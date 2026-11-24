#!/usr/bin/env bash
# =============================================================================
#  tg-ws-proxyctl — установка и обслуживание tg-ws-proxy на сервере предприятия
#
#  Часть проекта TG WS Proxy Corp (Proxmox VM), автор — Cybermind (MIT).
#  Сам прокси — tg-ws-proxy, автор Flowseal (MIT):
#      https://github.com/Flowseal/tg-ws-proxy
#  Этот скрипт только устанавливает и обслуживает его; код прокси скачивается
#  из оригинального репозитория.
#
#  Поддерживаемые ОС: Debian 11+/Ubuntu 20.04+, RHEL/Alma/Rocky 9+ (Python >= 3.8)
#
#  Быстрый старт:
#    sudo bash tg-ws-proxyctl.sh install \
#         --public-host tg-proxy.corp.local \
#         --allow 10.10.0.0/16,10.20.0.0/24
#
#  После установки скрипт доступен как команда:  tg-ws-proxyctl <команда>
#
#  Если сервер ходит в интернет через корпоративный HTTP-прокси или PyPI-зеркало,
#  запускайте с sudo -E и заранее заданными HTTPS_PROXY / PIP_INDEX_URL.
# =============================================================================
set -Eeuo pipefail
trap 'echo "[ошибка] команда завершилась с кодом $? (строка $LINENO): $BASH_COMMAND" >&2' ERR
# не ждать бесконечно при проблемах с сетью
export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=60

# ----------------------------- пути -----------------------------------------
CORP_VERSION=1.2.0
APP=tg-ws-proxy
CTL_PATH=/usr/local/sbin/tg-ws-proxyctl
INSTALL_DIR=/opt/tg-ws-proxy
SRC_DIR=$INSTALL_DIR/src
VENV=$INSTALL_DIR/venv
CONF_DIR=/etc/tg-ws-proxy
CONF=$CONF_DIR/config
FW_STATE=$CONF_DIR/.firewall-state
LINK_FILE=$CONF_DIR/link.txt
QR_FILE=$CONF_DIR/link-qr.png
LOG_DIR=/var/log/tg-ws-proxy
SVC_USER=tgproxy
UNIT=/etc/systemd/system/$APP.service
UPD_SVC=/etc/systemd/system/$APP-update.service
UPD_TIMER=/etc/systemd/system/$APP-update.timer
# старые имена (1.0.0) — удаляются при переходе
OLD_CHK_SVC=/etc/systemd/system/$APP-update-check.service
OLD_CHK_TIMER=/etc/systemd/system/$APP-update-check.timer
LOCK=/run/tg-ws-proxyctl.lock
EXIT_UPDATE_AVAILABLE=10

# ----------------------- значения по умолчанию ------------------------------
REPO_URL=https://github.com/Flowseal/tg-ws-proxy.git
VERSION=latest                 # latest = последний тег релиза; либо конкретный тег
PUBLIC_HOST=                   # DNS-имя/IP, которое попадёт в ссылку для сотрудников
LISTEN_ADDR=0.0.0.0            # на каком адресе слушать
PORT=1443
ALLOW_NETS=                    # подсети офиса и VPN через пробел/запятую
POOL_SIZE=8                    # WS-пул на каждый DC
DC_IPS="2:149.154.167.220 4:149.154.167.220"
EXTRA_ARGS=                    # доп. аргументы, напр. "--proxy-protocol"
FIREWALL=auto                  # auto | ufw | firewalld | none
UPDATE_MODE=                   # auto | check | off  (пусто = auto)
UPDATE_TIME=04:30              # время ежедневной проверки/обновления
UPDATE_DELAY_DAYS=0            # ставить релиз не раньше, чем через N дней после выхода
UPDATE_TIMER=                  # устарело (1.0.0): no = off
SELF_UPDATE=yes                # в режиме auto обновлять и сам tg-ws-proxyctl
SELF_UPDATE_REPO=cybermind-off/tg-ws-proxy-corp   # откуда брать новые версии скрипта
SECRET=

