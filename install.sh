#!/bin/bash

INSTALL_DIR="/opt/anaconduit"
REPO_URL="https://github.com/anaconduit-dev/anaconduit.git"

generate_secret() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w "${1:-32}" | head -n 1
}

echo "--- Установка Anaconduit Panel ---"

# 1. Проверка и установка Docker / Docker Compose
install_docker() {
    echo "--- Установка Docker... ---"
    if [ -f /etc/debian_version ]; then
        sudo apt update
        sudo apt install -y ca-certificates curl gnupg lsb-release
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt update
        sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    elif [ -f /etc/redhat-release ]; then
        sudo yum install -y yum-utils
        sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        echo "❌ ОШИБКА: Неподдерживаемая ОС для автоустановки Docker."
        exit 1
    fi
}

if ! command -v docker >/dev/null 2>&1; then
    install_docker
else
    echo "✅ Docker уже установлен."
fi

# Проверка и настройка автозапуска Docker
echo "--- Настройка автозапуска Docker ---"
sudo systemctl enable docker.service
sudo systemctl enable containerd.service

if ! systemctl is-active --quiet docker; then
    echo "Запуск службы Docker..."
    sudo systemctl start docker
fi

# Проверка Docker Compose (V2)
if ! docker compose version >/dev/null 2>&1; then
    echo "⚠️ Docker Compose V2 не найден. Пытаюсь установить..."
    sudo apt install -y docker-compose-plugin || echo "❌ ОШИБКА: Не удалось установить Docker Compose V2."
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

# 3. Выбор версии (Интерактивный список последних 5 релизов)
echo "--- Проверка доступных версий Anaconduit ---"

