#!/bin/bash

# ANSI escape codes for colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Base URL for scripts
SCRIPT_BASE_URL="https://raw.githubusercontent.com/peditx/CoreDNS-master/refs/heads/main"

# Function to download and execute a script
execute_script() {
    local script_name="$1"
    local script_url="$SCRIPT_BASE_URL/$script_name"
    local temp_path="/tmp/$script_name"

    echo -e "${BLUE}--- Starting execution of $script_name ---${NC}"
    echo -e "${YELLOW}Downloading $script_name from $script_url...${NC}"
    wget "$script_url" -O "$temp_path"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to download $script_name. Please check the URL and your internet connection.${NC}"
        return 1
    fi
    echo -e "${GREEN}$script_name downloaded successfully.${NC}"

    echo -e "${YELLOW}Granting execute permissions to $script_name...${NC}"
    chmod +x "$temp_path"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to grant execute permissions to $script_name.${NC}"
        rm "$temp_path"
        return 1
    fi
    echo -e "${GREEN}Permissions granted.${NC}"

    echo -e "${YELLOW}Executing $script_name...${NC}"
    bash "$temp_path"
    local exit_status=$?
    if [ $exit_status -ne 0 ]; then
        echo -e "${RED}Error: $script_name exited with status $exit_status. Please review its output.${NC}"
    else
        echo -e "${GREEN}$script_name executed successfully.${NC}"
    fi

    rm "$temp_path" # Clean up temporary script file
    return $exit_status
}

# Main menu loop
while true; do
    echo -e "\n${GREEN}--- PeDitX's CoreDNS-master Menu ---${NC}"
    echo -e "${YELLOW}Please select your desired option:${NC}" # Added this line to make the prompt clear.
    echo -e "${BLUE}1) Install CoreDNS (install_coredns.sh)${NC}"
    echo -e "${BLUE}2) Install API Backend (install_api_backend.sh)${NC}"
    echo -e "${BLUE}3) Install Frontend UI (install_frontend_ui.sh)${NC}"
    echo -e "${BLUE}4) Apply Geo-IP Mod (mod_geo_ip.sh)${NC}"
    echo -e "${BLUE}5) Integrate Xray (mod_xray_integration.sh)${NC}"
    echo -e "${BLUE}6) Update Xray UI (update_xray_ui_integration.sh)${NC}"
    echo -e "${RED}7) Exit${NC}"

    read -p "Enter your choice: " choice

    case $choice in
        1)
            execute_script "install_coredns.sh"
            ;;
        2)
            execute_script "install_api_backend.sh"
            ;;
        3)
            execute_script "install_frontend_ui.sh"
            ;;
        4)
            execute_script "mod_geo_ip.sh"
            ;;
        5)
            execute_script "mod_xray_integration.sh"
            ;;
        6)
            execute_script "update_xray_ui_integration.sh"
            ;;
        7)
            echo -e "${GREEN}Exiting menu. Have a nice day!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Invalid option. Please enter a number between 1 and 7.${NC}"
            ;;
    esac
    echo -e "\n${YELLOW}Press Enter to continue...${NC}"
    read -n 1 -s -r # Waits for any key press
done