# ----------------------------- утилиты --------------------------------------
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
[[ -t 1 ]] || { c_g=; c_y=; c_r=; c_b=; c_0=; }
log()  { echo "${c_g}==>${c_0} [$(date +%H:%M:%S)] $*"; }
warn() { echo "${c_y}[!]${c_0} $*" >&2; }
die()  { echo "${c_r}[ошибка]${c_0} $*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "запустите от root (sudo)"; }

take_lock() {
  exec 9>"$LOCK"
  flock -n 9 || die "уже выполняется другой экземпляр tg-ws-proxyctl"
}

usage() {
  cat <<EOF
${c_b}tg-ws-proxyctl${c_0} — корпоративный tg-ws-proxy

Команды:
  install        установить (или переустановить с сохранением секрета)
  apply          применить изменённые параметры (флаги ниже или правка $CONF)
  update         обновить до последнего релиза (с автооткатом при сбое)
  check          проверить наличие новой версии (код $EXIT_UPDATE_AVAILABLE = есть обновление)
  auto-update    проверить и, если режим auto, установить (запускается таймером)
  status         состояние службы, версия, ссылка, последняя статистика
  link           показать ссылку для сотрудников (и QR, если есть qrencode)
  rotate-secret  сгенерировать новый секрет (старая ссылка перестанет работать)
  uninstall      удалить (конфиг и логи сохраняются; --purge — удалить всё)
  version        версии скрипта и установленного tg-ws-proxy
  self-update    обновить сам tg-ws-proxyctl из последнего релиза
                 (--check — только проверить, код $EXIT_UPDATE_AVAILABLE = есть новая версия)

Параметры (install / apply):
  --public-host HOST   имя или IP для ссылки сотрудникам (по умолч. hostname -f)
  --listen ADDR        адрес прослушивания (по умолч. 0.0.0.0)
  --port N             порт (по умолч. 1443)
  --allow NETS         подсети, которым разрешён доступ: 10.10.0.0/16,10.20.0.0/24
  --pool-size N        WS-пул на DC (по умолч. 8)
  --dc-ips "LIST"      пары DC:IP через пробел (по умолч. "$DC_IPS")
  --extra-args "ARGS"  доп. аргументы прокси (напр. "--proxy-protocol")
  --version TAG        версия (тег) или latest
  --repo URL           git-репозиторий (можно внутреннее зеркало)
  --secret HEX32       задать секрет вручную (32 hex-символа)
  --firewall MODE      auto | ufw | firewalld | none
                       (ufw: установить и включить ufw, если его нет;
                        SSH 22/tcp остаётся открытым)
  --updates MODE       auto  — ежедневно проверять и устанавливать (по умолч.)
                       check — ежедневно только проверять и писать в журнал
                       off   — не проверять
  --update-time HH:MM  время ежедневного запуска (по умолч. 04:30)
  --update-delay N     ставить релиз не раньше, чем через N дней после выхода (по умолч. 0)
  --no-timer           то же, что --updates off
  --self-update yes|no в режиме auto обновлять и сам tg-ws-proxyctl (по умолч. yes)
  --self-update-repo OWNER/REPO  репозиторий с релизами скрипта
                       (по умолч. cybermind-off/tg-ws-proxy-corp)

Файлы:
  конфиг   $CONF
  ссылка   $LINK_FILE
  логи     $LOG_DIR/proxy.log  и  journalctl -u $APP
EOF
}

# --------------------------- конфигурация -----------------------------------
load_config() {
  if [[ -f $CONF ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
  fi
}

save_config() {
  install -d -m 755 "$CONF_DIR"
  local tmp; tmp=$(mktemp "$CONF_DIR/.config.XXXXXX")
  cat >"$tmp" <<EOF
# tg-ws-proxy: конфигурация. После правки выполните: tg-ws-proxyctl apply
# Файл читается и bash, и systemd (EnvironmentFile) — только строки KEY="value".
REPO_URL="$REPO_URL"
VERSION="$VERSION"
PUBLIC_HOST="$PUBLIC_HOST"
LISTEN_ADDR="$LISTEN_ADDR"
PORT="$PORT"
ALLOW_NETS="$ALLOW_NETS"
POOL_SIZE="$POOL_SIZE"
DC_IPS="$DC_IPS"
EXTRA_ARGS="$EXTRA_ARGS"
FIREWALL="$FIREWALL"
UPDATE_MODE="$UPDATE_MODE"
UPDATE_TIME="$UPDATE_TIME"
UPDATE_DELAY_DAYS="$UPDATE_DELAY_DAYS"
SELF_UPDATE="$SELF_UPDATE"
SELF_UPDATE_REPO="$SELF_UPDATE_REPO"
SECRET="$SECRET"
EOF
  chmod 600 "$tmp"
  mv -f "$tmp" "$CONF"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --public-host) PUBLIC_HOST=${2:?}; shift 2 ;;
      --listen)      LISTEN_ADDR=${2:?}; shift 2 ;;
      --port)        PORT=${2:?}; shift 2 ;;
      --allow)       ALLOW_NETS=${2:?}; shift 2 ;;
      --pool-size)   POOL_SIZE=${2:?}; shift 2 ;;
      --dc-ips)      DC_IPS=${2:?}; shift 2 ;;
      --extra-args)  EXTRA_ARGS=${2-}; shift 2 ;;
      --version)     VERSION=${2:?}; shift 2 ;;
      --repo)        REPO_URL=${2:?}; shift 2 ;;
      --secret)      SECRET=${2:?}; shift 2 ;;
      --firewall)    FIREWALL=${2:?}; shift 2 ;;
      --updates)     UPDATE_MODE=${2:?}; shift 2 ;;
      --update-time) UPDATE_TIME=${2:?}; shift 2 ;;
      --update-delay) UPDATE_DELAY_DAYS=${2:?}; shift 2 ;;
      --auto-update) UPDATE_MODE=auto; shift ;;
      --no-timer)    UPDATE_MODE=off; shift ;;
      --self-update) SELF_UPDATE=${2:?}; shift 2 ;;
      --self-update-repo) SELF_UPDATE_REPO=${2:?}; shift 2 ;;
      --purge)       PURGE=yes; shift ;;
      -h|--help)     usage; exit 0 ;;
      *) die "неизвестный параметр: $1 (см. --help)" ;;
    esac
  done
  ALLOW_NETS=${ALLOW_NETS//,/ }
  ALLOW_NETS=$(echo $ALLOW_NETS)   # нормализация пробелов
}

