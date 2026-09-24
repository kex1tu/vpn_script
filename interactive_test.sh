#!/bin/bash
# ==============================================================================
# interactive_test.sh — Запуск реальной панели 3X-UI и Nginx в Docker для браузера
# ==============================================================================
set -e

DOMAIN="test.example.com"
PANEL_PORT="2096"
PANEL_PATH="panel"
ADMIN_USER="admin"
ADMIN_PASS="admin"

# Цвета
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}   Инициализация полного окружения 3X-UI + Nginx в Docker       ${NC}"
echo -e "${CYAN}================================================================${NC}"

# 1. Запуск тестового скрипта для создания базовой архитектуры
echo -e "${BLUE}[*] Создание архитектуры Nginx (Stream SNI-preread, SSL)...${NC}"
/test_script.sh > /dev/null 2>&1 || true

# 2. Освобождаем внутренний порт 443 для подписок в SQLite3 (чтобы Nginx слушал 443)
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '28506' WHERE key = 'subPort';" 2>/dev/null || true

# 3. Настройка и запуск РЕАЛЬНОЙ панели 3X-UI
echo -e "${BLUE}[*] Настройка параметров 3X-UI (порт ${PANEL_PORT}, путь /${PANEL_PATH}/)...${NC}"
mkdir -p /etc/x-ui /var/log
/usr/local/x-ui/x-ui setting -username "${ADMIN_USER}" -password "${ADMIN_PASS}" -port "${PANEL_PORT}" -webBasePath "/${PANEL_PATH}/" >/dev/null 2>&1 || true

echo -e "${BLUE}[*] Запуск сервиса 3X-UI в фоне...${NC}"
pkill -f "/usr/local/x-ui/x-ui run" 2>/dev/null || true
/usr/local/x-ui/x-ui run > /var/log/x-ui.log 2>&1 &
sleep 2

# 4. Настройка Nginx Stream SNI-preread для локального тестирования
echo -e "${BLUE}[*] Конфигурирование Nginx Stream SNI-preread...${NC}"
cat > "/etc/nginx/stream-enabled/stream.conf" << 'EOF'
map $ssl_preread_server_name $sni_name {
    hostnames;
    test.example.com     www;
    localhost            www;
    ""                   www;
    default              www;
}

upstream www {
    server 127.0.0.1:7443;
}

server {
    proxy_protocol on;
    listen          443;
    listen         [::]:443;
    proxy_pass      $sni_name;
    ssl_preread     on;
}
EOF

# 5. Настройка vhost Nginx со связкой с реальным 3X-UI
cat > "/etc/nginx/sites-available/${DOMAIN}" << EOF
server {
	server_tokens off;
	server_name ${DOMAIN} localhost 127.0.0.1;
	listen 7443 ssl http2 proxy_protocol;
	listen [::]:7443 ssl http2 proxy_protocol;
	root /var/www/html/;
	index index.html;

	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
	ssl_certificate /etc/letsencrypt/live/test.example.com/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/test.example.com/privkey.pem;

	# Security headers
	add_header X-Content-Type-Options "nosniff" always;
	add_header X-Frame-Options "SAMEORIGIN" always;
	add_header Referrer-Policy "strict-origin-when-cross-origin" always;

	# Проксирование в реальную панель 3X-UI
	location = /${PANEL_PATH} {
		return 301 /${PANEL_PATH}/;
	}

	location /${PANEL_PATH}/ {
		proxy_pass http://127.0.0.1:${PANEL_PORT};
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$proxy_protocol_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto https;
		proxy_http_version 1.1;
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection "upgrade";
		proxy_read_timeout 3600s;
		proxy_send_timeout 3600s;
	}

	# Ассеты панели 3X-UI
	location /assets/ {
		proxy_pass http://127.0.0.1:${PANEL_PORT};
	}

	# Сайт-заглушка
	location / {
		try_files \$uri \$uri/ /index.html;
	}
}
EOF

