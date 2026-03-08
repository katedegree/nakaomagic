#!/bin/bash

# --- ポート確認関数 (単一ポートチェック) ---
check_port() {
    local port=$1
    local output=""

    if command -v lsof &> /dev/null; then
        output=$(lsof -i TCP:$port -sTCP:LISTEN 2> /dev/null)
    elif command -v netstat &> /dev/null; then
        output=$(netstat -tuln | grep ":$port\b" 2> /dev/null)
    fi
    
    if [ -n "$output" ]; then
        return 1 # ❌ 使用中
    else
        return 0 # ✅ 未使用
    fi
}

# --- ポート入力関数 ---
get_valid_port() {
    local service_name=$1
    local default_port=$2
    local port=""
    while true; do
        read -p "🔌 ${service_name}のホストポートを入力してください (デフォルト: ${default_port}): " port
        port=${port:-$default_port}
        
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
            echo "⚠️ 無効なポート番号です。1024〜65535の範囲で入力してください。"
            continue
        fi
        break
    done
    echo $port
}

# --- ポート一括チェックと即時終了処理 ---
check_all_ports() {
    local -a ports=("${FRONT_PORT}:Next.js" "${API_PORT}:Laravel" "${DB_PORT}:MySQL")
    local conflict_found=0

    echo "--- 🔍 ポート使用状況の確認 ---"
    
    if ! command -v lsof &> /dev/null && ! command -v netstat &> /dev/null; then
        echo "⚠️ 警告: lsof/netstatが見つかりません。ポートの競合チェックはスキップされます。"
        echo "⚠️ 競合が発生した場合、Docker起動時にエラーになります。"
        return 0
    fi

    for entry in "${ports[@]}"; do
        IFS=':' read -r port service <<< "$entry"
        if ! check_port "$port"; then
            echo "❌ 競合検出: ${service}用に指定されたポート ${port} は既に使用されています。"
            conflict_found=1
        else
            echo "✅ 使用可能: ${service} (${port})"
        fi
    done

    if [ $conflict_found -eq 1 ]; then
        echo "=================================================="
        echo "‼️ ポート競合が検出されたため、環境構築を終了します。"
        echo "=================================================="
        exit 1
    fi
    echo "✅ すべてのポートは使用可能です。構築を続行します。"
}

# --- docker compose コマンドのチェック ---
if ! command -v docker &> /dev/null; then
    echo "❌ Docker がインストールされていません。Docker Desktop または Docker Engine をインストールしてください。"
    exit 1
fi
if ! docker compose version &> /dev/null; then
    echo "❌ 'docker compose' コマンドが使用できません。"
    echo "Docker のバージョンが古い場合は、'docker-compose' ではなく新しい 'docker compose' が使えるようアップデートしてください。"
    exit 1
fi
echo "✅ docker compose コマンドが使用可能です。"

# --- ポート設定の取得 ---
echo "--- 🔌 ポート設定 ---"
FRONT_PORT=$(get_valid_port "Next.js (web)" "3000")
API_PORT=$(get_valid_port "Laravel (api)" "8000")
DB_PORT=$(get_valid_port "MySQL (db)" "3306")
echo "-------------------"

# --- 実行フェーズ 0: ポートチェック実行 ---
check_all_ports

# --- 1. 初期ファイル作成 ---

echo "✅ 1. 初期ファイルの作成 (compose.yaml, Dockerfile.api, Dockerfile.web)"

# compose.yml の作成 (ここではまだportsは含めない)
cat << EOF > compose.yaml
services:
  web:
    build: 
      dockerfile: Dockerfile.web
    volumes:
      - .:/workdir
  api:
    build:
      dockerfile: Dockerfile.api
    volumes:
      - .:/workdir

EOF

# Dockerfile.api, Dockerfile.web の作成 (変更なし)
cat << EOF > Dockerfile.api
FROM php:8.4-fpm
WORKDIR /workdir
COPY --from=composer:2.8 /usr/bin/composer /usr/bin/composer
ENV COMPOSER_ALLOW_SUPERUSER=1
RUN apt-get update
RUN apt-get install -y zip

EOF

cat << EOF > Dockerfile.web
FROM node:24-slim
WORKDIR /workdir

EOF

# --- 2. ディレクトリ作成 (Next.js & Laravel プロジェクトの作成) ---

echo "✅ 2. コンテナ作成 (docker compose build)"
docker compose build

echo "✅ 2.1. Next.jsプロジェクト 'web' の作成"
docker compose run --rm web npx -y create-next-app web --typescript --no-eslint --no-react-compiler --tailwind --src-dir --app --turbopack --no-import-alias

echo "✅ 2.2. Laravelプロジェクト 'api' の作成"
docker compose run --rm api composer create-project laravel/laravel api

# --- 3. Dockerfileの移動・作成と初期ファイルの削除 ---

echo "✅ 3. Dockerfileの移動・作成と初期ファイルの削除"

# 初期Dockerfileの削除
rm Dockerfile.api Dockerfile.web

