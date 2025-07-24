#!/bin/bash

# ANSI escape codes for colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}--- PeDitX's CoreDNS Bypass Manager - Pre-requisites and Menu Script Installer ---${NC}"
echo -e "${YELLOW}Installing prerequisites...${NC}"

# --- Check for root privileges ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root (e.g., sudo bash $0).${NC}"
    exit 1
fi

# --- 1. System Update ---
echo -e "${GREEN}Updating system and installing essential packages...${NC}"
apt update && apt upgrade -y
if [ $? -ne 0 ]; then
    echo -e "${RED}Error during system update.${NC}"
    exit 1
fi

apt install -y curl wget git vim apt-transport-https ca-certificates software-properties-common
if [ $? -ne 0 ]; then
    echo -e "${RED}Error installing essential tools.${NC}"
    exit 1
fi

# --- 2. Node.js and npm ---
echo -e "${GREEN}Installing Node.js (LTS) and npm...${NC}"
if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt install -y nodejs
    if [ $? -ne 0 ]; then
        echo -e "${RED}Node.js installation failed.${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}Node.js and npm already installed.${NC}"
fi

npm install -g create-react-app
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to install create-react-app.${NC}"
    exit 1
fi

# --- 3. Python3 and pip ---
echo -e "${GREEN}Installing Python3, pip, and venv...${NC}"
apt install -y python3 python3-pip python3-venv
if [ $? -ne 0 ]; then
    echo -e "${RED}Python installation failed.${NC}"
    exit 1
fi

# --- 4. PostgreSQL ---
echo -e "${GREEN}Installing PostgreSQL...${NC}"
apt install -y postgresql postgresql-contrib
if [ $? -ne 0 ]; then
    echo -e "${RED}PostgreSQL installation failed.${NC}"
    exit 1
fi

# --- 5. Nginx ---
echo -e "${GREEN}Installing Nginx...${NC}"
apt install -y nginx
if [ $? -ne 0 ]; then
    echo -e "${RED}Nginx installation failed.${NC}"
    exit 1
fi

# --- 6. UFW ---
echo -e "${GREEN}Installing UFW (Firewall)...${NC}"
apt install -y ufw
if [ $? -ne 0 ]; then
    echo -e "${RED}UFW installation failed.${NC}"
    exit 1
fi

# --- 7. ACL ---
echo -e "${GREEN}Installing ACL...${NC}"
apt install -y acl
if [ $? -ne 0 ]; then
    echo -e "${RED}ACL installation failed.${NC}"
    exit 1
fi

echo -e "${GREEN}All prerequisites installed successfully!${NC}"

# --- 8. Download menu.sh ---
MENU_SCRIPT_URL="https://raw.githubusercontent.com/peditx/CoreDNS-master/main/menu.sh"
MENU_SCRIPT_PATH="/tmp/menu.sh"

echo -e "${GREEN}Downloading menu.sh from GitHub...${NC}"
wget -q "$MENU_SCRIPT_URL" -O "$MENU_SCRIPT_PATH"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to download menu.sh. Check your internet or the URL.${NC}"
    exit 1
fi

chmod +x "$MENU_SCRIPT_PATH"
bash "$MENU_SCRIPT_PATH"
if [ $? -ne 0 ]; then
    echo -e "${RED}menu.sh execution failed.${NC}"
    exit 1
fi

echo -e "${GREEN}--- Installation complete. Enjoy! ---${NC}"