normalize_update_mode() {
  if [[ -z $UPDATE_MODE ]]; then
    if [[ $UPDATE_TIMER == no ]]; then UPDATE_MODE=off; else UPDATE_MODE=auto; fi
  fi
}

validate() {
  normalize_update_mode
  case $UPDATE_MODE in auto|check|off) ;; *) die "--updates: auto | check | off" ;; esac
  [[ $UPDATE_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "--update-time в формате ЧЧ:ММ, например 04:30"
  [[ $UPDATE_DELAY_DAYS =~ ^[0-9]+$ ]] || die "--update-delay: число дней"
  [[ $SELF_UPDATE == yes || $SELF_UPDATE == no ]] || die "--self-update: yes | no"
  [[ $SELF_UPDATE_REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--self-update-repo в формате OWNER/REPO"
  local bad='["$`\\]'
  local v
  for v in "$REPO_URL" "$VERSION" "$PUBLIC_HOST" "$LISTEN_ADDR" "$ALLOW_NETS" \
           "$DC_IPS" "$EXTRA_ARGS" "$FIREWALL"; do
    [[ $v =~ $bad ]] && die "недопустимые символы (\" \$ \` \\) в параметре: $v"
  done
  [[ $PORT =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "неверный порт: $PORT"
  [[ $POOL_SIZE =~ ^[0-9]+$ ]] || die "неверный --pool-size: $POOL_SIZE"
  [[ -z $SECRET || $SECRET =~ ^[0-9a-fA-F]{32}$ ]] || die "секрет должен быть 32 hex-символа"
  for v in $DC_IPS; do
    [[ $v =~ ^-?[0-9]+:[0-9a-fA-F.:]+$ ]] || die "неверная пара DC:IP: $v"
  done
  for v in $ALLOW_NETS; do
    [[ $v =~ ^[0-9a-fA-F.:]+(/[0-9]{1,3})?$ ]] || die "неверная подсеть: $v"
  done
  case $FIREWALL in auto|ufw|firewalld|none) ;; *) die "неверный --firewall: $FIREWALL" ;; esac
}

# ------------------------------ система -------------------------------------
PKG=
detect_pkg() {
  if command -v apt-get >/dev/null; then PKG=apt
  elif command -v dnf >/dev/null; then PKG=dnf
  elif command -v yum >/dev/null; then PKG=yum
  else die "не найден apt/dnf/yum — установите вручную: python3 (>=3.8) с venv, git, openssl"
  fi
}

wait_apt() {
  # На свежей системе apt-daily/unattended-upgrades держат блокировку apt
  local i=0
  # Важно: не путать с постоянно висящим unattended-upgrade-shutdown --wait-for-signal
  while pgrep -f '(apt\.systemd\.daily|/usr/bin/unattended-upgrade|/usr/bin/apt-get|/usr/bin/apt|/usr/bin/dpkg)( |$)' >/dev/null; do
    (( i == 0 )) && log "Ожидание завершения фонового обновления системы (apt занят)"
    (( ++i > 120 )) && { warn "apt занят больше 20 минут — продолжаю"; break; }
    sleep 10
  done
}

install_packages() {
  log "Установка системных пакетов"
  case $PKG in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      local apt_opts=(-o DPkg::Lock::Timeout=600 -o Acquire::Retries=3)
      wait_apt
      apt-get "${apt_opts[@]}" update -qq
      apt-get "${apt_opts[@]}" install -y -qq python3 python3-venv python3-pip git ca-certificates openssl iproute2 >/dev/null
      apt-get "${apt_opts[@]}" install -y -qq qrencode >/dev/null 2>&1 || warn "qrencode не установлен — QR-код не будет создан"
      ;;
    dnf|yum)
      $PKG install -y -q python3 python3-pip git ca-certificates openssl iproute >/dev/null
      $PKG install -y -q qrencode >/dev/null 2>&1 || warn "qrencode не установлен (нужен EPEL) — QR-код не будет создан"
      ;;
  esac
}

PYTHON=
find_python() {
  local p
  for p in python3 python3.13 python3.12 python3.11 python3.10 python3.9 python3.8; do
    if command -v "$p" >/dev/null && "$p" -c 'import sys,venv; sys.exit(sys.version_info < (3,8))' 2>/dev/null; then
      PYTHON=$(command -v "$p"); break
    fi
  done
  [[ -n $PYTHON ]] || die "нужен Python >= 3.8 с модулем venv (на RHEL 8: dnf install python39)"
  log "Python: $PYTHON ($("$PYTHON" -V 2>&1))"
}

ensure_user() {
  if ! id "$SVC_USER" >/dev/null 2>&1; then
    log "Создание системного пользователя $SVC_USER"
    useradd --system --home-dir "$INSTALL_DIR" --no-create-home \
            --shell /usr/sbin/nologin "$SVC_USER"
  fi
  install -d -m 755 "$INSTALL_DIR"
  install -d -m 750 -o "$SVC_USER" -g "$SVC_USER" "$LOG_DIR"
}

# ------------------------------ исходники -----------------------------------
git_src() { git -C "$SRC_DIR" "$@"; }

fetch_source() {
  if [[ -d $SRC_DIR/.git ]]; then
    git_src remote set-url origin "$REPO_URL"
    git_src fetch --tags --force --prune --quiet origin
  else
    log "Загрузка исходников: $REPO_URL"
    git clone --quiet "$REPO_URL" "$SRC_DIR"
    git_src fetch --tags --force --quiet origin
  fi
}

latest_version() {
  local t
  t=$(git_src tag --sort=-v:refname | head -n1 || true)
  if [[ -n $t ]]; then echo "$t"
  else git_src symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main
  fi
}

target_version() {
  if [[ $VERSION == latest ]]; then latest_version; else echo "$VERSION"; fi
}

current_version() {
  git_src describe --tags --exact-match 2>/dev/null || git_src rev-parse --short HEAD
}

checkout_and_build() {
  local ver=$1
  log "Версия: $ver"
  git_src -c advice.detachedHead=false checkout --quiet --force "$ver"
  if [[ ! -x $VENV/bin/python ]]; then
    log "Создание виртуального окружения"
    "$PYTHON" -m venv "$VENV"
  fi
  log "Установка Python-зависимостей"
  local pip_opts=(--disable-pip-version-check --progress-bar off --timeout 30 --retries 3)
  "$VENV/bin/pip" install --quiet "${pip_opts[@]}" --upgrade pip setuptools wheel
  "$VENV/bin/pip" install "${pip_opts[@]}" -e "$SRC_DIR" \
    || "$VENV/bin/pip" install "${pip_opts[@]}" "$SRC_DIR"
  [[ -f $SRC_DIR/proxy/tg_ws_proxy.py ]] || die "в версии $ver нет proxy/tg_ws_proxy.py — структура проекта изменилась"
}

# ------------------------------- systemd ------------------------------------
write_unit() {
  local args="--host $LISTEN_ADDR --port $PORT --pool-size $POOL_SIZE"
  local dc
  for dc in $DC_IPS; do args+=" --dc-ip $dc"; done
  args+=" --log-file $LOG_DIR/proxy.log --log-max-mb 20 --log-backups 5"
  [[ -n $EXTRA_ARGS ]] && args+=" $EXTRA_ARGS"

  cat >"$UNIT" <<EOF
# Сгенерировано tg-ws-proxyctl. Не правьте вручную — используйте: tg-ws-proxyctl apply
[Unit]
Description=Telegram WS proxy (MTProto) for corporate network
Documentation=https://github.com/Flowseal/tg-ws-proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
EnvironmentFile=$CONF
Environment=PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WorkingDirectory=$SRC_DIR
# запуск как модуля: иначе proxy/utils.py перекрывает пакет utils/
ExecStart=$VENV/bin/python -u -m proxy.tg_ws_proxy $args --secret \${SECRET}
Restart=always
RestartSec=5
LimitNOFILE=65535

# Изоляция
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ReadWritePaths=$LOG_DIR
$( (( PORT < 1024 )) && echo "AmbientCapabilities=CAP_NET_BIND_SERVICE" )

[Install]
WantedBy=multi-user.target
EOF
}

write_timer() {
  # переход с 1.0.0: еженедельная проверка -> ежедневный таймер
  if [[ -f $OLD_CHK_TIMER || -f $OLD_CHK_SVC ]]; then
    systemctl disable --now "$APP-update-check.timer" >/dev/null 2>&1 || true
    rm -f "$OLD_CHK_SVC" "$OLD_CHK_TIMER"
  fi
  if [[ $UPDATE_MODE == off ]]; then
    systemctl disable --now "$APP-update.timer" >/dev/null 2>&1 || true
    rm -f "$UPD_SVC" "$UPD_TIMER"
    return 0
  fi
  cat >"$UPD_SVC" <<EOF
# Сгенерировано tg-ws-proxyctl. Режим: $UPDATE_MODE
[Unit]
Description=tg-ws-proxy update ($UPDATE_MODE)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$CTL_PATH auto-update
SuccessExitStatus=$EXIT_UPDATE_AVAILABLE
TimeoutStartSec=30min
EOF
  cat >"$UPD_TIMER" <<EOF
# Сгенерировано tg-ws-proxyctl
[Unit]
Description=Daily tg-ws-proxy update ($UPDATE_MODE) at $UPDATE_TIME

[Timer]
OnCalendar=*-*-* $UPDATE_TIME:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

enable_timer() {
  systemctl daemon-reload
  if [[ $UPDATE_MODE != off ]]; then
    systemctl enable --now --quiet "$APP-update.timer"
    log "Обновления: $UPDATE_MODE, ежедневно в $UPDATE_TIME"
  else
    log "Обновления: автоматическая проверка выключена"
  fi
}

install_ctl() {
  local self
  self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
  if [[ -f $self && $self != "$CTL_PATH" ]]; then
    install -m 755 "$self" "$CTL_PATH"
    log "Команда управления: $CTL_PATH"
  elif [[ ! -x $CTL_PATH ]]; then
    warn "не удалось скопировать скрипт в $CTL_PATH (запуск через pipe?) — скопируйте вручную"
  fi
}

# ------------------------------- файрвол ------------------------------------
detect_firewall() {
  local m=$FIREWALL
  if [[ $m == auto ]]; then
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then m=ufw
    elif systemctl is-active --quiet firewalld 2>/dev/null; then m=firewalld
    else m=none
    fi
  fi
  echo "$m"
}

fw_rule() {   # fw_rule add|del MODE NET PORT
  local op=$1 mode=$2 net=$3 port=$4 fam=ipv4
  [[ $net == *:* ]] && fam=ipv6
  case $mode in
    ufw)
      if [[ $op == add ]]; then
        ufw allow proto tcp from "$net" to any port "$port" comment "$APP" >/dev/null
      else
        ufw delete allow proto tcp from "$net" to any port "$port" >/dev/null 2>&1 || true
      fi ;;
    firewalld)
      local rule="rule family=$fam source address=$net port port=$port protocol=tcp accept"
      if [[ $op == add ]]; then
        firewall-cmd --permanent --add-rich-rule="$rule" >/dev/null
      else
        firewall-cmd --permanent --remove-rich-rule="$rule" >/dev/null 2>&1 || true
      fi ;;
  esac
}

remove_firewall() {
  [[ -f $FW_STATE ]] || return 0
  local mode nets port net
  # shellcheck disable=SC1090
  mode=$(. "$FW_STATE"; echo "$FW_MODE"); nets=$(. "$FW_STATE"; echo "$FW_NETS"); port=$(. "$FW_STATE"; echo "$FW_PORT")
  for net in $nets; do fw_rule del "$mode" "$net" "$port"; done
  [[ $mode == firewalld ]] && firewall-cmd --reload >/dev/null 2>&1 || true
  rm -f "$FW_STATE"
}

ensure_ufw() {
  if ! command -v ufw >/dev/null; then
    log "Установка ufw"
    [[ -n $PKG ]] || detect_pkg
    case $PKG in
      apt) wait_apt; DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -qq ufw >/dev/null ;;
      *)   $PKG install -y -q ufw >/dev/null || die "не удалось установить ufw (на RHEL нужен EPEL) — используйте --firewall firewalld" ;;
    esac
  fi
  if ! ufw status 2>/dev/null | grep -q 'Status: active'; then
    log "Включение ufw: входящие запрещены, кроме SSH (22/tcp) и правил прокси"
    ufw allow 22/tcp comment 'SSH' >/dev/null
    ufw --force enable >/dev/null
  fi
}

