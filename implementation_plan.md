# Исправления по ревью документации — 2026-11-11

## Текущая итерация

1. Сверить команды миграции, поведение dry-run, значения по умолчанию, откат SSH и восстановление базы с установщиком и библиотеками.
2. Уточнить схему публичных и локальных слушателей, объём проверок аудита и результаты контейнерной приёмки.
3. Проверить локальные ссылки, блоки Markdown, изменённую схему и итоговый diff. Критерий готовности — команды и описания соответствуют текущему коду, статус приёмки отражает сценарии и коды завершения.

Неверное описание отката или пути к снимку может задержать восстановление. Исправления ограничены документацией.

---

# Обновление и синхронизация документации — 2026-11-11 (Историческая итерация)

## План предыдущей итерации

1. Актуализировать [README.md](README.md):
   - Добавить бейджи версии Nginx Mainline 1.31.8 и актуального Docker QA (12/12 PASS, матрица amd64).
   - Дополнить справочник аргументов (раздел 1.4) недостающими флагами управления SSH (`-ssh_confirm`, `-ssh_rollback`), указать явные значения по умолчанию для каждого флага и упомянуть системную команду `/usr/local/sbin/vpn-script`.
   - Дополнить архитектурную Mermaid-диаграмму веткой скачивания клиентской конфигурации xHTTP через HTTPS с Basic Auth.
   - Детализировать 6 генерируемых клиентских ссылок и сценарий запуска локального Xray SOCKS5-прокси (`127.0.0.1:10808`) через экспортированный JSON.
   - Синхронизировать раздел 7.1 тестирования с текущим `test_script.sh` (12 поведенческих проверок вместо устаревшей цифры 7).
   - Расширить раздел 8 по эксплуатации, администрированию и аудиту: описать все проверки скрипта `audit.sh`, права файлов состояния и диагностику.
2. Синхронизировать [PROJECT_CONTEXT.md](PROJECT_CONTEXT.md), [task.md](task.md) и [walkthrough.md](walkthrough.md) с коммитом `8f498e2`.
3. Провести статическую валидацию документации: проверка Markdown-ссылок, закрытия блоков кода и синтаксиса Mermaid.

---

# Аудит развёртывания и настройки xHTTP — 2026-11-11 (Историческая итерация)

1. Проверить рабочую ревизию в Docker и устранить подтверждённые дефекты preflight, проверки listeners, генерации Nginx и восстановления.
2. Добавить `-mask_port`, сохранить итоговый origin и проверить его применение в Nginx и Hysteria 2.
3. Экспортировать Xray-клиент xHTTP/TLS в настраиваемый локальный JSON-файл с правами 0600. Опциональный точный HTTPS-маршрут защищается отдельным паролем и не кэширует ответ. Проверить конфликт с панелью и транспортом, сохранение параметров при повторе, перенос пути и очистку при отключении.
4. Воспроизвести и устранить конфликт дескрипторов при восстановлении `ssh.socket` после загрузки Debian 12. Повторить режимы service/socket с настоящим systemd.
5. Проверить изоляцию, синтаксис Shell/Python, Nginx и Xray, базовый сьют и три профиля Docker QA на целевых amd64-системах. Зафиксировать результаты текущего diff и любые пропуски.

Риски: выдача клиентского секрета без проверки пароля, перезапись чужого файла, конфликт порта с внутренним listener, применение повреждённого снимка. Проверки должны покрыть эти сценарии и сохранить существующие идентификаторы клиентов.

## Заметки предыдущего прохода