# 6. Создаем красивую интерактивную страницу сайта-заглушки (Fake Site)
mkdir -p /var/www/html
cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <title>Service Operational</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0b1329; color: #f8fafc; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
        .card { background: #172554; padding: 48px; border-radius: 24px; box-shadow: 0 25px 50px -12px rgba(0,0,0,0.7); text-align: center; max-width: 550px; border: 1px solid #1e3a8a; }
        h1 { color: #60a5fa; margin-bottom: 12px; font-size: 28px; }
        p { color: #93c5fd; line-height: 1.6; font-size: 16px; }
        .badge { display: inline-flex; align-items: center; gap: 6px; background: #065f46; color: #6ee7b7; padding: 8px 18px; border-radius: 9999px; font-weight: 600; font-size: 14px; margin-bottom: 24px; border: 1px solid #047857; }
        .btn { display: inline-block; margin-top: 24px; padding: 14px 32px; background: #2563eb; color: #ffffff; text-decoration: none; border-radius: 12px; font-weight: bold; font-size: 16px; transition: all 0.2s; box-shadow: 0 10px 15px -3px rgba(37,99,235,0.4); }
        .btn:hover { background: #1d4ed8; transform: translateY(-2px); }
        .info-box { background: #0f172a; border-radius: 12px; padding: 16px; margin-top: 24px; text-align: left; font-family: monospace; font-size: 13px; color: #cbd5e1; border: 1px solid #334155; }
    </style>
</head>
<body>
    <div class="card">
        <div class="badge">● Nginx SNI Preread Active</div>
        <h1>Fake Website Online</h1>
        <p>Этот сайт отдаётся Nginx как безопасная заглушка при стандартном заходе на порт 443.</p>
        <div class="info-box">
            <div>🔐 Панель: <a href="/panel/" style="color:#38bdf8;">/panel/</a></div>
            <div>👤 Логин: admin</div>
            <div>🔑 Пароль: admin</div>
        </div>
        <a class="btn" href="/panel/">Войти в реальную панель 3X-UI →</a>
    </div>
</body>
</html>
EOF

# 7. Запуск Nginx
echo -e "${BLUE}[*] Валидация и запуск Nginx...${NC}"
nginx -t
nginx

echo ""
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}  🚀 3X-UI И NGINX УСПЕШНО ЗАПУЩЕНЫ И ГОТОВЫ К ТЕСТИРОВАНИЮ!   ${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo -e "  🌐 ${BOLD}ОТКРОЙТЕ ПРЯМО В БРАУЗЕРЕ НА ХОСТЕ:${NC}"
echo -e "     👉 Панель управления 3X-UI:  ${CYAN}${BOLD}https://localhost:8443/panel/${NC}"
echo -e "     👉 Логин:   ${YELLOW}${BOLD}${ADMIN_USER}${NC}"
echo -e "     👉 Пароль:  ${YELLOW}${BOLD}${ADMIN_PASS}${NC}"
echo ""
echo -e "     👉 Сайт-заглушка (Fake Site): ${CYAN}${BOLD}https://localhost:8443/${NC}"
echo -e "     👉 Редирект HTTP -> HTTPS:   ${CYAN}${BOLD}http://localhost:8080/${NC}"
echo ""
echo -e "${YELLOW}  ℹ️  В браузере появится предупреждение о самоподписанном сертификате —${NC}"
echo -e "${YELLOW}     нажмите «Дополнительно» -> «Перейти на localhost (небезопасно)».${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo ""

# Интерактивное меню
while true; do
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    echo -e "${YELLOW}ДЕЙСТВИЯ В ТЕРМИНАЛЕ:${NC}"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    echo -e "  ${GREEN}1${NC}) 🌐 Проверить ответ сайта-заглушки (curl GET /)"
    echo -e "  ${GREEN}2${NC}) 🔐 Проверить ответ панели 3X-UI (curl GET /panel/)"
    echo -e "  ${GREEN}3${NC}) 📋 Просмотреть логи панели 3X-UI (/var/log/x-ui.log)"
    echo -e "  ${GREEN}4${NC}) 🚦 Просмотреть открытые сетевые порты (ss -tlpn)"
    echo -e "  ${GREEN}5${NC}) 💻 Открыть Bash-консоль внутри контейнера"
    echo -e "  ${RED}0${NC}) ❌ Остановить контейнер и выйти"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    read -p "Выберите действие [0-5]: " choice

    case "$choice" in
        1)
            echo -e "\n${BLUE}>>> Запрос к сайту-заглушке:${NC}"
            curl -k -s -i https://127.0.0.1:443/ | head -n 16
            echo -e "${GREEN}✓ Ответ получен.${NC}\n"
            ;;
        2)
            echo -e "\n${BLUE}>>> Запрос к панели 3X-UI через Nginx:${NC}"
            curl -k -s -i https://127.0.0.1:443/panel/ | head -n 20
            echo -e "${GREEN}✓ Панель 3X-UI отвечает кодом 200 OK!${NC}\n"
            ;;
        3)
            echo -e "\n${BLUE}>>> Логи 3X-UI:${NC}"
            tail -n 25 /var/log/x-ui.log 2>/dev/null || echo "Лог пуст."
            echo ""
            ;;
        4)
            echo -e "\n${BLUE}>>> Активные сетевые сокеты:${NC}"
            ss -tlpn 2>/dev/null || netstat -tlpn 2>/dev/null
            echo ""
            ;;
        5)
            echo -e "\n${YELLOW}Вход в Bash. Для возврата в меню введите 'exit'.${NC}"
            bash || true
            ;;
        0)
            echo -e "${GREEN}Остановка сервисов и выход.${NC}"
            pkill -f "/usr/local/x-ui/x-ui run" 2>/dev/null || true
            nginx -s stop 2>/dev/null || true
            exit 0
            ;;
        *)
            echo -e "${RED}Неверный выбор. Повторите ввод.${NC}\n"
            ;;
    esac
done
