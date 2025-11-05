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
FRONT_PORT=$(get_valid_port "Next.js (front)" "3000")
API_PORT=$(get_valid_port "Laravel (api)" "8000")
DB_PORT=$(get_valid_port "MySQL (db)" "3306")
echo "-------------------"

# --- 実行フェーズ 0: ポートチェック実行 ---
check_all_ports

# --- 1. 初期ファイル作成 ---

echo "✅ 1. 初期ファイルの作成 (.docker-compose.yml, Dockerfile.api, Dockerfile.app)"

# docker-compose.yml の作成 (ここではまだportsは含めない)
cat << EOF > docker-compose.yml
services:
  app:
    build: 
      dockerfile: Dockerfile.app
    volumes:
      - .:/workdir
  api:
    build:
      dockerfile: Dockerfile.api
    volumes:
      - .:/workdir

EOF

# Dockerfile.api, Dockerfile.app の作成 (変更なし)
cat << EOF > Dockerfile.api
FROM php:8.4
WORKDIR /workdir
COPY --from=composer:2.8 /usr/bin/composer /usr/bin/composer
ENV COMPOSER_ALLOW_SUPERUSER=1
RUN apt-get update
RUN apt-get install -y zip

EOF

cat << EOF > Dockerfile.app
FROM node:24
WORKDIR /workdir

EOF

# --- 2. ディレクトリ作成 (Next.js & Laravel プロジェクトの作成) ---

echo "✅ 2. コンテナ作成 (docker compose build)"
docker compose build

echo "✅ 2.1. Next.jsプロジェクト 'front' の作成"
docker compose run app npx -y create-next-app front --typescript --no-eslint --no-react-compiler --tailwind --src-dir --app --turbopack --no-import-alias

echo "✅ 2.2. Laravelプロジェクト 'back' の作成"
docker compose run api composer create-project laravel/laravel back

echo "✅ 2.3. 一時コンテナの削除 (docker compose down)"
docker compose down

# --- 3. Dockerfileの移動・作成と初期ファイルの削除 ---

echo "✅ 3. Dockerfileの移動・作成と初期ファイルの削除"

# 初期Dockerfileの削除
rm Dockerfile.api Dockerfile.app

