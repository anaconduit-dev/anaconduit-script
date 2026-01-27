#!/bin/bash

INSTALL_DIR="/opt/anaconduit"
REPO_URL="https://github.com/anaconduit-dev/anaconduit.git"

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

# Создание .env (только если его нет)
if [ ! -f ".env" ]; then
  echo "Создание .env..."
  ADMIN_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)

  cat > .env <<EOF
HOST_DATA_PATH=$INSTALL_DIR/data
ADMIN_USERNAME=admin
ADMIN_PASSWORD=$ADMIN_PASSWORD
DATABASE_URL=sqlite:////app/data/panel.db
EOF
fi

# Подготовка директорий
mkdir -p "$INSTALL_DIR/data/xray"
mkdir -p "$INSTALL_DIR/data/nginx"

echo "Запуск контейнеров..."
docker compose up -d --build

echo "--- Установка завершена ---"
echo "Панель: http://localhost:8000"
echo "Данные для входа: $INSTALL_DIR/.env"
