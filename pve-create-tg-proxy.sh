#!/usr/bin/env bash
# =============================================================================
#  pve-create-tg-proxy.sh — создание VM с tg-ws-proxy на ноде Proxmox VE
#
#  Часть проекта TG WS Proxy Corp (Proxmox VM), автор — Cybermind (MIT).
#  Сам прокси — tg-ws-proxy, автор Flowseal (MIT):
#      https://github.com/Flowseal/tg-ws-proxy
#
#  Что делает:
#    1. Скачивает облачный образ Debian (genericcloud) и проверяет SHA512
#    2. Создаёт VM: 1 vCPU, 1 ГБ RAM, диск 8 ГБ, cloud-init, guest agent
#    3. Передаёт в VM tg-ws-proxyctl.sh (берётся из папки рядом со скриптом)
#       и устанавливает прокси при первой загрузке
#    4. Ждёт окончания установки и печатает ссылку для сотрудников
#
#  Запуск на ноде PVE от root, например:
#    ./pve-create-tg-proxy.sh \
#        --ip 10.0.0.10/24 --gw 10.0.0.1 --dns 10.0.0.2 --searchdomain corp.local \
#        --ssh-key /root/.ssh/id_ed25519.pub \
#        --public-host tg-proxy.corp.local --allow 10.10.0.0/16,10.20.0.0/24
#
#  Требования: Proxmox VE 7.2+ (лучше 8.x), доступ ноды к cloud.debian.org.
#  Для автоустановки прокси нужно хранилище с типом содержимого "snippets"
#  (см. README).
# =============================================================================
set -euo pipefail

# ------------------------------ параметры -----------------------------------
CORP_VERSION=1.1.0
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VMID=
NAME=tg-proxy
CORES=1
MEMORY=1024
DISK=8G
STORAGE=local-lvm
BRIDGE=vmbr0
VLAN=
IP=dhcp
GW=
DNS=
SEARCHDOMAIN=
CIUSER=admin
SSH_KEY=
ASK_PASSWORD=no
DEBIAN=13
IMAGE_VARIANT=genericcloud
TIMEZONE=Europe/Moscow
SNIPPET_STORAGE=auto
PROXYCTL=auto                  # auto = tg-ws-proxyctl.sh рядом со скриптом
FIREWALL=
UPDATES=
UPDATE_TIME=
PUBLIC_HOST=
ALLOW=
POOL_SIZE=4
START=yes
WAIT=yes
WAIT_MIN=20
REFRESH_IMAGE=no
IMG_DIR=/var/lib/vz/template/cloud

# ------------------------------ утилиты -------------------------------------
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
[[ -t 1 ]] || { c_g=; c_y=; c_r=; c_b=; c_0=; }
log()  { echo "${c_g}==>${c_0} $*"; }
warn() { echo "${c_y}[!]${c_0} $*" >&2; }
die()  { echo "${c_r}[ошибка]${c_0} $*" >&2; exit 1; }

usage() {
  cat <<EOF
${c_b}pve-create-tg-proxy.sh${c_0} — создание VM для tg-ws-proxy на Proxmox VE

VM:
  --vmid N               ID VM (по умолч. следующий свободный)
  --name NAME            имя VM (по умолч. $NAME)
  --cores N              vCPU (по умолч. $CORES)
  --memory MB            RAM в МБ (по умолч. $MEMORY)
  --disk SIZE            размер диска (по умолч. $DISK)
  --storage ID           хранилище для диска (по умолч. $STORAGE)
  --bridge IF            сетевой мост (по умолч. $BRIDGE)
  --vlan TAG             VLAN-тег (необязательно)
  --debian 12|13         версия Debian (по умолч. $DEBIAN)
  --timezone TZ          часовой пояс (по умолч. $TIMEZONE)

Сеть и доступ:
  --ip CIDR|dhcp         адрес, напр. 10.0.0.10/24 (по умолч. dhcp)
  --gw IP                шлюз (обязателен при статическом адресе)
  --dns "IP [IP]"        DNS-серверы
  --searchdomain DOM     DNS-домен, напр. corp.local
  --user NAME            пользователь для входа (по умолч. $CIUSER, sudo без пароля)
  --ssh-key FILE         публичный SSH-ключ (рекомендуется)
  --password             запросить пароль пользователя интерактивно

Автоустановка прокси:
  --proxyctl FILE        путь к tg-ws-proxyctl.sh (по умолч. файл рядом со скриптом)
  --no-install           создать «чистую» VM без установки прокси
  --public-host HOST     имя для ссылки (по умолч. NAME.searchdomain или IP)
  --allow NETS           подсети офиса/VPN: 10.10.0.0/16,10.20.0.0/24
  --pool-size N          WS-пул на DC (по умолч. $POOL_SIZE)
  --firewall MODE        файрвол в VM: auto | ufw | none (ufw — включить ufw,
                         открыть 1443 только для --allow, SSH оставить открытым)
  --updates MODE         обновления tg-ws-proxy: auto (ежедневно ставить, по умолч.)
                         | check (только проверять) | off
  --update-time HH:MM    время ежедневного обновления (по умолч. 04:30)
  --snippet-storage ID   хранилище snippets (по умолч. найти автоматически)

Прочее:
  --no-start             только создать VM, не запускать
  --no-wait              не ждать окончания установки
  --refresh-image        перекачать образ Debian
  -h, --help             эта справка
  --version              версия скрипта
EOF
}

