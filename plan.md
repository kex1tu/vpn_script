# Исторический архитектурный план: Устранение уязвимостей, включение OCSP Stapling и унификация сетевого стека узлов

> Архив предыдущей итерации. Не является текущим заданием, регламентом или разрешением production-доступа. Актуальный план — [implementation_plan.md](implementation_plan.md), правила — [AGENTS.md](AGENTS.md). Субагенты в проекте запрещены. Статусы и технические утверждения ниже относятся к историческому предложению и требуют повторной проверки перед применением.

> **Дата составления:** 14 октября 2026 г.<br>
> **Статус:** `PROPOSED` (Ожидает согласования оператором)<br>
> **Целевые серверы:**<br>
> 1. Сервер 1: `13.143.193.207` (Домен: `mymusicdownload.verymad.net`, SSH-порт: `56924`)<br>
> 2. Сервер 2: `194.76.168.20` (Алиас: `nl_music`, Домен: `musicdownloader.verymad.net`, SSH-порт: `56924`)<br>
> **Базовый регламент:** Строгое соблюдение инвариантов `AGENTS.md` (создание снимков SQLite БД перед миграциями, синтаксический тест `nginx -t` перед перезагрузкой, отсутствие простоев пользователей).

---

## 1. Цель и границы задачи (Objective & Scope)

### 1.1 Цель
Устранить критические расхождения и бреши в маскировке, выявленные в ходе глубокого аудита по методологии противодействия ТСПУ/DPI (Aster, `serv.host`), а именно:
1. Ликвидировать утечку боевого сертификата Let's Encrypt на Сервере 2 при сканировании с произвольным SNI.
2. Устранить демаскирующий маркер «самодельной VPN-ноды» на обоих серверах путем развертывания **OCSP Stapling** в Nginx.
3. Унифицировать архитектуру проксирования xHTTP (перевод Сервера 2 с `grpc_pass` на нативный HTTP/2 h2c через Unix-сокет в `/dev/shm`).
4. Оптимизировать параметры мультиплексирования `xMux` в базе 3X-UI (`maxConcurrency: 16`) для устранения Head-of-Line Blocking при передаче тяжелого потокового контента.
5. Закрыть открытый легаси-регекс проксирования портов в Nginx на Сервере 2.
6. Выровнять параметры TCP Fast Open (`tcp_fastopen = 3`) и защитить клиентов от зависания пакетов при MTU < 1500 (TCP MSS Clamping).

### 1.2 Границы задачи
- **In-Scope (Входит в план):**
  - Создание контрольных снимков конфигураций Nginx и баз SQLite на обоих хостах.
  - Правка конфигураций виртуальных хостов Nginx (`/etc/nginx/sites-available/`).
  - Включение OCSP Stapling с локальным резолвером и проверкой валидности через `openssl`.
  - Модификация SQLite-настроек `x-ui.db` в части параметров `xMux`.
  - Настройка `sysctl` параметров (`net.ipv4.tcp_fastopen = 3`).
  - Проверка валидности `nginx -t` и бесшовный reload `systemctl reload nginx`.
- **Out-of-Scope (Явно НЕ входит):**
  - Изменение настроек SSH (`sshd_config`, порт `56924`, пароли/ключи) — зафиксирован жесткий запрет оператора.
  - Изменение правил маршрутизации GeoHide DoH (работает штатно, подтверждено 10/10 тестами).
  - Установка Cloudflare WARP или сторонних туннелей.

---

## 2. Анализ текущего состояния и рисков (Current State Analysis)

### 2.1 Матрица дефектов по узлам

