#!/bin/bash

# ==============================
#  Debian Server Installer
# ==============================

CONFIG_FILE="./config.conf"

# --- Színek ---
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
RESET="\e[0m"

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
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY-RUN] $*${RESET}"
    else
        echo -e "${CYAN}[RUN] $*${RESET}"
        eval "$@"
    fi
}

banner() {
    clear
    echo -e "${BLUE}"
    echo "========================================"
    echo "   Debian Szerver Telepítő Script"
    echo "========================================"
    echo -e "${RESET}"
}

# --- Internet kapcsolat ellenőrzése ---
echo -e "${BLUE}▶ Internet kapcsolat ellenőrzése (8.8.8.8)${RESET}"

if ping -c 3 -W 2 8.8.8.8 > /dev/null 2>&1; then
    echo -e "${GREEN}✔ Internet kapcsolat rendben${RESET}\n"
else
    echo -e "${RED}✖ Nincs internet kapcsolat!${RESET}"
    echo -e "${YELLOW}A telepítés megszakítva.${RESET}"
    exit 1
fi


install_pkg() {
    local NAME="$1"
    local CMD="$2"

    echo -e "${BLUE}▶ Telepítés: $NAME${RESET}"
    run_cmd "$CMD"
    echo -e "${GREEN}✔ Kész: $NAME${RESET}\n"
}

# ==============================
#  TELEPÍTÉS
# ==============================

banner
echo -e "${CYAN}Log fájl: $LOG_FILE${RESET}"
echo -e "${CYAN}Dry-run mód: $DRY_RUN${RESET}\n"

run_cmd "apt update -y"

[[ "$INSTALL_APACHE" == "true" ]] && install_pkg "Apache2" "apt install -y apache2"
[[ "$INSTALL_PHP" == "true" ]] && install_pkg "PHP + Apache modul" "apt install -y php libapache2-mod-php"
[[ "$INSTALL_SSH" == "true" ]] && install_pkg "OpenSSH" "apt install -y openssh-server"
[[ "$INSTALL_MOSQUITTO" == "true" ]] && install_pkg "Mosquitto MQTT" "apt install -y mosquitto mosquitto-clients"
[[ "$INSTALL_MARIADB" == "true" ]] && install_pkg "MariaDB Server" "apt install -y mariadb-server"

# --- Node-RED ---
if [[ "$INSTALL_NODE_RED" == "true" ]]; then
    echo -e "${BLUE}▶ Node.js ${NODE_VERSION} + Node-RED telepítése${RESET}"
    run_cmd "curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -"
    run_cmd "apt install -y nodejs"
    run_cmd "npm install -g --unsafe-perm node-red"
    echo -e "${GREEN}✔ Node-RED telepítve${RESET}\n"
fi

# --- UFW ---
if [[ "$INSTALL_UFW" == "true" ]]; then
    echo -e "${BLUE}▶ UFW tűzfal telepítése és konfigurálása${RESET}"

    install_pkg "UFW" "apt install -y ufw"

    echo -e "${CYAN}Portok engedélyezése...${RESET}"

    run_cmd "ufw allow ${PORT_SSH}/tcp comment 'SSH'"
    run_cmd "ufw allow ${PORT_HTTP}/tcp comment 'HTTP'"
    run_cmd "ufw allow ${PORT_HTTPS}/tcp comment 'HTTPS'"
    run_cmd "ufw allow ${PORT_MQTT}/tcp comment 'MQTT'"
    run_cmd "ufw allow ${PORT_NODE_RED}/tcp comment 'Node-RED'"

    if [[ "$ALLOW_MARIADB_EXTERNAL" == "true" ]]; then
        run_cmd "ufw allow ${PORT_MARIADB}/tcp comment 'MariaDB'"
    else
        echo -e "${YELLOW}ℹ MariaDB port nem lett megnyitva (csak localhost)${RESET}"
    fi

    # MQTT SSL opcionális
    if [[ -n "$PORT_MQTT_SSL" ]]; then
        run_cmd "ufw allow ${PORT_MQTT_SSL}/tcp comment 'MQTT SSL'"
    fi

    echo -e "${CYAN}UFW engedélyezése...${RESET}"
    run_cmd "ufw --force enable"
    run_cmd "ufw reload"

    echo -e "${GREEN}✔ UFW konfigurálva${RESET}\n"
fi


# --- Szolgáltatások ---
echo -e "${BLUE}▶ Szolgáltatások engedélyezése${RESET}"
run_cmd "systemctl enable apache2 ssh mosquitto mariadb"
run_cmd "systemctl restart apache2 ssh mosquitto mariadb"

# --- Tűzfal státusz ---
echo -e "${BLUE}▶ Tűzfal státusz${RESET}"
run_cmd "ufw status verbose"


# --- Tűzfal portellenőrzés ---
check_port() {
    local PORT="$1"
    local NAME="$2"

    if ss -lnt | awk '{print $4}' | grep -q ":$PORT$"; then
        echo -e "${GREEN}✔ $NAME ($PORT) LISTENING${RESET}"
    else
        echo -e "${RED}✖ $NAME ($PORT) NEM ELÉRHETŐ${RESET}"
    fi
}

echo -e "${GREEN}"
echo "========================================"
echo "  Telepítés befejezve!"
echo "========================================"
echo -e "${RESET}"