## 1. Контекст и цели
В ходе аудита установщика и вспомогательных библиотек выявлены дефекты развертывания, миграции и восстановления:
1. Ошибка проверки слушателя SSH при активном `ssh.socket` (`systemd`), а также безусловный сброс порта в интерактивном режиме на 60022 с ненужным выставлением `SSH_PORT_EXPLICIT=y`.
2. Падение при старте по `ERR`-trap вместо штатного сообщения об ошибке при сбое `deployment_active` или `deployment_rollback`.
3. Утеря сохранённых учётных данных `Username:` и `Password:` в `/var/lib/vpn-script/credentials` при повторном запуске на узле с уже настроенной учётной записью.
4. Появление пустых строк `xPaddingKey`, `xPaddingHeader`, `sessionIDKey`, `seqKey` в `xhttpSettings` и клиентских ссылках при обновлении узлов без кастомных заголовков.
5. Чувствительность к ошибкам в существующих конфигах Nginx при вызовах `nginx -T` и раннем `nginx -t`, а также хрупкое регулярное выражение поиска `include sites-enabled`.
6. Несоответствие `legacy_resource()` фактически генерируемым и историческим файлам (`banaction = iptables-allports`, `vpn-script.conf`, `upstream www`).
7. Отсутствие безопасной обработки интерфейсов и zone id в `dns_preflight_check` и пропуск проверки версии панели при `-dry_run y`.
8. Мёртвый код в шаблоне Nginx (`$safe`, `$hack`), неиспользуемые функции/переменные и потеря мутации `USED_PORTS` из-за subshell в `make_port`.

Все исправления выполняются строго по правилам `AGENTS.md`. Исходные пользовательские изменения в рабочей копии сохраняются. Все проверки исполняемого кода проводятся исключительно внутри Docker.

---

## 2. Детализация изменений

### 2.1. [P1] SSH listener (`ssh.socket`) и сохранение порта (`script.sh`, `lib/deployment.sh`)
- В `lib/deployment.sh`: в `check_listener` использовать сопоставление по регулярному выражению `$0 ~ "\"(" proc ")\""`, позволяя передавать составные имена процессов (например, `sshd|systemd`).
- В `script.sh`:
  - Определять владельца сокета SSH: если `systemctl is-active --quiet ssh.socket`, то процесс — `"sshd|systemd"`, иначе `"sshd"`.
  - Проверять доступность `$SSH_PORT` через `check_listener "$SSH_PORT" t available "$ssh_proc"` для любого порта (убрав ограничение `if [[ "$SSH_PORT" != 22 ]]`).
  - При пустом `-ssh_port`:
    - Извлекать сохранённый порт из `$STATE_DIR/config.json` (`ssh_port`) или через `ssh_migration_current_port`.
    - Для интерактивного режима (`-t 0 && "$AUTODOMAIN" != y`): предлагать дефолтный порт из `config.json` (если есть), либо текущий слушатель (если не 22), либо 60022 (чистая установка).
    - Выставлять `SSH_PORT_EXPLICIT=y` только если введённый порт отличается от текущего активного порта SSH (или если был явно передан `-ssh_port`).

### 2.2. [P1] Безопасная обработка прерванной транзакции на старте (`script.sh`)
- Обернуть вызовы `deployment_active` и `deployment_rollback` в защитный блок:
  ```bash
  if [[ -e "$STATE_DIR/active" ]]; then
      if ! pending_deployment=$(deployment_active); then
          deployment_error "Cannot read the deployment recovery journal"
          exit 1
      fi
      if ! deployment_rollback "$pending_deployment"; then
          printf 'Rollback incomplete. Recovery data: %s\n' "$pending_deployment" >&2
          exit 1
      fi
  fi
  ```

### 2.3. [P2] Сохранение `Username` и `Password` в `credentials` (`script.sh`)
- При повторном прогоне, если `-z "$config_password"`, проверять существующий `$STATE_DIR/credentials` (или архивную копию в `$DEPLOYMENT/files/`):
  - Извлекать `Username:` и `Password:`.
  - Сверять `Username` с `SELECT username FROM users ORDER BY id LIMIT 1;` в `$XUIDB`.
  - Если совпадают — сохранять их для записи в `$STATE_DIR/credentials.new`.
  - Права файла строго `0600`, секреты не логировать.

### 2.4. [P2] Защита от пустых заголовков в `xhttpSettings` (`script.sh`)
- В Python-блоке `UPDATE_XUIDB`:
  - Всегда присваивать `"path": path`.
  - Для `xPaddingKey`, `xPaddingHeader`, `sessionIDKey`, `seqKey`: присваивать значение только если оно непустое (`if value: xhttp[name] = value`).
  - Если значение пустое, удалять пустые строки из `xhttp`, чтобы они не попадали в клиентские ссылки.

