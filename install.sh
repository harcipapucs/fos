#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -e

### ====== KONFIG ======
source ./config.conf
LOGFILE="/var/log/showoff_installer.log"

### ====== SZÍNEK ======
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
NC="\e[0m"

### ====== LOG ======
log() {
    echo "$(date '+%F %T') | $1" | tee -a "$LOGFILE"
}

ok() {
    echo -e "${GREEN} $1${NC}"
    log "OK: $1"
}

warn() {
    echo -e "${YELLOW} $1${NC}"
    log "WARN: $1"
}

fail() {
    echo -e "${RED} $1${NC}"
    log "FAIL: $1"
    exit 1
}

run() {
    if [ "$DRY_RUN" = true ]; then
        warn "[DRY-RUN] $*"
    else
        "$@"
    fi
}

trap 'fail "A script váratlanul megszakadt"' ERR

### ====== BANNER ======
clear
cat << "EOF"
=========================================
  SHOW-OFF SERVER INSTALLER v1.1
  Apache | Node-RED | MQTT | MariaDB
=========================================
EOF
echo -e "${BLUE}Logfile:${NC} $LOGFILE"
echo

### ====== ROOT CHECK ======
[ "$EUID" -ne 0 ] && fail "Root jogosultság szükséges"

### ====== APT UPDATE ======
log "APT csomaglista frissítése"
run apt update -y

### ====== INSTALL FUNCS ======
install_apache() {
    log "Apache2 telepítés"
    run apt install -y apache2
    run systemctl enable --now apache2
    ok "Apache2 fut"
}

install_ssh() {
    log "OpenSSH telepítés"
    run apt install -y openssh-server
    run systemctl enable --now ssh
    ok "OpenSSH aktív"
}

install_node_red() {
    # Node-RED installer néha nem exit 0-val tér vissza -> nem az exit code a döntő.
  apt_install curl ca-certificates || return 1
 
  log "Node-RED telepítés (non-interactive --confirm-root)"
  set +e
  curl -fsSL https://github.com/node-red/linux-installers/releases/latest/download/update-nodejs-and-nodered-deb \
    | bash -s -- --confirm-root
  local rc=$?
  set -e
  log "Node-RED installer exit code: $rc"
 
  # próbáljuk indítani, ha létrejött
  run systemctl daemon-reload || true
  if systemctl list-unit-files | grep -q '^nodered\.service'; then
    run systemctl enable --now nodered.service || true
  fi
 
  # tényleges sikerfeltétel: fut a service (vagy legalább települt a parancs)
  if systemctl is-active --quiet nodered 2>/dev/null; then
    return 0
  fi
  if command -v node-red >/dev/null 2>&1; then
    # Települt, de service nem fut -> ezt hibának vesszük
    return 1
  fi
  return 1
}
 
############################################
# FUTTATÁS
############################################
# apt update mindig menjen (különben minden más bukhat)
if apt_update; then
  ok "APT update kész"
else
  fail "APT update sikertelen (internet/DNS/repo gond)."
  # Itt még megpróbálhatjuk folytatni, de valószínűleg minden telepítés bukni fog.
fi
 
# Lépések (config szerint)
run_install() {
  local var="$1"
  local label="$2"
  local func="$3"
 
  echo -e "${BLUE}==> ${label}${NC}"
  if [[ "${!var:-false}" == "true" ]]; then
    if safe_step "$label" "$func"; then
      ok "$label OK"
    else
      fail "$label HIBA"
    fi
  else
    warn "$label kihagyva (config: $var=false)"
    set_result "$label" "KIHAGYVA"
  fi
  echo
}

install_mosquitto() {
    log "Mosquitto MQTT telepítés"
    run apt install -y mosquitto mosquitto-clients
    run systemctl enable --now mosquitto
    ok "Mosquitto fut"
}

install_mariadb() {
    log "MariaDB telepítés"
    run apt install -y mariadb-server
    run systemctl enable --now mariadb
    ok "MariaDB fut"
}

install_php() {
    log "PHP + Apache modul telepítés"
    run apt install -y php libapache2-mod-php php-mysql
    run systemctl restart apache2
    ok "PHP Apache modul aktív"
}

install_ufw() {
    log "UFW tűzfal beállítás"
    run apt install -y ufw
    run ufw allow ssh
    run ufw allow http
    run ufw allow 1883
    run ufw allow 1880
    run ufw --force enable
    ok "UFW engedélyezve"
}

### ====== TELEPÍTÉSI LISTA ======
SERVICES=(
    INSTALL_APACHE:install_apache
    INSTALL_SSH:install_ssh
    INSTALL_NODE_RED:install_node_red
    INSTALL_MOSQUITTO:install_mosquitto
    INSTALL_MARIADB:install_mariadb
    INSTALL_PHP:install_php
    INSTALL_UFW:install_ufw
)

TOTAL=${#SERVICES[@]}
COUNT=0

for s in "${SERVICES[@]}"; do
    COUNT=$((COUNT+1))
    VAR="${s%%:*}"
    FUNC="${s##*:}"

    echo -e "${BLUE}[$COUNT/$TOTAL]${NC} $FUNC"
    if [ "${!VAR}" = true ]; then
        $FUNC
    else
        warn "$FUNC kihagyva (config)"
    fi
done

### ====== HEALTH CHECK + PORT CHECK ======
echo
log "Szolgáltatások állapota"
for svc in apache2 ssh mosquitto mariadb nodered; do
    systemctl is-active --quiet $svc \
        && ok "$svc RUNNING" \
        || warn "$svc NEM FUT"
done

log "PORT CHECK (80,1880,1883)"
if command -v ss >/dev/null 2>&1; then
  ss -tulpn | grep -E '(:80|:1880|:1883)\b' && ok "Portok rendben" || warn "Nem látok hallgatózó portot (lehet szolgáltatás nem fut)."
else
  warn "ss parancs nem elérhető"
fi

### ====== SUMMARY ======
echo -e "${GREEN}
=================================
  TELEPÍTÉS SIKERES 
=================================
${NC}"

log "Telepítés befejezve"
