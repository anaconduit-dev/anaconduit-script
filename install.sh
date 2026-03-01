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

# 5. Подготовка директорий и выпуск сертификатов
# Нам нужно выпустить сертификаты ДО того, как Nginx потребует их в конфиге (либо использовать заглушки)
mkdir -p "$INSTALL_DIR/data/nginx/certs"
mkdir -p "$INSTALL_DIR/data/nginx/www"

echo "Выпуск SSL сертификатов..."
# Останавливаем всё, что может занимать 80 порт для режима standalone
systemctl stop nginx 2>/dev/null 

certbot certonly --standalone \
    -d "$PANEL_DOMAIN" -d "$REALITY_DEST_DOMAIN" \
    --email "$LE_EMAIL" --agree-tos --no-eff-email \
    --config-dir "$INSTALL_DIR/data/nginx/certs" \
    --work-dir "$INSTALL_DIR/data/nginx/certs/work" \
    --logs-dir "$INSTALL_DIR/data/nginx/certs/logs"

# 6. Настройка Cron для автопродления
CRON_JOB="0 3 * * * certbot renew --pre-hook 'docker stop nginx' --post-hook 'docker start nginx' --config-dir $INSTALL_DIR/data/nginx/certs >> /var/log/certbot-renew.log 2>&1"
(crontab -l 2>/dev/null | grep -v "certbot renew"; echo "$CRON_JOB") | crontab -

# 7. Запуск контейнеров
echo "Запуск контейнеров..."
docker compose up -d --build

# 8. Ожидание бэкенда и финальный setup Nginx
echo "Ожидание запуска бэкенда..."
MAX_RETRIES=30
COUNT=0
until $(curl --output /dev/null --silent --head --fail http://localhost:8000/docs); do
    printf '.'
    sleep 2
    COUNT=$((COUNT+1))
    [ $COUNT -eq $MAX_RETRIES ] && echo "Ошибка бэкенда" && exit 1
done

echo -e "\nПрименение конфигурации Nginx..."
curl -X POST "http://localhost:8000/nginx/setup" -H "accept: application/json"


echo "--- Установка завершена ---"
source .env
echo "-------------------------------------------------------"
echo "Панель управления: https://$PANEL_DOMAIN/$PANEL_SECRET_PATH"
echo "Путь подписок: https://$PANEL_DOMAIN/$SUB_PATH/TOKEN"
echo "Логин: $ADMIN_USER"
echo "Пароль: $ADMIN_PASSWORD"
echo "-------------------------------------------------------"
echo "Все данные сохранены в $INSTALL_DIR/.env"