setup_firewall() {
  remove_firewall
  local mode net
  mode=$(detect_firewall)
  if [[ $mode == ufw ]]; then ensure_ufw; fi
  if [[ $mode == none ]]; then
    warn "локальный файрвол не используется — ограничьте доступ к порту $PORT на сетевом оборудовании"
    return
  fi
  if [[ -z $ALLOW_NETS ]]; then
    warn "--allow не задан: правила $mode для порта $PORT не добавлены — клиенты могут не подключиться"
    return
  fi
  log "Файрвол ($mode): порт $PORT/tcp открыт для: $ALLOW_NETS"
  for net in $ALLOW_NETS; do fw_rule add "$mode" "$net" "$PORT"; done
  [[ $mode == firewalld ]] && firewall-cmd --reload >/dev/null
  printf 'FW_MODE="%s"\nFW_NETS="%s"\nFW_PORT="%s"\n' "$mode" "$ALLOW_NETS" "$PORT" >"$FW_STATE"
  chmod 600 "$FW_STATE"
}

# ------------------------------ проверки ------------------------------------
check_outbound() {
  local ip
  ip=$(echo "$DC_IPS" | awk '{print $1}' | cut -d: -f2-)
  [[ -n $ip ]] || return 0
  if timeout 5 bash -c "exec 3<>/dev/tcp/$ip/443" 2>/dev/null; then
    log "Исходящий доступ к Telegram ($ip:443): OK"
  else
    warn "прямое соединение с $ip:443 не проходит (провайдер или файрвол) — прокси попробует обходные пути (CfProxy); проверьте работу клиентом"
  fi
}

