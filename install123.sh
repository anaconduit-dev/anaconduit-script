#!/bin/bash

INSTALL_DIR="/opt/anaconduit"
REPO_URL="https://github.com/anaconduit-dev/anaconduit.git"

generate_secret() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w "${1:-32}" | head -n 1
}

echo "--- Установка Anaconduit Panel ---"

# --- 1. Проверка и установка Docker / Docker Compose ---
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
        echo "❌ Неподдерживаемая ОС."
        exit 1
    fi
}

command -v docker >/dev/null 2>&1 || install_docker
sudo systemctl enable docker.service
sudo systemctl enable containerd.service
systemctl is-active --quiet docker || sudo systemctl start docker

# Проверка docker-compose
docker compose version >/dev/null 2>&1 || sudo apt install -y docker-compose-plugin

# --- 2. Создание директории ---
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit 1

# --- 3. Получение доступных версий ---
echo "--- Проверка доступных версий ---"
ALL_VERSIONS=$(curl -s https://api.github.com/repos/anaconduit-dev/anaconduit/tags | grep '"name":' | sed -E 's/.*"([^"]+)".*/\1/' | head -n 5)

if [ -z "$ALL_VERSIONS" ]; then
    SELECTED_VERSION="v1.0.01"
else
    VERSIONS_ARRAY=($ALL_VERSIONS)
    DEFAULT_VERSION=${VERSIONS_ARRAY[0]}
    echo "Доступные версии:"
    for i in "${!VERSIONS_ARRAY[@]}"; do
        echo "  $((i+1))) ${VERSIONS_ARRAY[$i]}"
    done
    read -p "Выберите номер версии (по умолчанию 1 - $DEFAULT_VERSION): " VERSION_CHOICE
    if [[ -z "$VERSION_CHOICE" || ! "$VERSION_CHOICE" =~ ^[1-5]$ || "$VERSION_CHOICE" -gt "${#VERSIONS_ARRAY[@]}" ]]; then
        SELECTED_VERSION=$DEFAULT_VERSION
    else
        SELECTED_VERSION=${VERSIONS_ARRAY[$((VERSION_CHOICE-1))]}
    fi
fi

VERSION=$SELECTED_VERSION
echo "--- Выбрана версия: $VERSION ---"

# --- 4. Клонирование или обновление конфигов ---
if [ -d ".git" ]; then
    git config --global --add safe.directory "$INSTALL_DIR"
    git fetch --tags --all
    git checkout "$VERSION"
    git reset --hard "tags/$VERSION"
    git clean -fd
else
    git clone "$REPO_URL" .
    git checkout "$VERSION"
fi

# --- 5. Настройка .env ---
if [ ! -f ".env" ]; then
    echo "--- Настройка .env ---"
    IP4=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)

    read -p "Использовать авто-домены на базе IP? (y/n, default: n): " AUTODOMAIN
    if [[ ${AUTODOMAIN} =~ ^[Yy]$ ]]; then
        PANEL_DOMAIN="${IP4}.cdn-one.org"
        REALITY_DEST_DOMAIN="${IP4//./-}.cdn-one.org"
    else
        read -p "Введите домен панели: " PANEL_DOMAIN
        read -p "Введите домен маскировки Reality: " REALITY_DEST_DOMAIN
    fi

    read -p "Логин администратора (default: admin): " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-admin}
    read -p "Пароль администратора: " ADMIN_PASSWORD
    read -p "Email для Let's Encrypt: " EMAIL

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
else
    sed -i "s|^VERSION=.*|VERSION=$VERSION|" .env
    sed -i "s|^HOST_DATA_PATH=.*|HOST_DATA_PATH=$INSTALL_DIR/data|" .env
fi

source .env

# --- 6. Настройка SSL ---
mkdir -p "$INSTALL_DIR/data/nginx/certs" "$INSTALL_DIR/data/nginx/www"

check_cert() {
    local domain=$1
    [ -f "$INSTALL_DIR/data/nginx/certs/live/$domain/fullchain.pem" ]
}

