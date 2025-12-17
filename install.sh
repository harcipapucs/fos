#!/bin/bash

# ==============================
#  Debian Server Installer Wizard
# ==============================

CONFIG_FILE="./config.conf"

# --- Színek ---
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
PINK="\e[95m"
RESET="\e[0m"
BOLD="\e[1m"

# --- Betöltés ---
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}[ERROR] Hiányzik a konfigurációs fájl!${RESET}"
    exit 1
fi
source "$CONFIG_FILE"

# --- Logolás ---
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

# --- Root ellenőrzés ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] Root jogosultság szükséges!${RESET}"
    exit 1
fi

# --- Segédfüggvény ---
run_cmd() {
    local DESC="$1"
    local CMD="$2"
    echo -ne "${PINK}▶ ${DESC} ... ${RESET}"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY-RUN]${RESET}"
    else
        eval "$CMD" &>/dev/null
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}kész${RESET}"
        else
            echo -e "${RED}hiba!${RESET}"
        fi
    fi
}

check_port_nc() {
    local PORT="$1"
    local NAME="$2"
    nc -z localhost "$PORT" &>/dev/null
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✔ $NAME ($PORT) elérhető${RESET}"
    else
        echo -e "${RED}✖ $NAME ($PORT) nem elérhető${RESET}"
    fi
}

banner() {
    clear
    echo -e "${MAGENTA}${BOLD}"
    echo "========================================"
    echo "      Debian Server Installer"
    echo "========================================"
    echo -e "${RESET}"
}

# --- Internet kapcsolat ---
echo -e "${CYAN}▶ Ellenőrzés: internet kapcsolat (8.8.8.8)${RESET}"
if ping -c 3 -W 2 8.8.8.8 &>/dev/null; then
    echo -e "${GREEN}✔ Internet rendben${RESET}"
else
    echo -e "${RED}✖ Nincs internet kapcsolat, a telepítés megszakad!${RESET}"
    exit 1
fi

# ==============================
#  TELEPÍTÉS
# ==============================

banner
echo -e "${CYAN}Log fájl: $LOG_FILE${RESET}"
echo -e "${CYAN}Dry-run: $DRY_RUN${RESET}"
echo

run_cmd "Frissítés" "apt update -y"

[[ "$INSTALL_APACHE" == "true" ]] && run_cmd "Apache2 telepítése" "apt install -y apache2"
[[ "$INSTALL_PHP" == "true" ]] && run_cmd "PHP + Apache modul" "apt install -y php libapache2-mod-php"
[[ "$INSTALL_SSH" == "true" ]] && run_cmd "OpenSSH telepítése" "apt install -y openssh-server"
[[ "$INSTALL_MOSQUITTO" == "true" ]] && run_cmd "Mosquitto MQTT telepítése" "apt install -y mosquitto mosquitto-clients"
[[ "$INSTALL_MARIADB" == "true" ]] && run_cmd "MariaDB telepítése" "apt install -y mariadb-server"
run_cmd "Curl telepítése" "apt install -y curl"

# --- Node-RED ---
if [[ "$INSTALL_NODE_RED" == "true" ]]; then
    [[ -z "$NODE_VERSION" ]] && { echo -e "${RED}[ERROR] NODE_VERSION nincs a config.conf-ban!${RESET}"; exit 1; }

    run_cmd "Node.js setup" "curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -"
    run_cmd "Node.js telepítés" "apt install -y nodejs"
    run_cmd "Node-RED telepítés" "npm install -g --unsafe-perm node-red"

    if [[ "$DRY_RUN" == "false" ]]; then
        NR_PATH=$(which node-red)
        [[ -z "$NR_PATH" ]] && { echo -e "${RED}[ERROR] node-red nem található!${RESET}"; exit 1; }
    else
        NR_PATH="/usr/bin/env node-red"
    fi
    run_cmd "Node-RED service indítása" "systemctl daemon-reexec && systemctl daemon-reload"
fi

# --- Apache SSL ---
if [[ "$INSTALL_APACHE" == "true" && "$ENABLE_APACHE_SSL" == "true" ]]; then
    run_cmd "SSL modul engedélyezése" "/sbin/a2enmod ssl"
    run_cmd "default-ssl site engedélyezése" "/sbin/a2ensite default-ssl"
    run_cmd "Apache újratöltés" "systemctl reload apache2"
fi

# --- UFW ---
if [[ "$INSTALL_UFW" == "true" ]]; then
    run_cmd "UFW telepítése" "apt install -y ufw"
    run_cmd "SSH port engedélyezése" "/sbin/ufw allow ${PORT_SSH}/tcp"
    run_cmd "HTTP port engedélyezése" "/sbin/ufw allow ${PORT_HTTP}/tcp"
    run_cmd "HTTPS port engedélyezése" "/sbin/ufw allow ${PORT_HTTPS}/tcp"
    run_cmd "MQTT port engedélyezése" "/sbin/ufw allow ${PORT_MQTT}/tcp"
    run_cmd "Node-RED port engedélyezése" "/sbin/ufw allow ${PORT_NODE_RED}/tcp"
    [[ "$ALLOW_MARIADB_EXTERNAL" == "true" ]] && run_cmd "MariaDB port engedélyezése" "/sbin/ufw allow ${PORT_MARIADB}/tcp"
    run_cmd "UFW engedélyezése" "/sbin/ufw --force enable && /sbin/ufw reload"
fi

# --- Szolgáltatások indítása ---
run_cmd "Szolgáltatások engedélyezése és indítása" "systemctl enable apache2 ssh mosquitto mariadb && systemctl restart apache2 ssh mosquitto mariadb"

# --- Port ellenőrzés ---
echo
echo -e "${CYAN}▶ Szolgáltatások port ellenőrzése:${RESET}"
[[ "$INSTALL_SSH" == "true" ]] && check_port_nc "$PORT_SSH" "SSH"
[[ "$INSTALL_APACHE" == "true" ]] && check_port_nc "$PORT_HTTP" "HTTP"
[[ "$INSTALL_APACHE" == "true" ]] && check_port_nc "$PORT_HTTPS" "HTTPS"
[[ "$INSTALL_MOSQUITTO" == "true" ]] && check_port_nc "$PORT_MQTT" "MQTT"
[[ "$INSTALL_NODE_RED" == "true" ]] && check_port_nc "$PORT_NODE_RED" "Node-RED"
[[ "$INSTALL_MARIADB" == "true" ]] && check_port_nc "$PORT_MARIADB" "MariaDB"

echo
echo -e "${MAGENTA}${BOLD}"
echo "========================================"
echo "      Telepítés befejezve!"
echo "========================================"
echo -e "${RESET}"
