# Архитектурный план: Комплексное усиление сервера и внедрение резервного туннеля Hysteria 2

**Дата:** 24 сентября 2026 г.  
**Статус:** `PROPOSED` (Ожидает согласования)  
**Целевые компоненты:** [`script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh), [`Dockerfile.test`](file:///home/kex1tu/Рабочий%20стол/vpn_script/Dockerfile.test), [`test_script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/test_script.sh)  
**Автор:** `orchestrator-agent` & `devops-architect-agent`

---

## 1. Цель и границы задачи (Objective & Scope)

### 1.1 Цель
Реализовать второй этап модернизации серверной инфраструктуры `vpn_script`:
1. **SSH Hardening:** Перенос службы OpenSSH со стандартного порта `22/tcp` на выделенный высокий порт (по умолчанию `60022/tcp` или настраиваемый через аргумент `-ssh_port`), обновление правил UFW и конфигурации демона sshd без риска потери доступа администратора.
2. **Fail2ban SSH Jail:** Развертывание джейла `[sshd]` с баном атакующих IP на 24 часа (86400 сек) после 3 неудачных попыток аутентификации через интеграцию с UFW.
3. **Automated Security Updates (`unattended-upgrades`):** Настройка автоматической установки критических обновлений безопасности ядра Linux и пакетов дистрибутива без необходимости ручного входа на сервер.
4. **TCP Fast Open (TFO):** Включение параметра ядра `net.ipv4.tcp_fastopen = 3` в `/etc/sysctl.d/99-xui-tuning.conf` для 0-RTT сокращения сетевых задержек при повторных рукопожатиях.
5. **Hysteria 2 UDP Inbound (Резервный туннель):** Добавление второго полнофункционального протокола Hysteria 2 в ядро Xray/3X-UI на порту `443/udp` (L4 мультиплексирование с Nginx на 443/tcp), с маскировкой трафика (`masquerade: { type: "proxy", url: "http://127.0.0.1:80" }`), ALPN `h3`, TLS 1.3 с боевыми сертификатами Let's Encrypt и выводом готовой ссылки `hysteria2://...` в финальную сводку.

