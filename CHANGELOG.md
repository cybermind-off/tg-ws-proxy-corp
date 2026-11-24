# Changelog

TG WS Proxy Corp (Proxmox VM) — автор Cybermind.

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