restart_and_verify() {
  systemctl daemon-reload
  systemctl enable --quiet "$APP"
  systemctl restart "$APP"
  local i
  for i in {1..10}; do
    sleep 1
    if systemctl is-active --quiet "$APP" && ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q .; then
      log "Служба $APP запущена, порт $PORT слушается"
      return 0
    fi
  done
  journalctl -u "$APP" -n 30 --no-pager >&2 || true
  return 1
}

# -------------------------------- ссылка ------------------------------------
show_link() {
  local host=${PUBLIC_HOST:-$(hostname -f)} sec="dd$SECRET" logsec
  # если прокси напечатал ссылку (напр. ee-секрет при Fake TLS) — берём секрет оттуда
  logsec=$(journalctl -u "$APP" -n 300 --no-pager 2>/dev/null \
           | grep -o 'tg://proxy?[^ ]*' | tail -n1 | grep -o 'secret=[0-9a-fA-F]*' | cut -d= -f2 || true)
  [[ -n $logsec ]] && sec=$logsec

  local tg="tg://proxy?server=$host&port=$PORT&secret=$sec"
  local web="https://t.me/proxy?server=$host&port=$PORT&secret=$sec"
  printf '%s\n%s\n' "$tg" "$web" >"$LINK_FILE"
  chmod 600 "$LINK_FILE"

  echo
  echo "${c_b}Ссылка для сотрудников:${c_0}"
  echo "  $tg"
  echo "  $web"
  if command -v qrencode >/dev/null; then
    qrencode -o "$QR_FILE" -s 8 "$web" && chmod 600 "$QR_FILE"
    echo "  QR-код: $QR_FILE"
    [[ -t 1 ]] && qrencode -t ANSIUTF8 "$web"
  fi
  echo
}