# back/Dockerfile の作成 (変更なし)
cat << 'EOF' > back/Dockerfile
FROM php:8.4
WORKDIR /back
# composerをインストール
COPY --from=composer:2.8 /usr/bin/composer /usr/bin/composer
ENV COMPOSER_ALLOW_SUPERUSER=1
# パッケージのインストールとキャッシュ削除
RUN apt-get update && \
    apt-get install -y zip unzip git rsync && \
    rm -rf /var/lib/apt/lists/* && \
    docker-php-ext-install pdo_mysql
# 依存関係ファイルのみコピーしてキャッシュを効かせる
COPY composer.json composer.lock ./
RUN composer install --no-scripts
# マウント外にコピー
RUN mv vendor /opt/vendor
COPY . .
# vendor同期用スクリプト作成
RUN printf '#!/bin/bash\n\
set -e\n\
[ ! -d /back/vendor ] || [ -z "$(ls -A /back/vendor 2>/dev/null)" ] && \
cp -r /opt/vendor /back/vendor || \
rsync -au --quiet /opt/vendor/ /back/vendor/\n\
exec "$@"\n' > /docker-entrypoint.sh && \
    chmod +x /docker-entrypoint.sh
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["php", "artisan", "serve", "--host", "0.0.0.0"]
EXPOSE 8000
EOF

# front/Dockerfile の作成 (変更なし)
cat << 'EOF' > front/Dockerfile
FROM node:24
WORKDIR /front
# パッケージのインストールとキャッシュ削除
RUN apt-get update && \
    apt-get install -y rsync && \
    rm -rf /var/lib/apt/lists/*
# 依存関係ファイルのみコピーしてキャッシュを効かせる
COPY package.json package-lock.json ./
RUN npm install
# マウント外にコピー
RUN mv node_modules /opt/node_modules
COPY . .
# node_modules同期用スクリプト作成
RUN printf '#!/bin/bash\n\
set -e\n\
[ ! -d /front/node_modules ] || [ -z "$(ls -A /front/node_modules 2>/dev/null)" ] && \
cp -r /opt/node_modules /front/node_modules || \
rsync -au --quiet /opt/node_modules/ /front/node_modules/\n\
exec "$@"\n' > /docker-entrypoint.sh && \
    chmod +x /docker-entrypoint.sh
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["npm", "run", "dev"]
EXPOSE 3000
EOF

# --- 4. ファイル編集 (docker-compose.yml, .env, .gitignore, User.php) ---

echo "✅ 4. ファイル編集 (docker-compose.yml, .env, .gitignore, User.php)"

# docker-compose.yml の更新 (ポート適用と依存関係追加)
cat << EOF > docker-compose.yml
services:
  app:
    build: ./front
    volumes:
      - ./front:/front
    ports:
      - ${FRONT_PORT}:3000
  api:
    build: ./back
    volumes:
      - ./back:/back
    ports:
      - ${API_PORT}:8000
    depends_on:
      - db
  db:
    image: mysql:8.4
    volumes:
      - ./back/mysql_data:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD: password
      MYSQL_DATABASE: dev
    ports:
      - ${DB_PORT}:3306

EOF

# back/.env のデータベース箇所を編集
echo "⚙️ back/.env ファイルのデータベース設定を更新中..."
# ★★★ 修正点: DB設定を安全に削除してから追加 ★★★
# DB_CONNECTION=sqlite の行を見つけ、その行から6行分を削除（古いDB設定全体を削除）
# macOS (BSD sed) 向け
sed -i '' -e '/^DB_CONNECTION=sqlite/,+5d' back/.env

# 新しいDB設定行をファイル末尾に挿入
cat << EOL >> back/.env

# Docker Compose Environment
DB_CONNECTION=mysql
DB_HOST=db
DB_PORT=3306
DB_DATABASE=dev
DB_USERNAME=root
DB_PASSWORD=password
EOL

# back/.gitignore に mysql_data を追記
echo "mysql_data" >> back/.gitignore

# back/app/Models/User.php の編集 (Sanctum/HasApiTokensの追加)
sed -i '' -e '/use Illuminate\\Notifications\\Notifiable;/a\use Laravel\\Sanctum\\HasApiTokens;' back/app/Models/User.php
sed -i '' -e 's/use HasFactory, Notifiable;/use HasFactory, Notifiable, HasApiTokens;/' back/app/Models/User.php

# --- 5. 最終環境構築と起動 ---

echo "✅ 5. 最終コンテナビルド (docker compose build)"
docker compose build

echo "✅ 5.1. コンテナ起動 (docker compose up -d)"
docker compose up -d

# 環境が完全に立ち上がるまで待機時間を延長
echo "⌛ データベース起動を待機中 (20秒)..."
sleep 20 # 10秒から20秒に延長

echo "✅ 5.2. Laravel APIルートのインストール"
docker compose run api sh -c "yes | php artisan install:api"

echo "✅ 5.3. データベースマイグレーションの実行"

# マイグレーションが失敗した場合に備えて再試行
MIGRATION_SUCCESS=false
for i in 1 2 3; do
    echo "Attempting migration (Attempt $i/3)..."
    # run api php artisan migrate の実行結果をチェック
    if docker compose run api php artisan migrate; then
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
echo "Next.js (front) は http://localhost:${FRONT_PORT} で、Laravel (api) は http://localhost:${API_PORT} で動作しています。"
echo "MySQL (db) はホストポート ${DB_PORT} で接続可能です。"

rm -rf nakaomagic
# --- スクリプト終了 ---