### 2.5. [P2] Устойчивость Nginx (`nginx -T` / `nginx -t`) и `include` regex (`script.sh`)
- Заменить `grep -Eq '^ *include +/etc/nginx/sites-enabled/\*;'` на `grep -Eq '^[[:space:]]*include[[:space:]]+/etc/nginx/sites-enabled/\*;'`.
- Вызов `nginx -T > "$DEPLOYMENT/nginx-before.conf" 2>&1 || true` защитить от ненулевого кода возврата; проверку наличия `server_names_hash_bucket_size` и `map_hash_bucket_size` выполнять с учётом того, что в `00-vpn-script-http.conf` они ещё не должны считаться пользовательскими.
- Перед `nginx -t` для `80.conf` удалять старый симлинк `rm -f "/etc/nginx/sites-enabled/$domain"`, восстанавливая его только на этапе публикации полного vhost (после получения сертификатов и записи snippets).

### 2.6. [P2] Согласование `legacy_resource()` (`lib/deployment.sh`)
- Для `/etc/fail2ban/jail.d/99-sshd.local`: разрешить `(grep -Fq 'banaction = ufw' "$path" || grep -Fq 'banaction = iptables-allports' "$path") && grep -Fq 'findtime  = 600' "$path"`.
- Для systemd drop-in: поддерживать пути `.../{override,vpn-script}.conf` с телом `$'[Service]\nLimitNOFILE=65535'`.
- Для `/etc/nginx/stream-enabled/stream.conf`: проверять наличие `/dev/shm/nginx-http.sock` и (`upstream reality_failover` или `upstream www`).

### 2.7. [P3] Preflight-проверки в `-dry_run y` (`script.sh`)
- В `dns_preflight_check`:
  - Использовать `addr["local"].split("%", 1)[0]` с фильтром `if "local" in addr`.
  - Добавить `KeyError` в кортеж обрабатываемых исключений.
- Создать функцию `check_installed_panel_version` и вызывать её в preflight **до** выхода при `DRY_RUN=y`.

### 2.8. [P3] Очистка шаблона Nginx, мёртвого кода и `make_port` (`script.sh`)
- Удалить из шаблона Nginx строки с `$safe` и `$hack`.
- В `make_port`: поддерживать аргумент имени переменной (`make_port varname`) для прямого присвоения через `printf -v "$1" '%s' "$port"` без subshell, гарантируя сохранение `USED_PORTS["$port"]=1`.
- Удалить `sql_escape`, мёртвые переменные `PNLNUM`, `CFALLOW`, `release`, `policy_added`, `emoji_flag`, `sql_emoji_flag`, `green`, `yellow`, `red`, `blue`, `plain`. Заменить `${sql_emoji_flag}` на чистые имена в БД.

---

## 3. План тестирования и верификации
1. В Docker:
   - Проверка `bash -n` для `script.sh`, `audit.sh`, `lib/*.sh`, `test_script.sh`, `tests/*.sh`.
   - Проверка `python3 -m py_compile` для всех файлов `lib/*.py` и `tests/*.py`.
2. Регрессионные тесты в `test_script.sh`:
   - Сохранение `Username:` и `Password:` при повторном запуске.
   - Отсутствие пустых заголовков в `xhttpSettings` и `extra`.
   - Вывод `Rollback incomplete. Recovery data:` при сбое отката на старте.
   - Распознавание `banaction = iptables-allports` и `vpn-script.conf` в `legacy_resource`.
   - Прохождение проверки слушателя SSH при активном `ssh.socket`.
3. Запуск базового тест-сьюта в Docker (`test_script.sh`).
4. Запуск матричных тестов:
   - `bash tests/docker-matrix.sh`
   - `bash tests/docker-systemd.sh`
   - `bash tests/docker-external.sh`
5. Аудит безопасности итогового diff: отсутствие секретов, сохранение прав `0600`, сохранение пользовательских изменений.
6. Фиксация результатов и логов в `walkthrough.md`.
