#!/bin/bash

# --- Конфигурация ---
INSTALL_DIR="/opt/anaconduit"
REPO_URL="https://github.com/anaconduit-dev/anaconduit.git"
BIN_PATH="/usr/local/bin/anaconduit"
ENV_FILE="$INSTALL_DIR/.env"

# Цвета для вывода в терминал
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RED='\033[0;31m'
NC='\033[0m'

# --- Вспомогательные функции ---

generate_secret() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w "${1:-32}" | head -n 1
}

setup_bin() {
    if [ "$0" != "$BIN_PATH" ]; then
        echo -e "${GREEN}Настройка системной команды anaconduit...${NC}"
        sudo cp "$0" "$BIN_PATH"
        sudo chmod +x "$BIN_PATH"
    fi
}

get_current_version() {
    if [ -f "$ENV_FILE" ]; then
        grep "^VERSION=" "$ENV_FILE" | cut -d'=' -f2
    else
        echo "не установлено"
    fi
}

# --- Логика установки (Твой основной код) ---

run_full_install() {
    echo "--- Установка Anaconduit Panel ---"
    
    # 1. Docker
    if ! command -v docker >/dev/null 2>&1; then
        echo "--- Установка Docker... ---"
        if [ -f /etc/debian_version ]; then
            sudo apt update && sudo apt install -y ca-certificates curl gnupg lsb-release
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        elif [ -f /etc/redhat-release ]; then
            sudo yum install -y yum-utils
            sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        fi
    fi
    sudo systemctl enable --now docker

    # 2. Certbot
    if ! command -v certbot >/dev/null 2>&1; then
        [ -f /etc/debian_version ] && (sudo apt update && sudo apt install -y certbot)
        [ -f /etc/redhat-release ] && (sudo yum install -y epel-release && sudo yum install -y certbot)
    fi

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR" || exit 1

    # 3. Выбор версии
    ALL_VERSIONS=$(curl -s https://api.github.com/repos/anaconduit-dev/anaconduit/tags | grep '"name":' | sed -E 's/.*"([^"]+)".*/\1/' | head -n 5)
    VERSIONS_ARRAY=($ALL_VERSIONS)
    SELECTED_VERSION=${VERSIONS_ARRAY[0]:-"v1.0.01"}

    # Клонирование
    if [ -d ".git" ]; then
        git config --global --add safe.directory "$INSTALL_DIR"
        git fetch --tags --all
        git checkout "$SELECTED_VERSION"
        git reset --hard "tags/$SELECTED_VERSION"
        git clean -fd
    else
        git clone "$REPO_URL" .
        git checkout "$SELECTED_VERSION"
    fi

    # 4. .env
    if [ ! -f ".env" ]; then
        IP4=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)
        # Для простоты в скрипте установки оставим текстовые read, 
        # так как это разовый процесс конфигурации
        read -p "Использовать автоматические домены на базе IP? (y/n): " AUTODOMAIN
        if [[ ${AUTODOMAIN} == "y" ]]; then
            PANEL_DOMAIN="${IP4}.cdn-one.org"
            REALITY_DEST_DOMAIN="${IP4//./-}.cdn-one.org"
        else
            read -p "Введите домен панели: " PANEL_DOMAIN
            read -p "Введите домен Reality: " REALITY_DEST_DOMAIN
        fi
        read -p "Админ логин: " ADMIN_USER
        read -p "Админ пароль: " ADMIN_PASSWORD
        read -p "Email для SSL: " EMAIL

        cat > .env <<EOF
HOST_DATA_PATH=$INSTALL_DIR/data
DATABASE_URL=sqlite+aiosqlite:////app/data/anaconduit.db
ADMIN_USER=${ADMIN_USER:-admin}
ADMIN_PASSWORD=$ADMIN_PASSWORD
SECRET_KEY=$(generate_secret 32)
PANEL_DOMAIN=$PANEL_DOMAIN
REALITY_DEST_DOMAIN=$REALITY_DEST_DOMAIN
PANEL_SECRET_PATH=$(generate_secret 16)
SUB_PATH=$(generate_secret 12)
LE_EMAIL=$EMAIL
VERSION=$SELECTED_VERSION
EOF
    fi

    source .env
    
    # SSL и Запуск
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
    
    whiptail --title "Установка" --msgbox "Установка завершена! Команда 'anaconduit' теперь доступна." 10 60
}

# --- Функции управления для Меню ---

show_info() {
    if [ ! -f "$ENV_FILE" ]; then
        whiptail --title "Ошибка" --msgbox "Сначала выполните установку (пункт 4)." 8 45
        return
    fi
    source "$ENV_FILE"
    INFO="Панель: https://$PANEL_DOMAIN/$PANEL_SECRET_PATH\nЛогин: $ADMIN_USER\nПароль: $ADMIN_PASSWORD\nВерсия: $VERSION"
    whiptail --title "Данные доступа" --msgbox "$INFO" 12 65
}

check_updates() {
    CURRENT=$(get_current_version)
    LATEST=$(curl -s https://api.github.com/repos/anaconduit-dev/anaconduit/tags | grep '"name":' | sed -E 's/.*"([^"]+)".*/\1/' | head -n 1)

    if [ "$CURRENT" == "$LATEST" ]; then
        whiptail --title "Обновление" --msgbox "У вас последняя версия ($CURRENT)." 8 45
    else
        if whiptail --title "Обновление" --yesno "Доступна версия $LATEST. Обновить?\n(Ваша: $CURRENT)" 10 60; then
            cd "$INSTALL_DIR" || exit
            git fetch --tags --all
            git checkout "$LATEST"
            git reset --hard "tags/$LATEST"
            sed -i "s|^VERSION=.*|VERSION=$LATEST|" "$ENV_FILE"
            docker compose up -d --build
            whiptail --title "Успех" --msgbox "Обновлено до $LATEST" 8 45
        fi
    fi
}

# --- Главное меню ---

main_menu() {
    while true; do
        CHOICE=$(whiptail --title "Anaconduit Control Panel" --menu "Управление системой:" 15 60 6 \
            "1" "Показать инфо (ссылка/пароль)" \
            "2" "Проверить обновления" \
            "3" "Статус контейнеров (docker ps)" \
            "4" "Запустить установку/переустановку" \
            "5" "Перезапустить панель" \
            "6" "Выход" 3>&1 1>&2 2>&3)

        case $CHOICE in
            1) show_info ;;
            2) check_updates ;;
            3) 
                STATUS=$(docker compose -f "$INSTALL_DIR/docker-compose.yml" ps)
                whiptail --title "Статус" --msgbox "$STATUS" 15 80
                ;;
            4) run_full_install ;;
            5) 
                cd "$INSTALL_DIR" && docker compose restart
                whiptail --msgbox "Сервисы перезапущены" 8 40
                ;;
            6|*) exit 0 ;;
        esac
    done
}

# --- Запуск ---
setup_bin
main_menu