| Дефект / Уязвимость | Сервер 1 | Сервер 2 | Уровень риска | Последствие при бездействии |
| :--- | :---: | :---: | :---: | :--- |
| **Утечка сертификата чужим сканерам** | Нет (`ssl_reject_handshake`) | **ЕСТЬ** (отдает cert) | **P1 (Критично)** | Сканеры цензора вычисляют домен по IP за 1 запрос |
| **Отсутствие OCSP Stapling** | **ЕСТЬ** | **ЕСТЬ** | **P2 (Высокий)** | Эвристический скоринг ТСПУ метит сервер как proxy-only |
| **Несоответствие транспорта xHTTP** | Нет (нативный h2c) | **ЕСТЬ** (`grpc_pass`) | **P2 (Высокий)** | Ошибки при передаче chunked GET/Downlink, оверхед |
| **Легаси регекс прокси портов** | Нет | **ЕСТЬ** (`include.conf`) | **P2 (Высокий)** | Потенциальный SSRF к внутренним портам через HTTP |
| **TCP Fast Open только Client** | Нет (`tfo=3`) | **ЕСТЬ** (`tfo=1`) | **P3 (Средний)** | Лишний RTT на установление сессии с клиентами |
| **xMux `maxConcurrency = 0`** | **ЕСТЬ** | **ЕСТЬ** | **P3 (Средний)** | Торрент / 4K-стрим замораживает интерактивный трафик |
| **Устаревшие сьюты `HIGH:...`** | **ЕСТЬ** | **ЕСТЬ** | **P3 (Низкий)** | Согласование неоптимальных шифров на мобильных устройствах |

---

## 3. Архитектурные решения и техническое обоснование («Почему именно так»)

### 3.1 Защита от активных сканеров SNI на Сервере 2
* **Выбранное решение:**
  Настройка дефолтного сервер-блока на сокете `proxy_protocol`:
  ```nginx
  server {
      listen unix:/dev/shm/nginx-http.sock ssl default_server proxy_protocol;
      ssl_reject_handshake on;
  }
  ```
* **Почему именно так:**
  Директива `ssl_reject_handshake on` появилась в Nginx 1.19.4+. Она инструктирует TLS-стек завершать хэндшейк фатальным алертом `unrecognized name` (код `000` в curl) **до** отправки серверного сертификата. Сканер не получает публичный ключ и не может сопоставить IP-адрес с доменом `musicdownloader.verymad.net`.

### 3.2 Реализация OCSP Stapling в Nginx
* **Выбранное решение:**
  ```nginx
  ssl_stapling on;
  ssl_stapling_verify on;
  ssl_trusted_certificate /etc/letsencrypt/live/ДОМЕН/chain.pem;
  resolver 1.1.1.1 8.8.8.8 127.0.0.53 valid=300s;
  resolver_timeout 5s;
  ```