# ------------------------------ аргументы -----------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --vmid) VMID=${2:?}; shift 2 ;;
    --name) NAME=${2:?}; shift 2 ;;
    --cores) CORES=${2:?}; shift 2 ;;
    --memory) MEMORY=${2:?}; shift 2 ;;
    --disk) DISK=${2:?}; shift 2 ;;
    --storage) STORAGE=${2:?}; shift 2 ;;
    --bridge) BRIDGE=${2:?}; shift 2 ;;
    --vlan) VLAN=${2:?}; shift 2 ;;
    --debian) DEBIAN=${2:?}; shift 2 ;;
    --timezone) TIMEZONE=${2:?}; shift 2 ;;
    --ip) IP=${2:?}; shift 2 ;;
    --gw) GW=${2:?}; shift 2 ;;
    --dns) DNS=${2:?}; shift 2 ;;
    --searchdomain) SEARCHDOMAIN=${2:?}; shift 2 ;;
    --user) CIUSER=${2:?}; shift 2 ;;
    --ssh-key) SSH_KEY=${2:?}; shift 2 ;;
    --password) ASK_PASSWORD=yes; shift ;;
    --proxyctl) PROXYCTL=${2:?}; shift 2 ;;
    --no-install) PROXYCTL=; shift ;;
    --firewall) FIREWALL=${2:?}; shift 2 ;;
    --updates) UPDATES=${2:?}; shift 2 ;;
    --update-time) UPDATE_TIME=${2:?}; shift 2 ;;
    --version) echo "pve-create-tg-proxy.sh (TG WS Proxy Corp by Cybermind) $CORP_VERSION"; exit 0 ;;
    --public-host) PUBLIC_HOST=${2:?}; shift 2 ;;
    --allow) ALLOW=${2:?}; shift 2 ;;
    --pool-size) POOL_SIZE=${2:?}; shift 2 ;;
    --snippet-storage) SNIPPET_STORAGE=${2:?}; shift 2 ;;
    --no-start) START=no; WAIT=no; shift ;;
    --no-wait) WAIT=no; shift ;;
    --refresh-image) REFRESH_IMAGE=yes; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный параметр: $1 (см. --help)" ;;
  esac
done
ALLOW=${ALLOW//,/ }; ALLOW=$(echo $ALLOW)

# ------------------------------ проверки ------------------------------------
[[ $EUID -eq 0 ]] || die "запустите от root на ноде Proxmox"
command -v qm >/dev/null && command -v pvesm >/dev/null || die "qm/pvesm не найдены — это не нода Proxmox VE?"

pve_major=$(pveversion 2>/dev/null | sed -n 's#^pve-manager/\([0-9]*\)\..*#\1#p')
[[ -z $pve_major || $pve_major -ge 8 ]] || \
  { [[ $pve_major -eq 7 ]] && warn "Proxmox VE 7: нужна версия 7.2+ (import-from)"; } || die "нужен Proxmox VE 7.2+"

[[ $NAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || die "неверное имя VM: $NAME"
[[ $CORES =~ ^[0-9]+$ && $MEMORY =~ ^[0-9]+$ && $POOL_SIZE =~ ^[0-9]+$ ]] || die "cores/memory/pool-size должны быть числами"
[[ $DISK =~ ^[0-9]+[GT]$ ]] || die "размер диска в формате 8G"
[[ -z $VLAN || $VLAN =~ ^[0-9]+$ ]] || die "неверный VLAN: $VLAN"
case $DEBIAN in 12) CODENAME=bookworm ;; 13) CODENAME=trixie ;; *) die "--debian 12 или 13" ;; esac
[[ $TIMEZONE =~ ^[A-Za-z0-9_+/-]+$ ]] || die "неверный часовой пояс"
[[ $CIUSER =~ ^[a-z_][a-z0-9_-]*$ && $CIUSER != root ]] || die "неверное имя пользователя: $CIUSER"

