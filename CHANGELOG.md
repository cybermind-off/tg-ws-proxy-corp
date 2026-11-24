# Changelog

TG WS Proxy Corp (Proxmox VM) — автор Cybermind.

## [Unreleased]

### Исправлено
- `pve-create-tg-proxy.sh`: VM создаётся с устройством balloon (без `--balloon 0`),
  чтобы Proxmox показывал реальный расход памяти гостя, а не >100% вместе с кешем.
  Для уже созданных VM: `qm set <VMID> --delete balloon && qm reboot <VMID>`.

## [1.2.0] — 2026-11-24

### Добавлено
- Самообновление `tg-ws-proxyctl`: в режиме `--updates auto` ночной таймер сначала
  проверяет последний релиз `cybermind-off/tg-ws-proxy-corp`, ставит новую версию
  скрипта, применяет настройки и затем обновляет tg-ws-proxy уже новой версией.
- Проверка SHA256 скачанного скрипта, защита от понижения версии, откат на
  предыдущую версию скрипта, если новая не применилась.
- Команда `tg-ws-proxyctl self-update [--check]`, параметры `--self-update yes|no`
  и `--self-update-repo OWNER/REPO`.
- В релизы добавлен файл `SHA256SUMS`.

### Переход с 1.0.0 / 1.1.0
Один раз обновите скрипт вручную (старые версии не умеют самообновляться):
```bash
curl -fsSL https://github.com/cybermind-off/tg-ws-proxy-corp/releases/latest/download/tg-ws-proxyctl.sh -o /tmp/tg-ws-proxyctl.sh
sudo bash /tmp/tg-ws-proxyctl.sh install
```
Дальше новые версии будут приходить сами.

## [1.1.0] — 2026-11-24

### Добавлено
- Ежедневное автоматическое обновление tg-ws-proxy (по умолчанию в 04:30)
  с автооткатом при сбое: `--updates auto|check|off`, `--update-time HH:MM`,
  `--update-delay N` (ставить релиз не раньше чем через N дней после выхода).
- Команда `tg-ws-proxyctl auto-update` (её запускает таймер `tg-ws-proxy-update.timer`).
- Режим обновлений и время следующего запуска в `tg-ws-proxyctl status`.
- `pve-create-tg-proxy.sh`: параметры `--updates` и `--update-time`.
- Автоматическое оформление релизов через GitHub Actions: тег, описание из
  `CHANGELOG.md` и оба скрипта в приложении к релизу.

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