### 1.2 Границы задачи (Scope)
- **In-Scope:**
  - Добавление CLI-аргумента `-ssh_port` и безопасной функции миграции SSH-порта.
  - Настройка UFW: открытие нового SSH-порта, закрытие старого 22/tcp (при смене порта), открытие `443/udp` для Hysteria 2.
  - Конфигурация Fail2ban джейла `/etc/fail2ban/jail.d/99-sshd.local` с бэкендом UFW и защитой от сбоев отсутствия auth.log.
  - Установка и тюнинг `unattended-upgrades` (`20auto-upgrades` и `50unattended-upgrades`).
  - Расширение `/etc/sysctl.d/99-xui-tuning.conf` директивой `net.ipv4.tcp_fastopen = 3`.
  - Генерация инбаунда Hysteria 2 в SQLite `x-ui.db` (`inbounds` + `client_traffics`).
  - Генерация прямой клиентской ссылки `hysteria2://${client_id}@${domain}:443/?sni=${domain}&alpn=h3#${domain}-Hysteria2`.
  - Обновление процедуры деинсталляции `UNINSTALL_XUI`.
  - Обновление Docker-сьюта тестирования в [`test_script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/test_script.sh) (новые тесты 45–51) с валидацией строго в Docker-контейнере.
- **Out-of-Scope:**
  - Возврат сторонних конвертеров подписок (sub2sing-box, clash) — сохраняется строгая монолитная архитектура прямых URI.
  - Изменение архитектуры VLESS-xHTTP — xHTTP остается основным стелс-протоколом.

---

## 2. Анализ текущего состояния (Current State Analysis)

1. **SSH и файрвол ([`script.sh:1275`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh#L1275), [`script.sh:1428`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh#L1428)):**
   - Сейчас в UFW захардкожено правило `ufw allow 22/tcp || true`.
   - Порт 22 подвержен постоянному фоновому сканированию ботнетами, что приводит к раздуванию `/var/log/auth.log`, расходу процессорного времени и рискам эксплуатации уязвимостей в OpenSSH.
2. **Fail2ban ([`script.sh:1353-1386`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh#L1353-L1386)):**
   - Настроен джейл `99-nginx-probe.local` для защиты веб-сервера от зондирования.
   - Защита SSH от брутфорса паролей отсутствует в явном виде.
3. **Обновления безопасности ([`script.sh:150-196`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh#L150-L196)):**
   - Пакет `unattended-upgrades` не входит в перечень устанавливаемых пакетов. Сервер не получает автоматических исправлений уязвимостей ядра и библиотек.
4. **Сетевой стек sysctl ([`script.sh:1200-1249`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh#L1200-L1249)):**
   - Применяется оптимизация BBR, буферов UDP/TCP и сокетов, но `net.ipv4.tcp_fastopen` не определен (в Linux по умолчанию значение 1 — только клиент, либо 0 — выключен).
5. **Инбаунды X-UI ([`script.sh:717-815`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh#L717-L815)):**
   - В базе создается единственный инбаунд `vless` на локальном порту xHTTP.
   - Сетевой порт `443/udp` свободен (Nginx слушает только TCP 443 и TCP 80). Xray-core нативной версии 24.11+ / 26.6+ поддерживает QUIC-транспорт Hysteria 2, однако конфигурация инбаунда в базе отсутствует.

---

## 3. Архитектурное решение и обоснование (Architecture & Rationale)

### 3.1 Концептуальная схема взаимодействия портов и протоколов
```
                      [ Входящий Интернет-трафик ]
                                   │
         ┌─────────────────────────┴─────────────────────────┐
         │                                                   │
    [ TCP: 443 ]                                        [ UDP: 443 ]
         │                                                   │
   Nginx L4 Stream Router                                Xray-core
   (ssl_preread on)                                 (Hysteria 2 Inbound)
         │                                                   │
 ┌───────┴───────┐                                           │
 │ SNI = domain  │ Иной SNI / прямой IP                      │
 │               │ (Fallthrough)                             │
 ▼               ▼                                           │
Nginx L7      Fake Site                                      │
Reverse Proxy (80/tcp)                                       │
 │                                                           │
 │ xHTTP /videos/...                                         │
 ▼                                                           │
Xray-core VLESS                                              │
(127.0.0.1:xhttp_port)                                       │
                                                             │
                  Если Hysteria 2 получает зондирующий запрос:
                                     │
                                     ▼
                      Masquerade Proxy -> http://127.0.0.1:80
                                (Fake Site)
```

### 3.2 Детальное обоснование принятых решений («Why, not What»)

#### А. Мультиплексирование TCP/443 и UDP/443 без конфликтов
- **Почему именно так:** В модели OSI и сетевом стеке ядра Linux сокеты `AF_INET, SOCK_STREAM` (TCP) и `AF_INET, SOCK_DGRAM` (UDP) полностью изолированы. Nginx слушает `listen 443;` (TCP), а Xray Hysteria 2 слушает `listen 0.0.0.0:443 udp`. Между ними нет конфликта портов (`EADDRINUSE`).
- **Преимущество:** Пользователь получает два независимых туннеля на одном и том же стандартном порту 443:
  1. *Основной:* Стелс-туннель VLESS-xHTTP (TCP) под видом легитимного веб-сайта с SNI-роутингом.
  2. *Резервный:* Сверхскоростной туннель Hysteria 2 (UDP/QUIC) с контролем перегрузок Brutal, спасающий при нестабильном пинге, потерях пакетов или деградации TCP.

#### Б. Маскировка Hysteria 2 (`masquerade: { type: "proxy", url: "http://127.0.0.1:80" }`)
- **Почему именно так:** Если активный сетевой сканер отправляет HTTP/3 GET-запрос на порт 443/udp сервера без валидных учетных данных Hysteria 2, Xray проксирует этот запрос на локальный Nginx (`127.0.0.1:80`), который отдает легитимный Fake Site. В результате для внешнего наблюдателя сервер выглядит как обычный веб-сервер с поддержкой HTTP/3.

#### В. Безопасная миграция SSH-порта через drop-in конфигурацию
- **Почему именно так:** Редактирование основного `/etc/ssh/sshd_config` часто ломается при обновлениях пакета `openssh-server` (конфликты `conffile`). Использование drop-in файла `/etc/ssh/sshd_config.d/99-custom-port.conf` является официальным стандартом в Debian 12, Ubuntu 22.04 и Ubuntu 24.04.
- **Инвариант безопасности (Fail-Safe):** До перезапуска `sshd` скрипт обязан выполнить `ufw allow ${SSH_PORT}/tcp`. Если демон упадет или порт не применится, активная SSH-сессия администратора **не разрывается**, поскольку в Linux открытые файловые дескрипторы сокетов живут до завершения процесса.

#### Г. Тюнинг `net.ipv4.tcp_fastopen = 3`
- **Почему именно значение 3:** Битовая маска в ядре Linux:
  - `1` (бит 0) — клиентский TFO.
  - `2` (бит 1) — серверный TFO.
  - `3` (биты 0 и 1) — включен TFO и для входящих соединений сервера, и для исходящих прокси-соединений Xray к целевым ресурсам. Сокращает время первого байта (TTFB) на 1 сетевой RTT.

#### Д. Автообновления `unattended-upgrades` без спонтанных перезагрузок
- **Почему именно так:** Включение `Unattended-Upgrade::Automatic-Reboot "false"` гарантирует, что production VPN-сервер не уйдет в перезагрузку посреди рабочего дня из-за обновления ядра, а обновит уязвимые библиотеки на лету.

---

### 3.3 Сравнительный анализ альтернатив (Trade-off Matrix)

| Критерий / Параметр | Выбранный подход (Drop-in + UFW + Native Hysteria 2) | Альтернатива 1: Отдельный бинарник Hysteria 2 | Альтернатива 2: Смена SSH через sed в sshd_config |
| :--- | :--- | :--- | :--- |
| **Управление процессами** | Единый демон Xray-core через 3X-UI | Лишний systemd-юнит, отдельный мониторинг | Тот же sshd |
| **Потребление RAM/CPU** | 0 накладных расходов (общий рантайм Xray) | +50-100 МБ RAM на отдельный Go-бинарник | Без изменений |
| **Устойчивость к apt upgrade** | 100% (drop-in файлы не затираются) | Требует отдельного репозитория/обновлений | Конфликт dpkg-dist при обновлении openssh |
| **Маскировка зондирования** | Нативная маскировка HTTP/3 под Fake Site | Требует настройки acme и отдельного fake | Не применимо |
| **Контроль через 3X-UI** | Статистика трафика в базе `x-ui.db` | Трафик не учитывается панелью | Не применимо |

---

## 4. Пошаговая декомпозиция реализации (Step-by-Step Implementation)

### Этап 1: Добавление CLI-аргументов и параметров SSH
- **Файл:** [`script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh) `[MODIFY]`
- **Детали:**
  - Инициализация переменной: `SSH_PORT=""` (по умолчанию 60022 при согласии пользователя или явном указании флага).
  - Добавление в блок парсинга аргументов:
    ```bash
    -ssh_port) SSH_PORT="$2"; shift 2;;
    ```
  - В интерактивном режиме: запрос порта с подсказкой рекомендуемого значения `60022` (или сохранение текущего 22 при отказе).