# ------------------------------- команды ------------------------------------
cmd_install() {
  need_root; take_lock
  load_config
  parse_args "$@"
  [[ -n $PUBLIC_HOST ]] || PUBLIC_HOST=$(hostname -f)
  validate

  detect_pkg
  install_packages
  find_python
  ensure_user

  if [[ -z $SECRET ]]; then
    SECRET=$(openssl rand -hex 16)
    log "Сгенерирован новый секрет"
  else
    log "Используется существующий секрет"
  fi
  save_config

  fetch_source
  checkout_and_build "$(target_version)"
  install_ctl
  write_unit
  write_timer
  setup_firewall
  check_outbound

  restart_and_verify || die "служба не запустилась (лог выше)"
  enable_timer

  log "Готово. Версия: $(current_version)"
  show_link
  echo "Управление: tg-ws-proxyctl status | update | check | link | rotate-secret | apply | uninstall"
}

cmd_apply() {
  need_root; take_lock
  [[ -f $CONF ]] || die "не установлено — сначала выполните install"
  load_config
  parse_args "$@"
  validate
  save_config
  write_unit
  write_timer
  setup_firewall
  restart_and_verify || die "служба не запустилась после применения настроек"
  enable_timer
  show_link
}

cmd_check() {
  need_root
  [[ -d $SRC_DIR/.git ]] || die "не установлено"
  load_config
  fetch_source
  local cur latest
  cur=$(current_version); latest=$(latest_version)
  if [[ $cur == "$latest" ]]; then
    echo "Установлена актуальная версия: $cur"
    return 0
  fi
  echo "Доступна новая версия: $cur -> $latest"
  [[ $REPO_URL == *github.com* ]] && echo "Изменения: ${REPO_URL%.git}/releases/tag/$latest"
  logger -t "$APP" "доступна новая версия tg-ws-proxy: $cur -> $latest" 2>/dev/null || true
  return $EXIT_UPDATE_AVAILABLE
}

cmd_update() {
  need_root; take_lock
  [[ -d $SRC_DIR/.git ]] || die "не установлено"
  load_config
  parse_args "$@"
  find_python
  fetch_source
  local cur target
  cur=$(current_version); target=$(target_version)
  if [[ $cur == "$target" ]]; then
    echo "Установлена актуальная версия: $cur"; return 0
  fi
  log "Обновление: $cur -> $target"
  local prev_rev; prev_rev=$(git_src rev-parse HEAD)
  if checkout_and_build "$target" && write_unit && restart_and_verify; then
    log "Обновлено до $(current_version)"
  else
    warn "обновление не удалось — откат на $cur"
    checkout_and_build "$prev_rev"
    write_unit
    restart_and_verify || die "откат не помог — смотрите journalctl -u $APP"
    die "выполнен откат на $cur"
  fi
}

# ------------------------- самообновление скрипта ---------------------------
SELF_RC_UPDATED=20

download() {   # download URL FILE — через Python (учитывает HTTPS_PROXY)
  "$(command -v python3)" -I - "$1" "$2" 2>/dev/null <<'PY'
import sys, urllib.request
url, out = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(url, timeout=60) as r, open(out, "wb") as f:
    f.write(r.read())
PY
}

version_gt() {  # version_gt A B — истина, если A > B
  [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]
}