* **Почему именно так:**
  1. `ssl_trusted_certificate` обязан указывать на `chain.pem` (промежуточный сертификат Let's Encrypt R3/YR2), чтобы Nginx мог проверить подпись OCSP-ответа центра сертификации.
  2. `resolver` необходим Nginx для фонового обращения к OCSP-серверу Let's Encrypt (`http://r3.o.lencr.org`). Локальный кеш `127.0.0.53` и внешние `1.1.1.1`/`8.8.8.8` гарантируют доступность резолвинга даже при временных сбоях локального `systemd-resolved`.
  3. Клиент получает доказательство валидности сертификата прямо в `ServerHello` (0 RTT), имитируя поведение крупных белых веб-ресурсов.

### 3.3 Унификация проксирования xHTTP на Сервере 2
* **Выбранное решение:**
  1. Перевод L4 stream upstream на RAM-сокет: `server unix:/dev/shm/nginx-http.sock;`.
  2. Замена блока `location /api/library/stream/...` на нативный HTTP/2 cleartext (h2c) прокси:
     ```nginx
     location /api/library/stream/VyfRiF3d/chunks/ {
         if ($request_method !~ ^(GET|POST)$) {
             return 404;
         }
         proxy_http_version 2;
         proxy_pass http://127.0.0.1:13806;
         proxy_socket_keepalive on;
         proxy_request_buffering off;
         proxy_buffering off;
         client_max_body_size 0;
         proxy_read_timeout 1h;
         proxy_send_timeout 1h;
         client_body_timeout 1h;
         proxy_set_header Host $host;
         proxy_set_header X-Real-IP $remote_addr;
         proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
         proxy_set_header X-Forwarded-Proto $scheme;
     }
     ```
* **Почему именно так:**
  - `grpc_pass` оборачивает поток в фреймы gRPC (`application/grpc`), что является оверхедом и конфликтует с чистым xHTTP транспортом в Xray core v26.x.
  - Разрешение `GET|POST` необходимо, так как спецификация xHTTP `stream-one` использует метод `GET` для Downlink-стрима и `POST` для Uplink-данных. Ограничение `if ($request_method != POST)` на Сервере 2 блокировало штатную работу клиентов, использующих раздельные сессии.
  - Сокет в `/dev/shm` исключает сетевой стек TCP loopback (`127.0.0.1:7443`), снижая задержку на 1–2 мс и разгружая системные вызовы ядра.

### 3.4 Оптимизация xMux (`maxConcurrency: 16`, `maxConnections: 2-4`)
* **Выбранное решение:**
  Обновление `stream_settings` в базе `/etc/x-ui/x-ui.db`:
  `"maxConcurrency": 16`, `"maxConnections": "2-4"`.
* **Почему именно так:**
  При значении `0` (unlimited) все вкладки браузера, фоновые загрузки и стримы складываются в один HTTP/2 TCP-канал. Если один стрим начинает скачивать тяжелый файл, он насыщает окно управления потоком (Flow Control Window), вызывая джиттер интерактивных соединений. Лимит `16` с пулом `2-4` соединений дает идеальный баланс: тяжелый поток изолируется в отдельное физическое соединение, а интерактивные запросы идут без задержек.

---

## 4. Пошаговая декомпозиция реализации (Execution Plan)

### Этап 0: Создание контрольных точек и резервных копий
1. **Сервер 1:**
   - Резервная копия Nginx: `cp -r /etc/nginx /etc/nginx.bak_$(date +%s)`
   - Резервная копия БД: `cp /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.bak_$(date +%s)` + `sqlite3 /etc/x-ui/x-ui.db "PRAGMA integrity_check;"`
2. **Сервер 2:**
   - Резервная копия Nginx: `cp -r /etc/nginx /etc/nginx.bak_$(date +%s)`
   - Резервная копия БД: `cp /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.bak_$(date +%s)` + `sqlite3 /etc/x-ui/x-ui.db "PRAGMA integrity_check;"`

---

### Этап 1: Исправление Сервера 2 (`194.76.168.20`)
1. **[MODIFY] `/etc/nginx/stream-enabled/stream.conf`**:
   - Переключить `upstream www` на сокет `server unix:/dev/shm/nginx-http.sock;`.
2. **[MODIFY] `/etc/nginx/sites-available/musicdownloader.verymad.net`**:
   - Добавить дефолтный сервер-заглушку `ssl_reject_handshake on;` на сокете `unix:/dev/shm/nginx-http.sock`.
   - Перевести основной сервер на сокет `listen unix:/dev/shm/nginx-http.sock ssl proxy_protocol;`.
   - Включить `http2 on;` вместо устаревшего параметра в `listen`.
   - Внедрить блок `ssl_stapling on;`, `ssl_stapling_verify on;`, `ssl_trusted_certificate`.
   - Заменить `grpc_pass` на нативный `proxy_http_version 2; proxy_pass http://127.0.0.1:13806;` с поддержкой `GET|POST`.
   - Обновить шифросьюты до профиля Mozilla Intermediate:
     ```nginx
     ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
     ssl_prefer_server_ciphers off;
     ```
3. **[MODIFY] `/etc/nginx/snippets/includes.conf`**:
   - Закомментировать или удалить небезопасный регекс `location ~ ^/(?<fwdport>\d+)/`.
4. **[MODIFY] `/etc/sysctl.d/99-network-tuning.conf`**:
   - Установить `net.ipv4.tcp_fastopen = 3`.
   - Применить: `sysctl -p /etc/sysctl.d/99-network-tuning.conf`.
5. **Валидация и перезапуск Nginx**:
   - Запуск `nginx -t`. При успехе: `systemctl reload nginx`.

---

### Этап 2: Обновление Сервера 1 (`13.143.193.207`)
1. **[MODIFY] `/etc/nginx/sites-available/mymusicdownload.verymad.net`**:
   - Внедрить блок `ssl_stapling on;`, `ssl_stapling_verify on;`, `ssl_trusted_certificate`.
   - Обновить шифросьюты до профиля Mozilla Intermediate.
2. **Валидация и перезапуск Nginx**:
   - Запуск `nginx -t`. При успехе: `systemctl reload nginx`.

---

### Этап 3: Оптимизация параметров xMux в базе данных 3X-UI (Оба сервера)
1. **Сервер 1:**
   - Выполнить точечный SQLite `UPDATE` поля `stream_settings` для инбаунда `vless`:
     Установить `"maxConcurrency": 16` и `"maxConnections": "2-4"`.
   - Перезапустить Xray через 3X-UI API или `systemctl restart x-ui`.
2. **Сервер 2:**
   - Выполнить аналогичный `UPDATE` в `/etc/x-ui/x-ui.db`.
   - Перезапустить Xray: `systemctl restart x-ui`.

---

### Этап 4: Верификация и стресс-тестирование (Verification & Acceptance)
1. **Проверка OCSP Stapling:**
   ```bash
   echo "Q" | openssl s_client -connect 127.0.0.1:443 -servername <ДОМЕН> -status 2>/dev/null | grep -A 5 "OCSP Response Status"
   ```
   *Ожидаемый результат:* `OCSP Response Status: successful (0x0)`.
2. **Проверка отбоя чужого SNI на Сервере 2:**
   ```bash
   curl -skv --resolve "probe-scanner.test:443:127.0.0.1" https://probe-scanner.test/ --max-time 3
   ```
   *Ожидаемый результат:* Ошибка рукопожатия TLS `unrecognized name` (код 000), сертификат НЕ отдается.
3. **Проверка легитимного трафика маскировки:**
   ```bash
   curl -skv --resolve "<ДОМЕН>:443:127.0.0.1" https://<ДОМЕН>/ --max-time 3
   ```
   *Ожидаемый результат:* `HTTP/2 200`, отдача интерфейса `music-manager`.
4. **Проверка работоспособности Google AI:**
   - Прогон контрольных запросов к 10 эндпоинтам Google AI через `127.0.0.1:LOCAL_PORT` (все 10 PASS).
5. **Проверка статуса сервисов:**
   - `systemctl is-active x-ui nginx` -> `active active`.

---

## 5. Анализ рисков и план отката (Rollback Strategy)

| Риск | Вероятность | Влияние | Стратегия предотвращения и отката |
| :--- | :---: | :---: | :--- |
| **Ошибка синтаксиса в Nginx** | Низкая | Высокое | Обязательный запуск `nginx -t` перед вызовом `systemctl reload`. При ошибке откат конфига из `.bak`. |
| **Сбой резолвера Let's Encrypt OCSP** | Низкая | Среднее | Добавление множественных DNS-серверов в директиву `resolver` (`1.1.1.1 8.8.8.8 127.0.0.53`). |
| **Повреждение SQLite БД при UPDATE** | Низкая | Высокое | Фиксация целостности через `PRAGMA integrity_check;` до и после миграции. Наличие мгновенного `.bak`. |
| **Разрыв активных клиентских сессий** | Крайне низкая | Низкое | Использование `systemctl reload nginx` (Graceful reload без сброса открытых соединений). |

---

## 6. Критерии приемки (Definition of Done)
- [ ] Сервер 2 при сканировании с произвольным SNI разрывает соединение без выдачи сертификата.
- [ ] Оба сервера отдают валидный OCSP Stapling ответ в `openssl s_client -status`.
- [ ] На Сервере 2 путь xHTTP проксируется через HTTP/2 Cleartext без директивы `grpc_pass`.
- [ ] Все фоновые службы (`x-ui`, `nginx`, `music-manager`) находятся в статусе `active (running)`.
- [ ] Доступность Google AI и GeoHide DoH сохранена на 100% (10 из 10 проверок PASS).
- [ ] На обоих серверах актуализированы журналы изменений и сохранены бэкапы.