### Этап 2: Установка пакетов `unattended-upgrades` и `fail2ban`
- **Файл:** [`script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh) `[MODIFY]`
- **Детали:**
  - Добавить `unattended-upgrades` в список пакетов функции `install_dependencies()`.
  - Добавить функцию `setup_unattended_upgrades()`:
    - Создание `/etc/apt/apt.conf.d/20auto-upgrades`:
      ```text
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
      ```
    - Создание `/etc/apt/apt.conf.d/50unattended-upgrades`:
      ```text
      Unattended-Upgrade::Allowed-Origins {
          "${distro_id}:${distro_codename}-security";
          "${distro_id}ESMApps:${distro_codename}-apps-security";
          "${distro_id}ESM:${distro_codename}-infrastructure-security";
      };
      Unattended-Upgrade::Package-Blacklist {
      };
      Unattended-Upgrade::AutoFixInterruptedDpkg "true";
      Unattended-Upgrade::MinimalSteps "true";
      Unattended-Upgrade::InstallOnShutdown "false";
      Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
      Unattended-Upgrade::Remove-Unused-Dependencies "true";
      Unattended-Upgrade::Automatic-Reboot "false";
      ```
    - `systemctl enable --now unattended-upgrades 2>/dev/null || true`

### Этап 3: Настройка SSH-порта и UFW
- **Файл:** [`script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh) `[MODIFY]`
- **Детали:**
  - Функция `setup_ssh_port()`:
    - Валидация порта (целое число от 1024 до 65535, либо 22).
    - Если `SSH_PORT` != 22:
      1. Разрешить новый порт в UFW: `ufw allow "${SSH_PORT}/tcp" || true`.
      2. Создать `/etc/ssh/sshd_config.d/99-custom-port.conf` с содержимым `Port ${SSH_PORT}`.
      3. Проверить валидность конфигурации: `sshd -t 2>/dev/null`.
      4. Перезапустить демон SSH: `systemctl reload-or-restart ssh 2>/dev/null || systemctl reload-or-restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true`.
      5. Удалить старое правило: `ufw delete allow 22/tcp 2>/dev/null || true`.
    - Добавить `443/udp` в правила UFW:
      ```bash
      ufw allow 443/udp || true
      ```