# api/Dockerfile の作成 (変更なし)
cat << 'EOF' > api/Dockerfile
FROM dunglas/frankenphp:php8.4
WORKDIR /api
# composerをインストール
COPY --from=composer:2.8 /usr/bin/composer /usr/bin/composer
ENV COMPOSER_ALLOW_SUPERUSER=1
# パッケージのインストールとキャッシュ削除
RUN apt-get update && \
  apt-get install -y zip unzip git rsync && \
  rm -rf /var/lib/apt/lists/* && \
  install-php-extensions pdo_mysql pcntl
# 依存関係ファイルのみコピーしてキャッシュを効かせる
COPY composer.json composer.lock ./
RUN composer install --no-scripts
# マウント外にコピー
RUN mv vendor /opt/vendor
COPY . .
# vendor同期用スクリプト作成
RUN printf '#!/bin/bash\n\
set -e\n\
[ ! -d /api/vendor ] || [ -z "$(ls -A /api/vendor 2>/dev/null)" ] && \
cp -r /opt/vendor /api/vendor || \
rsync -au --quiet /opt/vendor/ /api/vendor/\n\
exec "$@"\n' > /docker-entrypoint.sh && \
    chmod +x /docker-entrypoint.sh
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["php", "artisan", "octane:start", "--host", "0.0.0.0", "--port", "8000", "--watch"]
EXPOSE 8000
EOF

# web/Dockerfile の作成 (変更なし)
cat << 'EOF' > web/Dockerfile
FROM node:24-slim
WORKDIR /web
# パッケージのインストールとキャッシュ削除
RUN apt-get update && \
    apt-get install -y rsync && \
    rm -rf /var/lib/apt/lists/*
# 依存関係ファイルのみコピーしてキャッシュを効かせる
COPY package.json package-lock.json ./
RUN npm install
# マウント外にコピー
RUN mv node_modules /opt/node_modules
COPY . .
# node_modules同期用スクリプト作成
RUN printf '#!/bin/bash\n\
set -e\n\
[ ! -d /web/node_modules ] || [ -z "$(ls -A /web/node_modules 2>/dev/null)" ] && \
cp -r /opt/node_modules /web/node_modules || \
rsync -au --quiet /opt/node_modules/ /web/node_modules/\n\
exec "$@"\n' > /docker-entrypoint.sh && \
    chmod +x /docker-entrypoint.sh
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["npm", "run", "dev"]
EXPOSE 3000
EOF

# --- 4. ファイル編集 (compose.yaml, .env, .gitignore, User.php) ---

echo "✅ 4. ファイル編集 (compose.yaml, .env, .gitignore, User.php)"

# compose.yaml の更新 (ポート適用と依存関係追加)
cat << EOF > compose.yaml
services:
  web:
    build: ./web
    volumes:
      - ./web:/web
    ports:
      - ${FRONT_PORT}:3000
  api:
    build: ./api
    volumes:
      - ./api:/api
    ports:
      - ${API_PORT}:8000
  db:
    image: mysql:8.4
    volumes:
      - ./api/mysql_data:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD: password
      MYSQL_DATABASE: dev
    ports:
      - ${DB_PORT}:3306

EOF

# api/.env のデータベース箇所を編集
echo "⚙️ api/.env ファイルのデータベース設定を更新中..."
# ★★★ 修正点: DB設定を安全に削除してから追加 ★★★
# DB_CONNECTION=sqlite の行を見つけ、その行から6行分を削除（古いDB設定全体を削除）
# macOS (BSD sed) 向け
cat > /tmp/new_env << 'EOL'

DB_CONNECTION=mysql
DB_HOST=db
DB_PORT=3306
DB_DATABASE=dev
DB_USERNAME=root
DB_PASSWORD=password
EOL

# 既存のDB設定ブロックを削除（sqlite/mysql問わず）
sed -i '' -e '/^DB_CONNECTION=/,+6d' api/.env

# LOG_LEVEL=debug の後に1行空けてDB設定を挿入
sed -i '' -e '/^LOG_LEVEL=debug$/r /tmp/new_env' api/.env

# api/.gitignore に mysql_data を追記
echo "mysql_data" >> api/.gitignore

# api/app/Models/User.php の編集 (Sanctum/HasApiTokensの追加)
sed -i '' -e $'/use Illuminate\\\\Notifications\\\\Notifiable;/a\\
use Laravel\\\\Sanctum\\\\HasApiTokens;
' api/app/Models/User.php
sed -i '' -e 's/use HasFactory, Notifiable;/use HasFactory, Notifiable, HasApiTokens;/' api/app/Models/User.php

# --- 5. 最終環境構築と起動 ---

echo "✅ 5. コンテナビルド (docker compose build)"
docker compose build

echo "✅ 5.1. Laravel APIルートのインストール"
docker compose run --rm api php artisan install:api --without-migration-prompt

echo "5.2. Octaneのインストール"
docker compose run --rm api sh -c "composer require laravel/octane && php artisan octane:install --server=frankenphp"

echo "5.4. コンテナの起動"
docker compose up -d

# 環境が完全に立ち上がるまで待機時間を延長
echo "⌛ データベース起動を待機中 (15秒)..."
sleep 15

echo "✅ 5.3. データベースマイグレーションの実行"

# マイグレーションが失敗した場合に備えて再試行
MIGRATION_SUCCESS=false
for i in 1 2 3; do
    echo "Attempting migration (Attempt $i/3)..."
    # exec api php artisan migrate の実行結果をチェック
    if docker compose exec api php artisan migrate; then
        echo "✅ データベースマイグレーションに成功しました。"
        MIGRATION_SUCCESS=true
        break
    fi
    echo "マイグレーション失敗。5秒待機後に再試行します..."
    sleep 5
done

if [ "$MIGRATION_SUCCESS" != "true" ]; then
    echo "❌ 警告: データベースマイグレーションが複数回失敗しました。DBコンテナの状態と.env設定を確認してください。"
fi

echo "🎉 環境構築が完了しました！"
echo "Next.js (web) は http://localhost:${FRONT_PORT} で、Laravel (api) は http://localhost:${API_PORT} で動作しています。"
echo "MySQL (db) はホストポート ${DB_PORT} で接続可能です。"

rm -rf nakaomagic
# --- スクリプト終了 ---