issue_cert() {
    local domain=$1
    echo "--- Выпуск SSL для $domain ---"
    systemctl stop nginx 2>/dev/null
    docker stop nginx 2>/dev/null

    certbot certonly --standalone \
        -d "$domain" \
        --email "$LE_EMAIL" --agree-tos --no-eff-email \
        --config-dir "$INSTALL_DIR/data/nginx/certs" \
        --work-dir "$INSTALL_DIR/data/nginx/certs/work" \
        --logs-dir "$INSTALL_DIR/data/nginx/certs/logs" \
        --non-interactive
}

check_cert "$PANEL_DOMAIN" || issue_cert "$PANEL_DOMAIN"
[ "$PANEL_DOMAIN" != "$REALITY_DEST_DOMAIN" ] && (check_cert "$REALITY_DEST_DOMAIN" || issue_cert "$REALITY_DEST_DOMAIN")

# --- 7. Настройка Cron для обновления сертификатов ---
CRON_JOB="0 3 * * * certbot renew --pre-hook 'docker stop nginx' --post-hook 'docker start nginx' --config-dir $INSTALL_DIR/data/nginx/certs --work-dir $INSTALL_DIR/data/nginx/certs/work --logs-dir $INSTALL_DIR/data/nginx/certs/logs >> /var/log/certbot-renew.log 2>&1"
(crontab -l 2>/dev/null | grep -v "certbot renew"; echo "$CRON_JOB") | crontab -

# --- 8. Запуск контейнера из публичного GHCR образа ---
echo "🚀 Запуск контейнеров (Версия: $VERSION)..."
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d

# 9. Настройка UFW
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
check_backend() {
    echo "--- Проверка работоспособности API ---"
    local max_attempts=5
    local attempt=1
    local wait_time=3
    local check_url="https://$PANEL_DOMAIN/$PANEL_SECRET_PATH"

    while [ "$attempt" -le "$max_attempts" ]; do
        # Получаем HTTP код ответа
        local response=$(curl -skL -o /dev/null -w "%{http_code}" "$check_url")

        # Используем '=' вместо '==' и стандартный синтаксис [ ]
        if [ "$response" = "200" ] || [ "$response" = "401" ]; then
            echo "✅ Бэкенд отвечает (Код: $response)."
            return 0
        else
            echo "⏳ Попытка $attempt/$max_attempts: Бэкенд пока не готов (Код: $response). Ожидание ${wait_time}с..."
            sleep "$wait_time"
            # Инкремент в стиле POSIX (работает везде)
            attempt=$((attempt + 1))
        fi
    done

   echo "❌ ОШИБКА: Бэкенд не ответил после $max_attempts попыток."
    echo "--- Последние 5 строк логов контейнера 'app' для отладки: ---"
    echo "------------------------------------------------------------"
    docker compose logs --tail 5 app
    echo "------------------------------------------------------------"
    echo "💡 Совет: Попробуйте выполнить 'docker compose restart app'"
    return 1
}

check_backend
# Определяем цвета
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

LOGIN_URL="https://${PANEL_DOMAIN}/${PANEL_SECRET_PATH}"

echo -e "\n${GREEN}${BOLD}=======================================================${NC}"
echo -e "  🚀  ${BOLD}Anaconduit успешно развернут!${NC}"
echo -e "${GREEN}${BOLD}=======================================================${NC}"
echo -e ""
echo -e "  ${BLUE}${BOLD}Адрес панели:${NC}  ${LOGIN_URL}"
echo -e "  ${BLUE}${BOLD}Пользователь:${NC}  ${ADMIN_USER}"
echo -e "  ${BLUE}${BOLD}Пароль:${NC}        ${ADMIN_PASSWORD}"
echo -e "  ${BLUE}${BOLD}Домен для реалити:  ${REALITY_DEST_DOMAIN}"
echo -e ""
echo -e "${GREEN}${BOLD}=======================================================${NC}"
echo -e "  ${BOLD}Внимание:${NC} Сохраните эти данные в надежном месте."
echo -e "  Путь к панели был сгенерирован случайно для безопасности."
echo -e "${GREEN}${BOLD}=======================================================${NC}\n"
