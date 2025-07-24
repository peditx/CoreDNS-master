#!/bin/bash

# ANSI escape codes for colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}--- PeDitX's CoreDNS Bypass Manager - Pre-requisites and Menu Script Installer ---${NC}"
echo -e "${YELLOW}This script installs all necessary prerequisites for setting up CoreDNS Bypass Manager.${NC}"
echo -e "${YELLOW}It will then download and execute the main menu script (menu.sh) from GitHub.${NC}"
echo -e "${YELLOW}This script is designed for Debian/Ubuntu based operating systems.${NC}"

# --- Check for root privileges ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run with root privileges. Please use 'sudo bash install_prerequisites_and_menu.sh'.${NC}"
    exit 1
fi

# --- 1. System Update ---
echo -e "${GREEN}Updating system and installing essential tools...${NC}"
apt update && apt upgrade -y
if [ $? -ne 0 ]; then
    echo -e "${RED}Error updating system. Please check for issues and try again.${NC}"
    exit 1
fi
apt install -y curl wget git vim systemctl apt-transport-https ca-certificates software-properties-common
if [ $? -ne 0 ]; then
    echo -e "${RED}Error installing essential tools. Please check for issues.${NC}"
    exit 1
fi
echo -e "${GREEN}System and essential tools installed/updated successfully.${NC}"

# --- 2. Install Node.js and npm ---
echo -e "${GREEN}Checking for and installing Node.js and npm...${NC}"
if ! command -v node &> /dev/null || ! command -v npm &> /dev/null; then
    echo -e "${YELLOW}Node.js or npm not found. Installing LTS version...${NC}"
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    apt-get install -y nodejs
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error installing Node.js and npm. Please check for issues.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Node.js and npm installed successfully.${NC}"
else
    echo -e "${GREEN}Node.js and npm are already installed.${NC}"
fi
npm install -g create-react-app # Install create-react-app globally
echo -e "${GREEN}create-react-app installed successfully.${NC}"

# --- 3. Install Python3, pip, and venv ---
echo -e "${GREEN}Checking for and installing Python3, pip, and python3-venv...${NC}"
apt install -y python3 python3-pip python3-venv
if [ $? -ne 0 ]; then
    echo -e "${RED}Error installing Python3 and required tools. Please check for issues.${NC}"
    exit 1
fi
echo -e "${GREEN}Python3 and its tools installed successfully.${NC}"

# --- 4. Install PostgreSQL ---
echo -e "${GREEN}Checking for and installing PostgreSQL...${NC}"
apt install -y postgresql postgresql-contrib
if [ $? -ne 0 ]; then
    echo -e "${RED}Error installing PostgreSQL. Please check for issues.${NC}"
    exit 1
fi
echo -e "${GREEN}PostgreSQL installed successfully.${NC}"

# --- 5. Install Nginx ---
echo -e "${GREEN}Checking for and installing Nginx...${NC}"
apt install -y nginx
if [ $? -ne 0 ]; then
    echo -e "${RED}Error installing Nginx. Please check for issues.${NC}"
    exit 1
fi
echo -e "${GREEN}Nginx installed successfully.${NC}"

# --- 6. Install UFW (Firewall) ---
echo -e "${GREEN}Checking for and installing UFW (Firewall)...${NC}"
apt install -y ufw
if [ $? -ne 0 ]; then
    echo -e "${RED}Error installing UFW. Please check for issues.${NC}"
    exit 1
fi
echo -e "${GREEN}UFW installed successfully.${NC}"

# --- 7. Install ACL (for setfacl command) ---
echo -e "${GREEN}Checking for and installing ACL (for setfacl command)...${NC}"
apt install -y acl
if [ $? -ne 0 ]; then
    echo -e "${RED}Error installing ACL. Please check for issues.${NC}"
    exit 1
fi
echo -e "${GREEN}ACL installed successfully.${NC}"

echo -e "${GREEN}--- Prerequisites installation finished! ---${NC}"
echo -e "${YELLOW}Now, the main menu script (menu.sh) will be downloaded and executed from GitHub.${NC}"

# --- 8. Download and Run menu.sh ---
MENU_SCRIPT_URL="https://raw.githubusercontent.com/peditx/CoreDNS-master/refs/heads/main/menu.sh"
MENU_SCRIPT_PATH="/tmp/menu.sh"

echo -e "${GREEN}Downloading menu script from: $MENU_SCRIPT_URL${NC}"
wget "$MENU_SCRIPT_URL" -O "$MENU_SCRIPT_PATH"
if [ $? -ne 0 ]; then
    echo -e "${RED}Error downloading menu script. Please check the URL and your internet connection.${NC}"
    exit 1
fi
echo -e "${GREEN}Menu script downloaded successfully: $MENU_SCRIPT_PATH${NC}"

# --- 9. Give execute permissions and run ---
echo -e "${GREEN}Granting execute permissions and running the menu script...${NC}"
chmod +x "$MENU_SCRIPT_PATH"
if [ $? -ne 0 ]; then
    echo -e "${RED}Error granting execute permissions to the menu script. Please check permissions.${NC}"
    exit 1
fi

# Execute the menu script with sudo
bash "$MENU_SCRIPT_PATH"
if [ $? -ne 0 ]; then
    echo -e "${RED}Error executing the menu script. Please check the error messages.${NC}"
    exit 1
fi

echo -e "${GREEN}--- PeDitX's CoreDNS Bypass Manager installation and setup complete! ---${NC}"
echo -e "${YELLOW}You can now manage different parts of the system through the menu script.${NC}"
echo -e "${YELLOW}Good luck!${NC}"
