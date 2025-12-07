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
├── docker-compose.yml # 作成
├── Dockerfile.api # 作成
└── Dockerfile.app # 作成
```

docker-compose.yml

```yaml
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

```

Dockerfile.api

```docker
FROM php:8.4
WORKDIR /workdir
COPY --from=composer:2.8 /usr/bin/composer /usr/bin/composer
ENV COMPOSER_ALLOW_SUPERUSER=1
RUN apt-get update
RUN apt-get install -y zip

```

Dockerfile.app

```docker
FROM node:24
WORKDIR /workdir

```

### ディレクトリ作成

コンテナ作成

```bash
docker compose build
```

front

```bash
 docker compose run app npx -y create-next-app front --typescript --no-eslint --no-react-compiler --tailwind --src-dir --app --turbopack --no-import-alias
```

back

```bash
docker compose run api composer create-project laravel/laravel back
```

コンテナ削除

```bash
docker compose down
```

### ファイル作成, 削除

```bash
.
├── back
│   └── Dockerfile # 作成
├── front
│   └── Dockerfile # 作成
├── docker-compose.yml
├── Dockerfile.api # 削除
└── Dockerfile.app # 削除
```

back/Dockerfile

```bash
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
# マウント外にコピー
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

```

front/Dockerfile

```bash
FROM node:24
WORKDIR /front
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
[ ! -d /front/node_modules ] || [ -z "$(ls -A /front/node_modules 2>/dev/null)" ] && \
cp -r /opt/node_modules /front/node_modules || \
rsync -au --quiet /opt/node_modules/ /front/node_modules/\n\
exec "$@"\n' > /docker-entrypoint.sh && \
    chmod +x /docker-entrypoint.sh
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["npm", "run", "dev"]
EXPOSE 3000

```

### ファイル編集

```bash
.
├── back
│   ├── app
│   │   └── Models
│   │       └── User.php # 編集
│   ├── .env # 編集
│   └── .gitignore # 編集
├── front
└── docker-compose.yml # 編集
```

docker-compose.yml

```yaml
services:
  app:
    build: ./front
    volumes:
      - ./front:/front
    ports:
      - 3000:3000
  api:
    build: ./back
    volumes:
      - ./back:/back
    ports:
      - 8000:8000
  db:
    image: mysql:8.4
    volumes:
      - ./back/mysql_data:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD: password
      MYSQL_DATABASE: dev
    ports:
      - 3306:3306

```

back/app/Models/User.php

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

back/.env（データベース箇所を編集）

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

back/.gitignore（行末に追記）

```diff
+ mysql_data
```

### APIルートの作成

```bash
docker compose build
```

```bash
docker compose up -d
```

```bash
docker compose run api sh -c "yes | php artisan install:api"
```

### 環境構築（git cloneした人も含む）
※ `git clone` した人は `.env` ファイルをリポジトリ管理者から受け取り、内容を自身の `.env` にコピーしてください


```bash
docker compose build
```

```bash
docker compose up -d
```

```bash
docker compose run api php artisan migrate
```