# Возвращает 0 — обновлять нечего, $SELF_RC_UPDATED — установлена новая версия,
# иначе — ошибка (старая версия остаётся на месте).
self_update() {
  local only_check=${1-} base tmp remote bak
  base=${TGWS_RELEASE_BASE:-https://github.com/$SELF_UPDATE_REPO/releases/latest/download}
  tmp=$(mktemp -d) || return 1
  if ! download "$base/tg-ws-proxyctl.sh" "$tmp/tg-ws-proxyctl.sh" || \
     ! download "$base/SHA256SUMS" "$tmp/SHA256SUMS"; then
    warn "не удалось скачать последний релиз $SELF_UPDATE_REPO"; rm -rf "$tmp"; return 1
  fi
  if ! (cd "$tmp" && grep ' tg-ws-proxyctl\.sh$' SHA256SUMS | sha256sum -c --status 2>/dev/null); then
    warn "контрольная сумма tg-ws-proxyctl.sh не совпала — обновление отменено"; rm -rf "$tmp"; return 1
  fi
  if ! bash -n "$tmp/tg-ws-proxyctl.sh" || ! grep -q '^CORP_VERSION=' "$tmp/tg-ws-proxyctl.sh"; then
    warn "скачанный tg-ws-proxyctl.sh повреждён — обновление отменено"; rm -rf "$tmp"; return 1
  fi
  remote=$(grep -m1 '^CORP_VERSION=' "$tmp/tg-ws-proxyctl.sh" | cut -d= -f2)
  if ! version_gt "$remote" "$CORP_VERSION"; then
    echo "tg-ws-proxyctl актуален: $CORP_VERSION (в релизе: $remote)"; rm -rf "$tmp"; return 0
  fi
  echo "Доступна новая версия tg-ws-proxyctl: $CORP_VERSION -> $remote"
  if [[ $only_check == --check ]]; then rm -rf "$tmp"; return $SELF_RC_UPDATED; fi

  bak=$CTL_PATH.prev
  [[ -f $CTL_PATH ]] && cp -p "$CTL_PATH" "$bak"
  install -m 755 "$tmp/tg-ws-proxyctl.sh" "$CTL_PATH"
  rm -rf "$tmp"
  log "tg-ws-proxyctl обновлён до $remote, применение настроек"
  if "$CTL_PATH" apply; then
    logger -t "$APP" "tg-ws-proxyctl автоматически обновлён: $CORP_VERSION -> $remote" 2>/dev/null || true
    return $SELF_RC_UPDATED
  fi
  warn "новая версия tg-ws-proxyctl не применилась — возврат на $CORP_VERSION"
  logger -p user.err -t "$APP" "обновление tg-ws-proxyctl до $remote не удалось, откат на $CORP_VERSION" 2>/dev/null || true
  if [[ -f $bak ]]; then install -m 755 "$bak" "$CTL_PATH"; "$CTL_PATH" apply || true; fi
  return 1
}

cmd_self_update() {
  need_root
  [[ -f $CONF ]] || die "не установлено"
  load_config
  [[ ${1-} == --check || -z ${1-} ]] || die "использование: tg-ws-proxyctl self-update [--check]"
  local rc=0
  self_update "${1-}" || rc=$?
  if (( rc == SELF_RC_UPDATED )); then
    [[ ${1-} == --check ]] && return $EXIT_UPDATE_AVAILABLE
    return 0
  fi
  return "$rc"
}

cmd_auto_update() {
  need_root
  [[ -f $CONF ]] || die "не установлено"
  load_config
  normalize_update_mode
  local self rc=0 latest age_days
  self=$(readlink -f "${BASH_SOURCE[0]}")

  if [[ $UPDATE_MODE == off ]]; then
    echo "Автоматические обновления выключены (--updates off)"; return 0
  fi

  # сначала — сам скрипт; после обновления продолжает уже новая версия
  if [[ $UPDATE_MODE == auto && $SELF_UPDATE == yes && -z ${TGWS_SELF_UPDATED-} ]]; then
    set +e; self_update; rc=$?; set -e
    if (( rc == SELF_RC_UPDATED )); then
      export TGWS_SELF_UPDATED=1
      exec "$CTL_PATH" auto-update
    fi
    rc=0   # ошибка самообновления не мешает обновить tg-ws-proxy
  fi

  # проверка — отдельным процессом, чтобы ошибки внутри не терялись
  set +e; bash "$self" check; rc=$?; set -e
  if [[ $rc -eq 0 ]]; then return 0; fi
  if [[ $rc -ne $EXIT_UPDATE_AVAILABLE ]]; then
    logger -t "$APP" "ошибка проверки обновлений (код $rc)" 2>/dev/null || true
    return "$rc"
  fi
  if [[ $UPDATE_MODE == check ]]; then return $EXIT_UPDATE_AVAILABLE; fi

  if [[ $VERSION != latest ]]; then
    echo "Версия закреплена ($VERSION) — автоустановка пропущена"; return 0
  fi

  latest=$(latest_version)
  if (( UPDATE_DELAY_DAYS > 0 )); then
    age_days=$(( ( $(date +%s) - $(git_src log -1 --format=%ct "$latest") ) / 86400 ))
    if (( age_days < UPDATE_DELAY_DAYS )); then
      echo "Релиз $latest вышел $age_days дн. назад — установка отложена (--update-delay $UPDATE_DELAY_DAYS)"
      return 0
    fi
  fi

  log "Автообновление до $latest"
  set +e; bash "$self" update; rc=$?; set -e
  if [[ $rc -eq 0 ]]; then
    logger -t "$APP" "tg-ws-proxy автоматически обновлён до $latest" 2>/dev/null || true
  else
    logger -p user.err -t "$APP" "автообновление до $latest не удалось (код $rc), выполнен откат" 2>/dev/null || true
  fi
  return "$rc"
}

cmd_status() {
  [[ -f $CONF ]] || die "не установлено"
  need_root
  load_config
  echo "${c_b}Версия:${c_0}   $(current_version 2>/dev/null || echo '?')"
  echo "${c_b}Адрес:${c_0}    $LISTEN_ADDR:$PORT   (для клиентов: ${PUBLIC_HOST}:$PORT)"
  echo "${c_b}Доступ:${c_0}   ${ALLOW_NETS:-не ограничен локальным файрволом}"
  normalize_update_mode
  local next
  next=$(systemctl show "$APP-update.timer" -p NextElapseUSecRealtime --value 2>/dev/null || true)
  if [[ $UPDATE_MODE == off ]]; then
    echo "${c_b}Обновл.:${c_0}  выключены"
  else
    echo "${c_b}Обновл.:${c_0}  $UPDATE_MODE, ежедневно в $UPDATE_TIME${next:+ (следующий запуск: $next)}"
  fi
  if [[ $UPDATE_MODE == auto && $SELF_UPDATE == yes ]]; then
    echo "${c_b}Скрипт:${c_0}   tg-ws-proxyctl $CORP_VERSION, самообновление из $SELF_UPDATE_REPO"
  else
    echo "${c_b}Скрипт:${c_0}   tg-ws-proxyctl $CORP_VERSION, самообновление выключено"
  fi
  echo
  systemctl --no-pager status "$APP" | head -n 5 || true
  echo
  echo "${c_b}Последние записи лога:${c_0}"
  tail -n 10 "$LOG_DIR/proxy.log" 2>/dev/null || journalctl -u "$APP" -n 10 --no-pager
  if [[ -f $LINK_FILE ]]; then
    echo; echo "${c_b}Ссылка:${c_0}"; sed 's/^/  /' "$LINK_FILE"
  fi
}

cmd_link() {
  need_root
  [[ -f $CONF ]] || die "не установлено"
  load_config
  show_link
}

cmd_rotate_secret() {
  need_root; take_lock
  [[ -f $CONF ]] || die "не установлено"
  load_config
  SECRET=$(openssl rand -hex 16)
  save_config
  restart_and_verify || die "служба не запустилась"
  warn "секрет изменён — старая ссылка больше не работает, разошлите новую"
  show_link
}

cmd_version() {
  echo "tg-ws-proxyctl (TG WS Proxy Corp by Cybermind) $CORP_VERSION"
  if [[ -d $SRC_DIR/.git ]]; then
    echo "tg-ws-proxy (Flowseal)           $(current_version 2>/dev/null || echo '?')"
  else
    echo "tg-ws-proxy (Flowseal)           не установлен"
  fi
}

cmd_uninstall() {
  need_root; take_lock
  PURGE=no
  parse_args "$@"
  load_config
  log "Остановка и удаление службы"
  systemctl disable --now "$APP" "$APP-update.timer" "$APP-update-check.timer" >/dev/null 2>&1 || true
  rm -f "$UNIT" "$UPD_SVC" "$UPD_TIMER" "$OLD_CHK_SVC" "$OLD_CHK_TIMER"
  systemctl daemon-reload
  remove_firewall
  rm -rf "$INSTALL_DIR"
  userdel "$SVC_USER" >/dev/null 2>&1 || true
  if [[ $PURGE == yes ]]; then
    rm -rf "$CONF_DIR" "$LOG_DIR"
    log "Конфигурация и логи удалены"
  else
    log "Конфигурация ($CONF_DIR) и логи ($LOG_DIR) сохранены; полное удаление: uninstall --purge"
  fi
  rm -f "$CTL_PATH"
  log "Удалено"
}

# --------------------------------- main -------------------------------------
PURGE=no
cmd=${1:-help}; [[ $# -gt 0 ]] && shift
case $cmd in
  install)        cmd_install "$@" ;;
  apply)          cmd_apply "$@" ;;
  update)         cmd_update "$@" ;;
  check)          cmd_check || exit $? ;;
  auto-update)    cmd_auto_update || exit $? ;;
  self-update)    cmd_self_update "$@" || exit $? ;;
  status)         cmd_status ;;
  link)           cmd_link ;;
  rotate-secret)  cmd_rotate_secret ;;
  uninstall)      cmd_uninstall "$@" ;;
  version|--version) cmd_version ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
