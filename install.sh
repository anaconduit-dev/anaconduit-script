#!/bin/bash

# 1. Параметры
INSTALL_DIR="/opt/anaconduit"
REPO_URL="https://github.com/youruser/anaconduit.git"

echo "--- Установка Anaconduit Panel ---"

# 2. Проверка Docker
if ! [ -x "$(command -v docker)" ]; then
  echo "ОШИБКА: Docker не установлен. Установите Docker и попробуйте снова."
  exit 1
fi

# 3. Создание структуры папок
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

# 4. Клонирование или обновление кода
if [ -d ".git" ]; then
  echo "Обновление существующего проекта..."
  git pull
else
  echo "Клонирование проекта..."
  git clone $REPO_URL .
fi

# 5. Создание базового .env файла с правильными путями
if [ ! -f ".env" ]; then
  echo "Настройка окружения..."
  echo "HOST_DATA_PATH=$INSTALL_DIR/data" >> .env
  echo "ADMIN_USERNAME=admin" >> .env
  echo "ADMIN_PASSWORD=$(openssl rand -hex 12)" >> .env
  echo "DATABASE_URL=sqlite:////app/data/panel.db" >> .env
fi

# 6. Подготовка папки данных (чтобы Docker не создал их как root-папки)
mkdir -p $INSTALL_DIR/data/xray
touch $INSTALL_DIR/data/xray/config.json

# 7. Запуск
echo "Запуск контейнеров..."
docker compose up -d --build

echo "--- Установка завершена! ---"
echo "Панель доступна на порту 8000"
echo "Логин/пароль администратора можно найти в $INSTALL_DIR/.env"
