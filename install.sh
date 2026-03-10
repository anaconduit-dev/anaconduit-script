#!/bin/bash

INSTALL_DIR="/opt/anaconduit"
REPO_URL="https://github.com/anaconduit-dev/anaconduit.git"

generate_secret() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w "${1:-32}" | head -n 1
}

echo "--- Установка Anaconduit Panel ---"

# 1. Проверка Docker
if ! command -v docker >/dev/null 2>&1; then
  echo "ОШИБКА: Docker не установлен."
  exit 1
fi

# 2. Проверка и установка Certbot
if ! command -v certbot >/dev/null 2>&1; then
    echo "Certbot не найден. Установка..."
    if [ -f /etc/debian_version ]; then
        sudo apt update && sudo apt install -y certbot
    elif [ -f /etc/redhat-release ]; then
        sudo yum install -y epel-release && sudo yum install -y certbot
    else
        echo "ОШИБКА: Не удалось определить пакетный менеджер. Установите certbot вручную."
        exit 1
    fi
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit 1

# 3. Клонирование / обновление
if [ -d ".git" ]; then
    git pull
else
    git clone "$REPO_URL" .
fi

# 4. Настройка .env
if [ ! -f ".env" ]; then
    echo "--- Настройка параметров ---"
    read -p "Введите логин администратора (default: admin): " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-admin}
    read -p "Введите пароль администратора: " ADMIN_PASSWORD
    read -p "Введите домен панели: " PANEL_DOMAIN
    read -p "Введите домен маскировки Reality: " REALITY_DEST_DOMAIN
    read -p "Введите ваш Email (для уведомлений Let's Encrypt): " EMAIL

    SECRET_KEY=$(generate_secret 32)
    PANEL_SECRET_PATH=$(generate_secret 16)
    SUB_PATH=$(generate_secret 12)

    cat > .env <<EOF
HOST_DATA_PATH=$INSTALL_DIR/data
DATABASE_URL=sqlite+aiosqlite:////app/data/anaconduit.db
APP_NAME=Anaconduit
DEBUG=false
ADMIN_USER=$ADMIN_USER
ADMIN_PASSWORD=$ADMIN_PASSWORD
SECRET_KEY=$SECRET_KEY
PANEL_DOMAIN=$PANEL_DOMAIN
REALITY_DEST_DOMAIN=$REALITY_DEST_DOMAIN
PANEL_SECRET_PATH=$PANEL_SECRET_PATH
SUB_PATH=$SUB_PATH
LE_EMAIL=$EMAIL
EOF
fi

source .env

# 5. Подготовка директорий и настройка SSL
mkdir -p "$INSTALL_DIR/data/nginx/certs"
mkdir -p "$INSTALL_DIR/data/nginx/www"

echo "--- Настройка SSL (Let's Encrypt) ---"

check_cert() {
    local domain=$1
    if [ -f "$INSTALL_DIR/data/nginx/certs/live/$domain/fullchain.pem" ]; then
        return 0
    else
        return 1
    fi
}

DOMAINS_TO_ISSUE=""

# Проверка PANEL_DOMAIN
if check_cert "$PANEL_DOMAIN"; then
    echo "✅ SSL для PANEL_DOMAIN ($PANEL_DOMAIN) найден."
    read -p "Перевыпустить его? (y/N): " REISSUE_PANEL
    [[ "$REISSUE_PANEL" =~ ^[Yy]$ ]] && DOMAINS_TO_ISSUE+="-d $PANEL_DOMAIN "
else
    echo "❌ SSL для PANEL_DOMAIN ($PANEL_DOMAIN) не найден."
    DOMAINS_TO_ISSUE+="-d $PANEL_DOMAIN "
fi

# Проверка REALITY_DEST_DOMAIN
if [ "$PANEL_DOMAIN" != "$REALITY_DEST_DOMAIN" ]; then
    if check_cert "$REALITY_DEST_DOMAIN"; then
        echo "✅ SSL для REALITY_DOMAIN ($REALITY_DEST_DOMAIN) найден."
        read -p "Перевыпустить его? (y/N): " REISSUE_REALITY
        [[ "$REISSUE_REALITY" =~ ^[Yy]$ ]] && DOMAINS_TO_ISSUE+="-d $REALITY_DEST_DOMAIN "
    else
        echo "❌ SSL для REALITY_DOMAIN ($REALITY_DEST_DOMAIN) не найден."
        DOMAINS_TO_ISSUE+="-d $REALITY_DEST_DOMAIN "
    fi
fi

if [ -n "$DOMAINS_TO_ISSUE" ]; then
    echo "--- Процесс выпуска SSL сертификатов для: $DOMAINS_TO_ISSUE ---"
    systemctl stop nginx 2>/dev/null
    docker stop nginx 2>/dev/null

    certbot certonly --standalone \
        $DOMAINS_TO_ISSUE \
        --email "$LE_EMAIL" --agree-tos --no-eff-email \
        --config-dir "$INSTALL_DIR/data/nginx/certs" \
        --work-dir "$INSTALL_DIR/data/nginx/certs/work" \
        --logs-dir "$INSTALL_DIR/data/nginx/certs/logs" \
        --non-interactive
    
    if [ $? -ne 0 ]; then
        echo "⚠️ ОШИБКА: Certbot не смог выполнить операцию."
        read -p "Продолжить установку без SSL? (y/N): " CONT_WITHOUT_SSL
        [[ ! "$CONT_WITHOUT_SSL" =~ ^[Yy]$ ]] && exit 1
    else
        echo "✅ Операция с сертификатами завершена успешно!"
    fi
else
    echo "--- Все сертификаты актуальны. Пропуск выпуска. ---"
fi

# 6. Настройка Cron
CRON_JOB="0 3 * * * certbot renew --pre-hook 'docker stop nginx' --post-hook 'docker start nginx' --config-dir $INSTALL_DIR/data/nginx/certs >> /var/log/certbot-renew.log 2>&1"
(crontab -l 2>/dev/null | grep -v "certbot renew"; echo "$CRON_JOB") | crontab -

# 7. Запуск контейнеров
echo "Запуск контейнеров..."
docker compose up -d --build


echo "--- Установка завершена ---"
echo "-------------------------------------------------------"
echo "Панель управления: https://$PANEL_DOMAIN/$PANEL_SECRET_PATH"
echo "Логин: $ADMIN_USER"
echo "Пароль: $ADMIN_PASSWORD"
echo "-------------------------------------------------------"
