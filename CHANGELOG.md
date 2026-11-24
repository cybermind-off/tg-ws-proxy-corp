# Changelog

TG WS Proxy Corp (Proxmox VM) — автор Cybermind.

## [1.1.0] — 2026-11-24

### Добавлено
- Ежедневное автоматическое обновление tg-ws-proxy (по умолчанию в 04:30)
  с автооткатом при сбое: `--updates auto|check|off`, `--update-time HH:MM`,
  `--update-delay N` (ставить релиз не раньше чем через N дней после выхода).
- Команда `tg-ws-proxyctl auto-update` (её запускает таймер `tg-ws-proxy-update.timer`).
- Режим обновлений и время следующего запуска в `tg-ws-proxyctl status`.
- `pve-create-tg-proxy.sh`: параметры `--updates` и `--update-time`.

### Изменено
- Еженедельная проверка (`tg-ws-proxy-update-check.timer`) заменена ежедневным
  таймером `tg-ws-proxy-update.timer`; старый таймер удаляется автоматически.
- Режим по умолчанию — `auto`. Конфигурации 1.0.0 с `--no-timer` переходят в `off`.

### Переход с 1.0.0
На VM: скопировать новый `tg-ws-proxyctl.sh` и выполнить
`sudo bash tg-ws-proxyctl.sh install` — настройки и секрет сохранятся,
включится ежедневное автообновление.

## [1.0.0] — 2026-11-24

Первый публичный выпуск.

### Возможности
- `pve-create-tg-proxy.sh` — создание VM на Proxmox VE из облачного образа Debian 12/13
  (проверка SHA512, cloud-init, guest agent, автозапуск, VLAN) с автоматической
  установкой tg-ws-proxy и выводом ссылки для сотрудников.
- `tg-ws-proxyctl.sh` — установка tg-ws-proxy из релизов оригинального проекта
  в виртуальное окружение Python, systemd-служба с изоляцией, ротация логов.
- Команды `install`, `apply`, `update` (с автооткатом), `check`, `status`, `link`,
  `rotate-secret`, `version`, `uninstall`.
- Ограничение доступа по подсетям через ufw/firewalld, режим `--firewall ufw`
  с автоматическим включением ufw.
- Еженедельная проверка новых версий tg-ws-proxy (без автоустановки).
- Ссылки `tg://` и `https://t.me/proxy`, QR-код.

### Исправлено в ходе тестирования
- Запуск прокси как модуля (`python -m proxy.tg_ws_proxy`): при запуске файлом
  `proxy/utils.py` перекрывал пакет `utils/`.
- Ожидание фонового apt на свежей VM без ложных срабатываний на
  `unattended-upgrade-shutdown`.
- Любая ошибка установки помечается в логе `[ошибка]`; скрипт создания VM
  определяет сбой по статусу cloud-init и показывает логи вместо долгого ожидания.
- Таймауты для git и pip при проблемах с сетью.