### Этап 4: Настройка Fail2ban для SSH
- **Файл:** [`script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh) `[MODIFY]`
- **Детали:**
  - В функции `setup_fail2ban()`:
    - Создание файла `/etc/fail2ban/jail.d/99-sshd.local`:
      ```ini
      [sshd]
      enabled   = true
      port      = ${SSH_PORT:-22}
      filter    = sshd
      logpath   = /var/log/auth.log
      maxretry  = 3
      findtime  = 600
      bantime   = 86400
      banaction = ufw
      ```
    - Обеспечение наличия `/var/log/auth.log` (`touch /var/log/auth.log && chmod 640 /var/log/auth.log`) для предотвращения падений Fail2ban в контейнерах.

### Этап 5: Тюнинг ядра `net.ipv4.tcp_fastopen = 3`
- **Файл:** [`script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh) `[MODIFY]`
- **Детали:**
  - Внутри `apply_sysctl_tuning()` добавить в `/etc/sysctl.d/99-xui-tuning.conf`:
    ```ini
    # --- TCP Fast Open (0-RTT client & server handshake) ---
    net.ipv4.tcp_fastopen = 3
    ```

### Этап 6: Генерация инбаунда Hysteria 2 в SQLite `x-ui.db`
- **Файл:** [`script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh) `[MODIFY]`
- **Детали:**
  - Добавить создание второго инбаунда (`id = 2`) в `config_after_install()`:
    ```sql
    INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('2','1','firstHy2','0','0','0','0','0');
    INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES (
      '1', '0', '0', '0',
      '${sql_emoji_flag} hysteria2', '1', '0',
      '0.0.0.0', 443, 'hysteria',
      '{
        "version": 2,
        "auth": "${client_id}",
        "users": [
          {
            "auth": "${client_id}",
            "email": "firstHy2",
            "enable": true
          }
        ],
        "clients": [
          {
            "id": "${client_id}",
            "auth": "${client_id}",
            "email": "firstHy2",
            "limitIp": 0,
            "totalGB": 0,
            "expiryTime": 0,
            "enable": true
          }
        ]
      }',
      '{
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "alpn": [
            "h3"
          ],
          "minVersion": "1.3",
          "certificates": [
            {
              "certificateFile": "/root/cert/${domain}/fullchain.pem",
              "keyFile": "/root/cert/${domain}/privkey.pem"
            }
          ]
        },
        "hysteriaSettings": {
          "version": 2,
          "auth": "${client_id}",
          "udpIdleTimeout": 60,
          "masquerade": {
            "type": "proxy",
            "url": "http://127.0.0.1:80",
            "rewriteHost": true
          }
        },
        "sockopt": {
          "tcpcongestion": "bbr",
          "trustedXForwardedFor": [
            "X-Real-IP"
          ]
        }
      }',
      'in-443-udp',
      '{
        "enabled": false,
        "destOverride": ["http", "tls", "quic", "fakedns"],
        "metadataOnly": false,
        "routeOnly": false
      }'
    );
    ```

### Этап 7: Экспорт URI Hysteria 2 в финальную сводку
- **Файл:** [`script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh) `[MODIFY]`
- **Детали:**
  - Генерация переменной ссылки:
    ```bash
    CLIENT_HY2_URL="hysteria2://${client_id}@${domain}:443/?sni=${domain}&alpn=h3#${emoji_flag}%20${domain}%20(Hysteria2)"
    ```
  - Вывод в итоговом экране:
    ```text
    Direct Client Connection (Hysteria 2 UDP Backup):
    ${CLIENT_HY2_URL}
    ```
  - Если порт SSH изменен: вывод предупреждения `SSH Port: ${SSH_PORT} (Connect with: ssh -p ${SSH_PORT} root@${domain})`.

