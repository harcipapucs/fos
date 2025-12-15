#!/bin/bash
# Show-Off Server Installer - robust edition (VirtualBox/Debian/Ubuntu)
# Installs: Apache2, SSH, Mosquitto(+clients), Node-RED, MariaDB, PHP, UFW
# Uses config.conf toggles, logs, and does NOT abort on single-component failures.
 
set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive
 
############################################
# KONFIG
############################################
CONFIG_FILE="./config.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
else
  echo "WARN: config.conf nem található, alapértelmezett értékekkel futok."
fi
 
: "${DRY_RUN:=false}"
: "${INSTALL_APACHE:=true}"
: "${INSTALL_SSH:=true}"
: "${INSTALL_NODE_RED:=true}"
: "${INSTALL_MOSQUITTO:=true}"
: "${INSTALL_MARIADB:=true}"
: "${INSTALL_PHP:=true}"
: "${INSTALL_UFW:=true}"
: "${LOGFILE:=/var/log/showoff_installer.log}"
 
############################################
# SZÍNEK
############################################
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
NC="\e[0m"
 
############################################
# ROOT CHECK
############################################
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo -e "${RED}Root jogosultság szükséges.${NC}"
  echo "Futtasd így:"
  echo "  su -"
  echo "  ./install.sh"
  exit 1
fi
 
############################################
# LOG
############################################
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
touch "$LOGFILE" 2>/dev/null || true
 
log() {
  echo "$(date '+%F %T') | $1" | tee -a "$LOGFILE" >/dev/null
}
 
ok()   { echo -e "${GREEN}✔ $1${NC}"; log "OK: $1"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; log "WARN: $1"; }
fail() { echo -e "${RED}✖ $1${NC}"; log "FAIL: $1"; }
 
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    warn "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}
 
############################################
# BANNER
############################################
clear
cat << "EOF"
=========================================
  SHOW-OFF SERVER INSTALLER vFINAL
  Apache | Node-RED | MQTT | MariaDB | PHP | UFW
  VirtualBox / Debian / Ubuntu - ROBUSZTUS
=========================================
EOF
echo -e "${BLUE}Logfile:${NC} $LOGFILE"
echo
 
############################################
# EREDMÉNY TÁBLÁZAT
############################################
declare -A RESULTS
set_result() { RESULTS["$1"]="$2"; }
 
############################################
# APT HELPERS (STABIL)
############################################
apt_update() {
  log "APT csomaglista frissítése"
  run apt-get update -y
}
 
apt_install() {
  log "Csomag telepítés: $*"
  run apt-get install -y "$@"
}
 
############################################
# SAFE EXEC: ne álljon meg, hanem rögzítse a hibát
############################################
safe_step() {
  # safe_step "Label" command...
  local label="$1"; shift
  log "START: $label -> $*"
  if "$@"; then
    set_result "$label" "SIKERES"
    return 0
  else
    set_result "$label" "HIBA"
    return 1
  fi
}
 
############################################
# TELEPÍTŐK
############################################
install_apache() {
  apt_install apache2 || return 1
  run systemctl enable --now apache2 || return 1
  return 0
}
 
install_ssh() {
  apt_install openssh-server || return 1
  run systemctl enable --now ssh || return 1
  return 0
}
 
install_mosquitto() {
  apt_install mosquitto mosquitto-clients || return 1
  run systemctl enable --now mosquitto || return 1
  return 0
}
 
install_mariadb() {
  apt_install mariadb-server || return 1
  run systemctl enable --now mariadb || return 1
  return 0
}
 
install_php() {
  apt_install php libapache2-mod-php php-mysql || return 1
  run systemctl restart apache2 || return 1
  return 0
}
 
install_ufw() {
  apt_install ufw || return 1
  run ufw allow OpenSSH || return 1
  run ufw allow 80/tcp || return 1
  run ufw allow 1880/tcp || return 1
  run ufw allow 1883/tcp || return 1
  run ufw --force enable || return 1
  return 0
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
 
run_install INSTALL_APACHE     "Apache2"   install_apache
run_install INSTALL_SSH        "SSH"       install_ssh
run_install INSTALL_MOSQUITTO  "Mosquitto" install_mosquitto
run_install INSTALL_NODE_RED   "Node-RED"  install_node_red
run_install INSTALL_MARIADB    "MariaDB"   install_mariadb
run_install INSTALL_PHP        "PHP"       install_php
run_install INSTALL_UFW        "UFW"       install_ufw
 
############################################
# HEALTH CHECK + PORT CHECK
############################################
log "HEALTH CHECK"
for svc in apache2 ssh mosquitto mariadb nodered; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    ok "$svc RUNNING"
  else
    warn "$svc NEM FUT"
  fi
done
 
log "PORT CHECK (80,1880,1883)"
if command -v ss >/dev/null 2>&1; then
  ss -tulpn | grep -E '(:80|:1880|:1883)\b' && ok "Portok rendben" || warn "Nem látok hallgatózó portot (lehet szolgáltatás nem fut)."
else
  warn "ss parancs nem elérhető"
fi
 
############################################
# ÖSSZEFOGLALÓ
############################################
echo
echo "================================="
echo "  TELEPÍTÉSI ÖSSZEFOGLALÓ"
echo "================================="
for k in "${!RESULTS[@]}"; do
  echo "$k : ${RESULTS[$k]}"
done
echo
 
# Exit code: 0 ha minden SIKERES/KIHAGYVA, 1 ha volt HIBA
any_fail=0
for k in "${!RESULTS[@]}"; do
  if [[ "${RESULTS[$k]}" == "HIBA" ]]; then
    any_fail=1
  fi
done
 
if [[ "$any_fail" -eq 0 ]]; then
  echo -e "${GREEN}KÉSZ – minden lépés rendben lefutott.${NC}"
  log "Telepítés befejezve: SIKERES"
  exit 0
else
  echo -e "${YELLOW}KÉSZ – volt sikertelen lépés. Nézd a logot: $LOGFILE${NC}"
  log "Telepítés befejezve: RÉSZBEN SIKERES"
  exit 1
fi
