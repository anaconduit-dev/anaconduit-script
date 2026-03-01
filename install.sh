#!/bin/bash

INSTALL_DIR="/opt/anaconduit"
REPO_URL="https://github.com/anaconduit-dev/anaconduit.git"

# Функция для генерации случайных строк
generate_secret() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w "${1:-32}" | head -n 1
}

echo "--- Установка Anaconduit Panel ---"

# Проверка Docker
if ! command -v docker >/dev/null 2>&1; then
  echo "ОШИБКА: Docker не установлен."
  exit 1
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit 1

# Клонирование / обновление
if [ -d ".git" ]; then
  echo "Обновление проекта..."
  git pull
else
  echo "Клонирование проекта..."
  git clone "$REPO_URL" .
fi

# Интерактивный ввод данных (только если .env не существует)
if [ ! -f ".env" ]; then
    echo "--- Настройка параметров ---"
    read -p "Введите логин администратора (default: admin): " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-admin}

    read -p "Введите пароль администратора: " ADMIN_PASSWORD
    
    read -p "Введите домен панели (например, panel.test): " PANEL_DOMAIN
    read -p "Введите домен маскировки Reality (например, reality.test): " REALITY_DEST_DOMAIN

    # Генерация автоматических ключей
    SECRET_KEY=$(generate_secret 32)
    PANEL_SECRET_PATH=$(generate_secret 16)
    SUB_PATH=$(generate_secret 12)

    echo "Создание .env..."
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
EOF
    echo ".env файл успешно создан."
fi

# Подготовка директорий
mkdir -p "$INSTALL_DIR/data/xray"
mkdir -p "$INSTALL_DIR/data/nginx"

echo "Запуск контейнеров (сборка может занять время)..."
docker compose up -d --build

# Ожидание готовности бэкенда для выполнения setup
echo "Ожидание запуска бэкенда для настройки Nginx..."
MAX_RETRIES=30
COUNT=0
until $(curl --output /dev/null --silent --head --fail http://localhost:8000/docs); do
    printf '.'
    sleep 2
    COUNT=$((COUNT+1))
    if [ $COUNT -eq $MAX_RETRIES ]; then
        echo "Ошибка: Бэкенд не запустился вовремя."
        exit 1
    fi
done

echo -e "\nВыполнение первичной настройки Nginx..."
# Выполняем POST запрос. Внутри контейнеров обычно нет авторизации на localhost или 
# используем прямой вызов. Предполагаем, что эндпоинт доступен.
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