### Этап 8: Обновление логики деинсталляции `UNINSTALL_XUI`
- **Файл:** [`script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh) `[MODIFY]`
- **Детали:**
  - Удаление `/etc/fail2ban/jail.d/99-sshd.local`.
  - Удаление `/etc/ssh/sshd_config.d/99-custom-port.conf`.
  - Удаление `/etc/apt/apt.conf.d/20auto-upgrades` и `/etc/apt/apt.conf.d/50unattended-upgrades`.

---

## 5. Анализ рисков и краевых случаев (Risks, Edge Cases & Guardrails)

| Риск / Краевой случай | Вероятность / Влияние | Стратегия митигации |
| :--- | :---: | :--- |
| **Блокировка администратора (SSH Lockout)** при смене порта SSH | Средняя / Критическое | Порт UFW открывается **ДО** перезапуска демона sshd. Проверяется валидность конфигурации `sshd -t`. Текущая сессия SSH не разрывается ядром. При ошибке синтаксиса откатываемся на порт 22. |
| **Отсутствие `/etc/ssh/sshd_config.d`** на старых дистрибутивах | Низкая / Среднее | Скрипт проверяет наличие директории: если её нет, создает `mkdir -p /etc/ssh/sshd_config.d` и обеспечивает директиву `Include` в основном конфиге. |
| **Падение `fail2ban-client -t`** из-за отсутствия `/var/log/auth.log` в минимальном Docker | Высокая / Высокое | Скрипт принудительно выполняет `touch /var/log/auth.log` с правами `0640` перед запуском сервиса и в тестах. |
| **Конфликт UDP 443** с другим сервисом | Низкая / Среднее | Проверка `ss -ulnp 'sport = :443'` перед биндом, вывод понятного предупреждения в лог. |
| **Повреждение SQLite DB при добавлении инбаунда** | Низкая / Высокое | Инвариант бэкапа базы `/etc/x-ui/x-ui.db.bak_$(date +%s)` и `PRAGMA integrity_check` перед добавлением записей. |
| **Некорректный JSON в SQLite** | Низкая / Высокое | Предварительная валидация сформированного JSON через `jq .` внутри проверочных сценариев. |

---

## 6. План тестирования и верификации (Verification Matrix)

Все проверки проводятся **исключительно внутри Docker-контейнера** `xui-test` (`Dockerfile.test`).

### Новые сценарии тестирования в `test_script.sh` (Тесты 45–51):
1. **Тест 45: Валидация sysctl `net.ipv4.tcp_fastopen = 3`:**
   - Проверка наличия директивы `net.ipv4.tcp_fastopen = 3` в шаблоне `/etc/sysctl.d/99-xui-tuning.conf` в коде `script.sh`.
2. **Тест 46: Конфигурация SSH-порта и CLI-флаг `-ssh_port`:**
   - Проверка парсинга `-ssh_port 60022` и генерации `/etc/ssh/sshd_config.d/99-custom-port.conf`.
3. **Тест 47: Валидация Fail2ban SSH джейла:**
   - Генерация `99-sshd.local` с `port = 60022`, проверка синтаксиса через `fail2ban-client -t` (без ошибок бэкенда).
4. **Тест 48: Проверка конфигурации `unattended-upgrades`:**
   - Проверка генерации `20auto-upgrades` и `50unattended-upgrades` с корректными директивами в `script.sh`.
5. **Тест 49: Валидация инбаунда Hysteria 2 в SQLite:**
   - Добавление инбаунда Hysteria 2 в тестовую SQLite базу, проверка извлечения через `sqlite3`:
     - `protocol == 'hysteria'`
     - `port == 443`
     - `listen == '0.0.0.0'`
     - JSON settings валиден (`jq -e .settings`)
     - JSON stream_settings валиден (`jq -e .stream_settings`)
     - `alpn == ["h3"]`, `masquerade.url == "http://127.0.0.1:80"`
6. **Тест 50: Проверка URI ссылки Hysteria 2 в итоговой сводке:**
   - Проверка наличия `CLIENT_HY2_URL=` и строки `"Direct Client Connection (Hysteria 2 UDP Backup):"` в `script.sh`.
7. **Тест 51: Проверка правил UFW:**
   - Проверка открытия `443/udp` и кастомного SSH-порта в `script.sh`.

---

## 7. Критерии приемки (Definition of Done)

- [ ] В [`script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh) добавлены флаг `-ssh_port` и безопасная настройка SSH (drop-in + UFW + restart).
- [ ] В [`script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh) реализован джейл `99-sshd.local` Fail2ban на 24 часа.
- [ ] В [`script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh) настроен пакет `unattended-upgrades` без автоматических внезапных перезагрузок.
- [ ] В [`script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh) добавлен параметр `net.ipv4.tcp_fastopen = 3` в sysctl.
- [ ] В [`script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh) в SQLite `x-ui.db` создается инбаунд Hysteria 2 на `443/udp` с маскировкой на `http://127.0.0.1:80`.
- [ ] В [`script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/script.sh) формируется и выводится ссылка `hysteria2://${client_id}@${domain}:443/?sni=${domain}&alpn=h3#...`.
- [ ] В UFW открыт порт `443/udp`.
- [ ] В [`Dockerfile.test`](file:///home/kex1tu/Рабочий%20стол/vpn_script/Dockerfile.test) добавлены необходимые пакеты (`openssh-server`, `unattended-upgrades`).
- [ ] В [`test_script.sh`](file:///home/kex1tu/Рабочий%20стол/vpn_script/test_script.sh) добавлены тесты 45–51, и полный тестовый сьют (51 тест) успешно проходит в Docker (`51 passed, 0 failed`).
- [ ] Проведен аудит безопасности (`security-compliance-agent`) без замечаний.
