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

# 5. Подготовка директорий и проверка/выпуск сертификатов
CERT_PATH="$INSTALL_DIR/data/nginx/certs/live/$PANEL_DOMAIN/fullchain.pem"
# 5. Подготовка директорий и проверка/выпуск сертификатов
CERT_DIR="$INSTALL_DIR/data/nginx/certs/live/$PANEL_DOMAIN"
CERT_PATH="$CERT_DIR/fullchain.pem"

mkdir -p "$INSTALL_DIR/data/nginx/certs"
mkdir -p "$INSTALL_DIR/data/nginx/www"

echo "--- Настройка SSL (Let's Encrypt) ---"

# Проверяем, есть ли уже сертификат на диске
if [ -f "$CERT_PATH" ]; then
    echo "✅ SSL сертификаты уже найдены в $CERT_DIR"
    read -p "Перевыпустить их заново? (y/N): " REISSUE_CERT
    REISSUE_CERT=${REISSUE_CERT:-n}
else
    echo "❌ SSL сертификаты не найдены."
    read -p "Выпустить новые через Certbot (Let's Encrypt)? (Y/n): " ISSUE_NEW
    ISSUE_NEW=${ISSUE_NEW:-y}
fi

if [[ "$REISSUE_CERT" =~ ^[Yy]$ ]] || [[ "$ISSUE_NEW" =~ ^[Yy]$ ]]; then
    echo "--- Процесс выпуска SSL сертификатов ---"
    
    # Останавливаем всё, что может занимать 80 порт
    systemctl stop nginx 2>/dev/null
    docker stop nginx 2>/dev/null

    # Запуск Certbot
    certbot certonly --standalone \
        -d "$PANEL_DOMAIN" -d "$REALITY_DEST_DOMAIN" \
        --email "$LE_EMAIL" --agree-tos --no-eff-email \
        --config-dir "$INSTALL_DIR/data/nginx/certs" \
        --work-dir "$INSTALL_DIR/data/nginx/certs/work" \
        --logs-dir "$INSTALL_DIR/data/nginx/certs/logs"
    
    if [ $? -ne 0 ]; then
        echo "⚠️ ОШИБКА: Certbot не смог выпустить сертификат."
        echo "Возможные причины: лимиты Let's Encrypt, закрытый порт 80 или неверные DNS записи."
        read -p "Продолжить установку без SSL (на свой страх и риск)? (y/N): " CONT_WITHOUT_SSL
        if [[ ! "$CONT_WITHOUT_SSL" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        echo "✅ Сертификаты успешно получены!"
    fi
else
    echo "--- Пропуск выпуска сертификатов. Убедитесь, что они добавлены вручную. ---"
fi

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
until $(curl --output /dev/null --silent --head --fail http://localhost:8000/health); do
    printf '.'
    sleep 2
    COUNT=$((COUNT+1))
    [ $COUNT -eq $MAX_RETRIES ] && echo "Ошибка бэкенда" && exit 1
done




echo "--- Установка завершена ---"
source .env
echo "-------------------------------------------------------"
echo "Панель управления: https://$PANEL_DOMAIN/$PANEL_SECRET_PATH"
echo "Путь подписок: https://$PANEL_DOMAIN/$SUB_PATH/TOKEN"
echo "Логин: $ADMIN_USER"
echo "Пароль: $ADMIN_PASSWORD"
echo "-------------------------------------------------------"
echo "Все данные сохранены в $INSTALL_DIR/.env"
