# NAKAO MAGIC
1. gitをインストールする
2. Docker Desktopを起動する
3. アプリのディレクトリを作る
4. 移動する
5. ターミナルで魔法を実行する
```bash
[ -d "./nakaomagic" ] && (chmod +x ./nakaomagic/setup.sh && ./nakaomagic/setup.sh) || (git clone https://github.com/katedegree/nakaomagic.git && chmod +x ./nakaomagic/setup.sh && ./nakaomagic/setup.sh)
```

<br />
<br />
<br />

# 実行内容
### ファイル作成

```bash
.
├── compose.yaml # 作成
├── Dockerfile.api # 作成
└── Dockerfile.web # 作成
```

compose.yaml

```yaml
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

```

Dockerfile.api

```docker
FROM php:8.4-fpm
WORKDIR /workdir
COPY --from=composer:2.8 /usr/bin/composer /usr/bin/composer
ENV COMPOSER_ALLOW_SUPERUSER=1
RUN apt-get update
RUN apt-get install -y zip

```

Dockerfile.app

```docker
FROM node:24-slim
WORKDIR /workdir

```

### ディレクトリ作成

コンテナ作成

```bash
docker compose build
```

web

```bash
docker compose run --rm web npx -y create-next-app web --typescript --no-eslint --no-react-compiler --tailwind --src-dir --app --turbopack --no-import-alias
```

api

```bash
docker compose run --rm api composer create-project laravel/laravel api
```

### ファイル作成, 削除

```bash
.
├── api
│   └── Dockerfile # 作成
├── web
│   └── Dockerfile # 作成
├── compose.yaml
├── Dockerfile.api # 削除
└── Dockerfile.web # 削除
```

api/Dockerfile

```bash
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

```

web/Dockerfile

```bash
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

```

### ファイル編集

```bash
.
├── api
│   ├── app
│   │   └── Models
│   │       └── User.php # 編集
│   ├── .env # 編集
│   └── .gitignore # 編集
├── web
└── compose.yaml # 編集
```

compose.yaml

```yaml
services:
  web:
    build: ./web
    volumes:
      - ./web:/web
    ports:
      - 3000:3000
  api:
    build: ./api
    volumes:
      - ./api:/api
    ports:
      - 8000:8000
  db:
    image: mysql:8.4
    volumes:
      - ./api/mysql_data:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD: password
      MYSQL_DATABASE: dev
    ports:
      - 3306:3306

```

api/app/Models/User.php

```php
<?php

namespace App\Models;

// use Illuminate\Contracts\Auth\MustVerifyEmail;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Foundation\Auth\User as Authenticatable;
use Illuminate\Notifications\Notifiable;
use Laravel\Sanctum\HasApiTokens;

class User extends Authenticatable
{
    /** @use HasFactory<\Database\Factories\UserFactory> */
    use HasFactory, Notifiable, HasApiTokens;

    /**
     * The attributes that are mass assignable.
     *
     * @var list<string>
     */
    protected $fillable = [
        'name',
        'email',
        'password',
    ];

    /**
     * The attributes that should be hidden for serialization.
     *
     * @var list<string>
     */
    protected $hidden = [
        'password',
        'remember_token',
    ];

    /**
     * Get the attributes that should be cast.
     *
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'email_verified_at' => 'datetime',
            'password' => 'hashed',
        ];
    }
}

```

api/.env（データベース箇所を編集）

```diff
- DB_CONNECTION=sqlite
- DB_HOST=127.0.0.1
- DB_PORT=3306
- DB_DATABASE=laravel
- DB_USERNAME=root
- DB_PASSWORD=
+ DB_CONNECTION=mysql # mysqlに変更
+ DB_HOST=db # サービス名に変更
+ DB_PORT=3306
+ DB_DATABASE=dev # 接続するデータベース
+ DB_USERNAME=root
+ DB_PASSWORD=password # パスワード
```

api/.gitignore（行末に追記）

```diff
+ mysql_data
```

### APIルートの作成とOctane のインストール

```bash
docker compose build
```

```bash
docker compose run --rm api sh -c "no | php artisan install:api"
```

```bash
docker compose run --rm api sh -c "composer require laravel/octane && php artisan octane:install --server=frankenphp"
```

### 環境構築（git cloneした人も含む）
※ `git clone` した人は `.env` ファイルをリポジトリ管理者から受け取り、内容を自身の `.env` にコピーしてください

```bash
docker compose up -d
```

```bash
docker compose exec api php artisan migrate
```
