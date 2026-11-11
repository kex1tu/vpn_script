# Аудит развёртывания и настройки xHTTP — 2026-11-11

Статус: DONE. Контейнерная приёмка Linux/amd64 пройдена.

- [x] Добавить порт сервиса прикрытия и сохранение итогового origin.
- [x] Добавить локальный экспорт xHTTP и опциональный HTTPS-маршрут с аутентификацией.
- [x] Исправить проверку слушателей, порядок проверки SQLite-снимка и обработку ответов Nginx.
- [x] Исправить смену слушателей `ssh.socket` при откате после загрузки.
- [x] Завершить amd64-матрицу, проверить итоговый diff и записать результаты в [walkthrough.md](walkthrough.md).

## Заметки предыдущего прохода

Статус на момент записи: IN_PROGRESS.

- [ ] 1.1 [P1] Проверка слушателя SSH при `ssh.socket` и сохранение порта при интерактивном запуске (`script.sh`, `lib/deployment.sh`)
- [ ] 1.2 [P1] Безопасная обработка восстановления прерванной транзакции на старте (`script.sh`)
- [ ] 1.3 [P2] Сохранение `Username` и `Password` в `/var/lib/vpn-script/credentials` при повторном запуске (`script.sh`)
- [ ] 1.4 [P2] Защита от записи пустых заголовков в `xhttpSettings` при миграции БД (`script.sh`)
- [ ] 1.5 [P2] Устойчивость проверок Nginx (`nginx -T` / `nginx -t`) при обновлении и корректный поиск `include` (`script.sh`)
- [ ] 1.6 [P2] Согласование `legacy_resource()` и `managed_files` (`lib/deployment.sh`)
- [ ] 1.7 [P3] Усиление preflight-проверок в режиме `-dry_run y` (`script.sh`)
- [ ] 1.8 [P3] Очистка шаблона Nginx ($safe/$hack), мёртвого кода и устранение subshell-бага в `make_port` (`script.sh`)
- [ ] 2.1 Регрессионные тесты в `test_script.sh` и `tests/`
- [ ] 2.2 Docker-проверки синтаксиса (`bash -n`, `py_compile`) и базовый сьют (`test_script.sh`)
- [ ] 2.3 Полный матричный прогон amd64 (Ubuntu 22.04, Ubuntu 24.04, Debian 12): `docker-matrix.sh`, `docker-systemd.sh`, `docker-external.sh`
- [ ] 2.4 Аудит безопасности итогового diff и фиксация доказательств в `walkthrough.md`

---

# Исторические задачи: REALITY Steal-Oneself и Classic — 2026-11-09

Статус: ЗАВЕРШЕНО в предыдущей сессии.