if [[ $IP != dhcp ]]; then
  [[ $IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || die "адрес в формате 10.0.0.10/24 или dhcp"
  [[ -n $GW ]] || die "для статического адреса нужен --gw"
  [[ $GW =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "неверный шлюз: $GW"
fi
for v in $DNS; do [[ $v =~ ^[0-9a-fA-F.:]+$ ]] || die "неверный DNS: $v"; done
[[ -z $SEARCHDOMAIN || $SEARCHDOMAIN =~ ^[a-zA-Z0-9.-]+$ ]] || die "неверный домен: $SEARCHDOMAIN"
for v in $ALLOW; do [[ $v =~ ^[0-9a-fA-F.:]+(/[0-9]{1,3})?$ ]] || die "неверная подсеть: $v"; done
[[ -z $PUBLIC_HOST || $PUBLIC_HOST =~ ^[a-zA-Z0-9.:-]+$ ]] || die "неверный --public-host"

[[ -n $SSH_KEY || $ASK_PASSWORD == yes ]] || die "укажите --ssh-key FILE или --password — иначе в VM нельзя будет войти"
[[ -z $SSH_KEY || -s $SSH_KEY ]] || die "файл ключа не найден: $SSH_KEY"

pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "хранилище не найдено: $STORAGE"
ip link show "$BRIDGE" >/dev/null 2>&1 || die "мост не найден: $BRIDGE"

if [[ -n $VMID ]]; then
  [[ $VMID =~ ^[0-9]+$ ]] || die "неверный VMID"
  qm status "$VMID" >/dev/null 2>&1 && die "VM $VMID уже существует"
else
  VMID=$(pvesh get /cluster/nextid)
fi

case $UPDATES in ''|auto|check|off) ;; *) die "--updates: auto | check | off" ;; esac
[[ -z $UPDATE_TIME || $UPDATE_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "--update-time в формате ЧЧ:ММ"
case $FIREWALL in ''|auto|ufw|none) ;; *) die "--firewall: auto | ufw | none" ;; esac
if [[ $PROXYCTL == auto ]]; then
  PROXYCTL=$SCRIPT_DIR/tg-ws-proxyctl.sh
  [[ -f $PROXYCTL ]] || die "не найден $PROXYCTL — положите tg-ws-proxyctl.sh рядом, укажите --proxyctl FILE или --no-install"
fi
if [[ -n $PROXYCTL ]]; then
  [[ -f $PROXYCTL ]] || die "не найден файл: $PROXYCTL"
  bash -n "$PROXYCTL" || die "$PROXYCTL содержит синтаксические ошибки"
  grep -q 'tg-ws-proxyctl' "$PROXYCTL" || die "$PROXYCTL не похож на tg-ws-proxyctl.sh"
fi

if [[ -z $PUBLIC_HOST ]]; then
  if [[ -n $SEARCHDOMAIN ]]; then PUBLIC_HOST=$NAME.$SEARCHDOMAIN
  elif [[ $IP != dhcp ]]; then PUBLIC_HOST=${IP%/*}
  fi
fi

# snippets
SNIP=
if [[ $SNIPPET_STORAGE == auto ]]; then
  SNIPPET_STORAGE=$(pvesm status --content snippets 2>/dev/null | awk 'NR>1 && $3=="active"{print $1; exit}')
fi
if [[ -n $SNIPPET_STORAGE ]]; then
  SNIP="$SNIPPET_STORAGE:snippets/tg-proxy-$VMID-vendor.yaml"
  SNIP_PATH=$(pvesm path "$SNIP") || die "не удалось получить путь для $SNIP"
else
  warn "нет хранилища с типом 'snippets': guest agent и прокси не будут установлены автоматически"
  warn "включить: pvesm set local --content iso,vztmpl,backup,snippets  (сохраните текущие типы!)"
  [[ -n $PROXYCTL ]] && die "для автоустановки прокси нужно хранилище snippets (или запустите с --no-install)"
  WAIT=no
fi

PASSWORD=
if [[ $ASK_PASSWORD == yes ]]; then
  read -rsp "Пароль для пользователя $CIUSER: " PASSWORD; echo
  read -rsp "Повторите пароль: " p2; echo
  [[ -n $PASSWORD && $PASSWORD == "$p2" ]] || die "пароли пусты или не совпадают"
fi

# ------------------------------ образ ---------------------------------------
IMG_NAME=debian-$DEBIAN-$IMAGE_VARIANT-amd64.qcow2
IMG_URL=https://cloud.debian.org/images/cloud/$CODENAME/latest
IMG=$IMG_DIR/$IMG_NAME

get_image() {
  mkdir -p "$IMG_DIR"
  if [[ -f $IMG && $REFRESH_IMAGE == no ]]; then
    log "Образ уже скачан: $IMG (обновить: --refresh-image)"
    return
  fi
  log "Скачивание $IMG_NAME"
  local tmp=$IMG.part
  wget -q --show-progress -O "$tmp" "$IMG_URL/$IMG_NAME" || { rm -f "$tmp"; die "не удалось скачать образ"; }
  wget -q -O "$IMG_DIR/SHA512SUMS.$CODENAME" "$IMG_URL/SHA512SUMS" || die "не удалось скачать SHA512SUMS"
  local want got
  want=$(awk -v f="$IMG_NAME" '$2==f{print $1}' "$IMG_DIR/SHA512SUMS.$CODENAME")
  got=$(sha512sum "$tmp" | awk '{print $1}')
  [[ -n $want && $want == "$got" ]] || { rm -f "$tmp"; die "контрольная сумма образа не совпала"; }
  mv -f "$tmp" "$IMG"
  log "Образ проверен (SHA512 OK)"
}

# ------------------------- cloud-init vendor-data ---------------------------
write_vendor_data() {
  local install_cmd=""
  if [[ -n $PROXYCTL ]]; then
    install_cmd="bash /root/tg-ws-proxyctl.sh install --pool-size $POOL_SIZE"
    [[ -n $PUBLIC_HOST ]] && install_cmd+=" --public-host $PUBLIC_HOST"
    [[ -n $ALLOW ]] && install_cmd+=" --allow ${ALLOW// /,}"
    [[ -n $FIREWALL ]] && install_cmd+=" --firewall $FIREWALL"
    [[ -n $UPDATES ]] && install_cmd+=" --updates $UPDATES"
    [[ -n $UPDATE_TIME ]] && install_cmd+=" --update-time $UPDATE_TIME"
    install_cmd+=" > /var/log/tg-ws-proxy-install.log 2>&1"
  fi
  {
    echo "#cloud-config"
    echo "timezone: $TIMEZONE"
    echo "package_update: true"
    echo "packages:"
    echo "  - qemu-guest-agent"
    echo "  - unattended-upgrades"
    if [[ -n $PROXYCTL ]]; then
      echo "write_files:"
      echo "  - path: /root/tg-ws-proxyctl.sh"
      echo "    permissions: '0755'"
      echo "    encoding: b64"
      echo "    content: $(base64 -w0 "$PROXYCTL")"
    fi
    echo "runcmd:"
    echo "  - [systemctl, enable, --now, qemu-guest-agent]"
    echo "  - [systemctl, enable, --now, unattended-upgrades]"
    if [[ -n $install_cmd ]]; then
      echo "  - [bash, -c, \"$install_cmd\"]"
    fi
  } >"$SNIP_PATH"
  chmod 600 "$SNIP_PATH"
}

# ------------------------------ создание VM ---------------------------------
CREATED=no
cleanup() {
  local rc=$?
  if [[ $rc -ne 0 && $CREATED == yes ]]; then
    warn "ошибка — удаляю недосозданную VM $VMID"
    qm stop "$VMID" >/dev/null 2>&1 || true
    qm destroy "$VMID" --purge >/dev/null 2>&1 || true
    [[ -n ${SNIP_PATH-} ]] && rm -f "$SNIP_PATH"
  fi
}
trap cleanup EXIT

get_image

log "Создание VM $VMID ($NAME): ${CORES} vCPU, ${MEMORY} МБ, диск $DISK на $STORAGE"
net="virtio,bridge=$BRIDGE"; [[ -n $VLAN ]] && net+=",tag=$VLAN"
qm create "$VMID" \
  --name "$NAME" \
  --description "tg-ws-proxy (MTProto → WebSocket) для офиса и VPN. Создано pve-create-tg-proxy.sh" \
  --tags tg-proxy \
  --ostype l26 \
  --cores "$CORES" --memory "$MEMORY" --balloon 0 \
  --scsihw virtio-scsi-single \
  --net0 "$net" \
  --agent enabled=1 \
  --serial0 socket --vga serial0 \
  --onboot 1
CREATED=yes

qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$IMG,discard=on,iothread=1,ssd=1" >/dev/null
qm resize "$VMID" scsi0 "$DISK" >/dev/null
qm set "$VMID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0 >/dev/null

ipcfg="ip=$IP"; [[ $IP != dhcp ]] && ipcfg+=",gw=$GW"
ci_args=(--ciuser "$CIUSER" --ipconfig0 "$ipcfg")
[[ -n $SSH_KEY ]] && ci_args+=(--sshkeys "$SSH_KEY")
[[ -n $PASSWORD ]] && ci_args+=(--cipassword "$PASSWORD")
[[ -n $DNS ]] && ci_args+=(--nameserver "$DNS")
[[ -n $SEARCHDOMAIN ]] && ci_args+=(--searchdomain "$SEARCHDOMAIN")
if [[ -n $SNIP ]]; then
  write_vendor_data
  ci_args+=(--cicustom "vendor=$SNIP")
fi
qm set "$VMID" "${ci_args[@]}" >/dev/null
log "Cloud-init настроен (пользователь $CIUSER, сеть: $ipcfg)"

if [[ $START == no ]]; then
  trap - EXIT
  log "VM $VMID создана. Запуск: qm start $VMID"
  exit 0
fi

qm start "$VMID"
trap - EXIT
log "VM $VMID запущена"

# ------------------------------ ожидание ------------------------------------
guest_exec() {   # печатает stdout команды в госте, код возврата = код команды
  local json
  json=$(qm guest exec "$VMID" --timeout 30 -- "$@" 2>/dev/null) || return 1
  python3 -c '
import json,sys
d=json.loads(sys.argv[1])
sys.stdout.write(d.get("out-data",""))
sys.exit(d.get("exitcode",1) if d.get("exited") else 1)' "$json"
}

if [[ $WAIT == yes ]]; then
  log "Ожидание guest agent (первая загрузка и установка пакетов, до $WAIT_MIN мин)"
  deadline=$(( $(date +%s) + WAIT_MIN*60 ))
  until qm guest cmd "$VMID" ping >/dev/null 2>&1; do
    (( $(date +%s) < deadline )) || die "guest agent не ответил за $WAIT_MIN мин — смотрите консоль: qm terminal $VMID"
    sleep 10
  done
  log "Guest agent отвечает"

  if [[ -n $PROXYCTL ]]; then
    log "Ожидание установки tg-ws-proxy (ход установки ниже)"
    last=
    until guest_exec test -f /etc/tg-ws-proxy/link.txt >/dev/null; do
      line=$(guest_exec tail -n 1 /var/log/tg-ws-proxy-install.log 2>/dev/null | tr -d '\r' | cut -c1-150 || true)
      if [[ -n $line && $line != "$last" ]]; then echo "    $line"; last=$line; fi
      # cloud-init закончил, а ссылки нет — установка упала
      ci=$(guest_exec cloud-init status 2>/dev/null | awk '/^status:/{print $2}' || true)
      if [[ $ci == done || $ci == error || $ci == degraded ]] && \
         ! guest_exec test -f /etc/tg-ws-proxy/link.txt >/dev/null; then
        echo
        echo "${c_b}--- /var/log/tg-ws-proxy-install.log ---${c_0}"
        guest_exec tail -n 30 /var/log/tg-ws-proxy-install.log || echo "(лог отсутствует)"
        echo "${c_b}--- /var/log/cloud-init-output.log ---${c_0}"
        guest_exec tail -n 15 /var/log/cloud-init-output.log || true
        die "установка прокси не удалась (cloud-init: $ci). VM $VMID оставлена для диагностики: qm terminal $VMID"
      fi
      (( $(date +%s) < deadline )) || die "установка не завершилась за $WAIT_MIN мин — в VM: tail /var/log/tg-ws-proxy-install.log"
      sleep 10
    done
    guest_exec cloud-init status --wait >/dev/null 2>&1 || true
    echo
    log "Готово"
    echo "${c_b}Ссылка для сотрудников:${c_0}"
    guest_exec cat /etc/tg-ws-proxy/link.txt | sed 's/^/  /'
  fi

  ipaddr=$(guest_exec hostname -I 2>/dev/null | awk '{print $1}' || true)
  echo
  echo "VM:       $VMID ($NAME)"
  if [[ -n $ipaddr ]]; then echo "Адрес:    $ipaddr"; echo "SSH:      ssh $CIUSER@$ipaddr"; fi
  if [[ -n $PROXYCTL ]]; then echo "Прокси:   sudo tg-ws-proxyctl status"; fi
else
  echo
  echo "VM $VMID запущена. Первая загрузка с установкой занимает несколько минут."
  if [[ -n $PROXYCTL ]]; then echo "Лог установки в VM: /var/log/tg-ws-proxy-install.log; ссылка: /etc/tg-ws-proxy/link.txt"; fi
fi