# Получаем список последних 5 тегов через GitHub API
ALL_VERSIONS=$(curl -s https://api.github.com/repos/anaconduit-dev/anaconduit/tags | grep '"name":' | sed -E 's/.*"([^"]+)".*/\1/' | head -n 5)

if [ -z "$ALL_VERSIONS" ]; then
    echo "⚠️ Не удалось получить список версий. Будет установлена версия по умолчанию: v1.0.01"
    SELECTED_VERSION="v1.0.01"
else
    # Превращаем список в массив
    VERSIONS_ARRAY=($ALL_VERSIONS)
    DEFAULT_VERSION=${VERSIONS_ARRAY[0]}

    echo "Доступные версии для установки:"
    for i in "${!VERSIONS_ARRAY[@]}"; do
        echo "  $((i+1))) ${VERSIONS_ARRAY[$i]}"
    done

    read -p "Выберите номер версии (по умолчанию 1 - $DEFAULT_VERSION): " VERSION_CHOICE
    
    # Если нажали Enter или ввели некорректный номер — берем последнюю
    if [[ -z "$VERSION_CHOICE" || ! "$VERSION_CHOICE" =~ ^[1-5]$ || "$VERSION_CHOICE" -gt "${#VERSIONS_ARRAY[@]}" ]]; then
        SELECTED_VERSION=$DEFAULT_VERSION
    else
        SELECTED_VERSION=${VERSIONS_ARRAY[$((VERSION_CHOICE-1))]}
    fi
fi

VERSION=$SELECTED_VERSION
echo "--- Выбрана версия: $VERSION ---"

# Клонирование или обновление
if [ -d ".git" ]; then
    echo "Обновление текущей папки до $VERSION..."
    git fetch --tags
    git checkout "$VERSION"
else
    echo "Клонирование версии $VERSION в $INSTALL_DIR..."
    git clone --branch "$VERSION" --depth 1 "$REPO_URL" .
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
VERSION=$VERSION
EOF
fi

source .env

# 5. Подготовка директорий и настройка SSL
mkdir -p "$INSTALL_DIR/data/nginx/certs"
mkdir -p "$INSTALL_DIR/data/nginx/www"

echo "--- Настройка SSL (Let's Encrypt) ---"

# Функция для проверки наличия сертификата
check_cert() {
    local domain=$1
    if [ -f "$INSTALL_DIR/data/nginx/certs/live/$domain/fullchain.pem" ]; then
        return 0 # Сертификат есть
    else
        return 1 # Сертификата нет
    fi
}

# Функция для выпуска сертификата (одиночный вызов)
issue_cert() {
    local domain=$1
    echo "--- Процесс выпуска SSL для: $domain ---"
    
    # Останавливаем всё, что может занять 80 порт
    systemctl stop nginx 2>/dev/null
    docker stop nginx 2>/dev/null

    certbot certonly --standalone \
        -d "$domain" \
        --email "$LE_EMAIL" --agree-tos --no-eff-email \
        --config-dir "$INSTALL_DIR/data/nginx/certs" \
        --work-dir "$INSTALL_DIR/data/nginx/certs/work" \
        --logs-dir "$INSTALL_DIR/data/nginx/certs/logs" \
        --non-interactive

    if [ $? -eq 0 ]; then
        echo "✅ SSL для $domain успешно выпущен!"
        return 0
    else
        echo "⚠️ ОШИБКА: Не удалось выпустить SSL для $domain."
        return 1
    fi
}

# --- Обработка PANEL_DOMAIN ---
if check_cert "$PANEL_DOMAIN"; then
    echo "✅ SSL для PANEL_DOMAIN ($PANEL_DOMAIN) найден."
    read -p "Перевыпустить его? (y/N): " REISSUE_PANEL
    if [[ "$REISSUE_PANEL" =~ ^[Yy]$ ]]; then
        issue_cert "$PANEL_DOMAIN"
    fi
else
    echo "❌ SSL для PANEL_DOMAIN ($PANEL_DOMAIN) не найден."
    issue_cert "$PANEL_DOMAIN"
fi

# --- Обработка REALITY_DEST_DOMAIN ---
# Запускаем проверку только если домены разные
if [ "$PANEL_DOMAIN" != "$REALITY_DEST_DOMAIN" ]; then
    if check_cert "$REALITY_DEST_DOMAIN"; then
        echo "✅ SSL для REALITY_DOMAIN ($REALITY_DEST_DOMAIN) найден."
        read -p "Перевыпустить его? (y/N): " REISSUE_REALITY
        if [[ "$REISSUE_REALITY" =~ ^[Yy]$ ]]; then
            issue_cert "$REALITY_DEST_DOMAIN"
        fi
    else
        echo "❌ SSL для REALITY_DOMAIN ($REALITY_DEST_DOMAIN) не найден."
        issue_cert "$REALITY_DEST_DOMAIN"
    fi
else
    echo "ℹ️ REALITY_DOMAIN совпадает с PANEL_DOMAIN. Дополнительный сертификат не требуется."
fi

# 6. Настройка Cron (Исправлено для Docker)
CRON_JOB="0 3 * * * certbot renew --pre-hook 'docker stop nginx' --post-hook 'docker start nginx' --config-dir $INSTALL_DIR/data/nginx/certs --work-dir $INSTALL_DIR/data/nginx/certs/work --logs-dir $INSTALL_DIR/data/nginx/certs/logs >> /var/log/certbot-renew.log 2>&1"
(crontab -l 2>/dev/null | grep -v "certbot renew"; echo "$CRON_JOB") | crontab -

# 7. Запуск контейнеров
echo "Запуск контейнеров (Версия: $VERSION)..."
docker compose up -d --build

# 8. Настройка UFW
echo "--- Настройка брандмауэра UFW ---"
if command -v ufw >/dev/null 2>&1; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
    echo "✅ UFW включен. Открыты только порты 22, 80 и 443."
    echo "ℹ️ Все Xray-сервисы работают через Nginx на порту 443."
else
    echo "⚠️ UFW не найден. Пропуск настройки брандмауэра."
fi

echo "--- Установка завершена ---"
echo "-------------------------------------------------------"
echo "Версия панели: $VERSION"
echo "Панель управления: https://$PANEL_DOMAIN/$PANEL_SECRET_PATH"
echo "Логин: $ADMIN_USER"
echo "Пароль: $ADMIN_PASSWORD"
echo "-------------------------------------------------------"
echo "--- Проверка запущенных сервисов ---"
docker compose ps
