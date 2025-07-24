#!/bin/bash

# ANSI escape codes for colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}--- CoreDNS Installation Script ---${NC}"
echo -e "${YELLOW}This script installs and configures CoreDNS on your system.${NC}"
echo -e "${YELLOW}Tested on Debian/Ubuntu based systems only.${NC}"

# --- Check for root privileges ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run with root privileges. Please use 'sudo bash install_coredns.sh'.${NC}"
    exit 1
fi

# --- Get user inputs ---
read -p "Do you want to update the system? (y/n): " UPDATE_SYSTEM
read -p "Desired Prometheus port (default: 9153): " PROMETHEUS_PORT
PROMETHEUS_PORT=${PROMETHEUS_PORT:-9153} # Set default if empty

read -p "Do you want to configure the firewall (UFW)? (y/n): " CONFIGURE_UFW

# --- 1. Update system ---
if [[ "$UPDATE_SYSTEM" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Updating system...${NC}"
    apt update && apt upgrade -y
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error updating system. Please check for issues and try again.${NC}"
        exit 1
    fi
    echo -e "${GREEN}System updated successfully.${NC}"
fi

# --- 2. Download and install CoreDNS ---
echo -e "${GREEN}Downloading and installing CoreDNS...${NC}"

# Get the latest stable version of CoreDNS
CORE_DNS_VERSION=$(curl -s https://api.github.com/repos/coredns/coredns/releases/latest | grep "tag_name" | cut -d : -f 2,3 | tr -d \"\, | awk '{print $1}')
if [ -z "$CORE_DNS_VERSION" ]; then
    echo -e "${RED}Error: Unable to fetch the latest CoreDNS version. Please check manually: https://github.com/coredns/coredns/releases${NC}"
    exit 1
fi

echo -e "${YELLOW}Latest CoreDNS version found: $CORE_DNS_VERSION${NC}"
CORE_DNS_TAR="coredns_$(echo $CORE_DNS_VERSION | tr -d v)_linux_amd64.tgz"
CORE_DNS_URL="https://github.com/coredns/coredns/releases/download/$CORE_DNS_VERSION/$CORE_DNS_TAR"

wget "$CORE_DNS_URL" -O /tmp/$CORE_DNS_TAR
if [ $? -ne 0 ]; then
    echo -e "${RED}Error downloading CoreDNS from $CORE_DNS_URL. Please check your internet connection.${NC}"
    exit 1
fi

tar -xvzf /tmp/$CORE_DNS_TAR -C /tmp/
sudo mv /tmp/coredns /usr/local/bin/

if [ $? -ne 0 ]; then
    echo -e "${RED}Error moving CoreDNS executable. Permissions might be an issue.${NC}"
    exit 1
fi

rm /tmp/$CORE_DNS_TAR /tmp/LICENSE.md /tmp/README.md

echo -e "${GREEN}CoreDNS installed successfully.${NC}"

# --- 3. Create CoreDNS user and directory ---
echo -e "${GREEN}Creating CoreDNS user and directory...${NC}"
# Create a system group for CoreDNS, if it doesn't exist
groupadd --system coredns || true
# Create a system user for CoreDNS, if it doesn't exist, and assign it to the coredns group
useradd -s /sbin/nologin --system -g coredns coredns || true

# Create the CoreDNS configuration directory
mkdir -p /etc/coredns
# Set ownership of the configuration directory to the coredns user and group
chown -R coredns:coredns /etc/coredns
echo -e "${GREEN}CoreDNS user and directory created successfully.${NC}"

# --- 4. Create Corefile ---
echo -e "${GREEN}Creating Corefile...${NC}"
# Write the CoreDNS configuration to /etc/coredns/Corefile
cat <<EOF > /etc/coredns/Corefile
. {
    # Bind CoreDNS to all network interfaces on port 53 (standard DNS port)
    bind 0.0.0.0

    # The 'forward' plugin sends DNS queries to upstream DNS servers.
    # '.' means all domains.
    forward . 8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 {
        # Prefer UDP protocol for DNS queries (standard practice)
        prefer_udp
        # Perform health checks on upstream servers every 10 seconds
        health_check 10s
    }

    # The 'cache' plugin caches DNS responses to improve performance and reduce upstream load.
    cache 300 # Cache for 5 minutes (300 seconds)

    # The 'log' plugin logs all DNS queries and responses.
    log

    # The 'errors' plugin logs any DNS errors.
    errors

    # The 'reload' plugin watches the Corefile for changes and reloads CoreDNS without downtime.
    # Essential for managing configurations via an API/UI.
    reload 30s # CoreDNS will check for Corefile changes every 30 seconds

    # The 'prometheus' plugin exposes CoreDNS metrics for monitoring tools like Prometheus.
    # Metrics will be available on the specified port.
    prometheus 0.0.0.0:${PROMETHEUS_PORT}
}

# --- Blocked Domains Configuration ---
# This section is for domain-specific forwarding (bypass).
# In the future, this part will be dynamically generated and managed by your API Backend.
# For now, it's commented out. You can add test domains here manually for initial testing.
# Example:
# blockeddomain.com {
#     forward . 5.6.7.8 9.10.11.12 { # These should be the IPs of your bypass DNS servers
#         prefer_udp
#         health_check 10s
#     }
# }
# anotherblockeddomain.org {
#     forward . 5.6.7.8 9.10.11.12 {
#         prefer_udp
#         health_check 10s
#     }
# }

EOF
echo -e "${GREEN}Corefile created successfully.${NC}"

# --- 5. Create Systemd service file ---
echo -e "${GREEN}Creating Systemd service file for CoreDNS...${NC}"
# Create the systemd service unit file for CoreDNS
cat <<EOF > /etc/systemd/system/coredns.service
[Unit]
Description=CoreDNS DNS server
Documentation=https://coredns.io
After=network.target

[Service]
# Set permissions for the service startup
PermissionsStartOnly=true
# Command to execute when starting the service, specifying the Corefile location
ExecStart=/usr/local/bin/coredns -conf /etc/coredns/Corefile
# Restart the service automatically if it fails
Restart=on-failure
# Run the service under the 'coredns' user and group for security
User=coredns
Group=coredns
# Set resource limits for the service
LimitNOFILE=1048576
LimitNPROC=512
# Capabilities required for CoreDNS to bind to privileged ports (like 53)
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
# Enable the service to start automatically during boot
WantedBy=multi-user.target
EOF
echo -e "${GREEN}Systemd service file created successfully.${NC}"

# --- 6. Enable and start CoreDNS service ---
echo -e "${GREEN}Enabling and starting CoreDNS service...${NC}"
# Reload systemd manager configuration
systemctl daemon-reload
# Enable the CoreDNS service to start on boot
systemctl enable coredns
# Start the CoreDNS service immediately
systemctl start coredns

# Check if the service started successfully
if [ $? -ne 0 ]; then
    echo -e "${RED}Error starting CoreDNS service. Please check the logs:${NC}"
    echo -e "${YELLOW}sudo journalctl -u coredns --no-pager${NC}"
    exit 1
fi

echo -e "${GREEN}CoreDNS service enabled and started successfully.${NC}"

# --- 7. Configure Firewall (UFW) ---
if [[ "$CONFIGURE_UFW" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Configuring firewall (UFW)...${NC}"
    # Check if UFW is installed
    if ! command -v ufw &> /dev/null; then
        echo -e "${YELLOW}UFW not found. Installing UFW...${NC}"
        apt install ufw -y
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error installing UFW. Please install manually.${NC}"
        fi
    fi

    # Allow UDP and TCP traffic on DNS port (53)
    ufw allow 53/udp
    ufw allow 53/tcp
    # Allow TCP traffic on the Prometheus monitoring port
    ufw allow ${PROMETHEUS_PORT}/tcp
    # Enable UFW (if not already enabled)
    ufw enable
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error enabling UFW. UFW might already be active or there's an issue.${NC}"
    fi
    echo -e "${GREEN}Firewall (UFW) configured successfully.${NC}"
else
    echo -e "${YELLOW}Firewall configuration skipped. Please ensure port 53 is open.${NC}"
fi

# --- Final Test ---
echo -e "${GREEN}--- Final CoreDNS Test ---${NC}"
echo -e "${YELLOW}Testing CoreDNS with dig...${NC}"
# Test DNS resolution using the local CoreDNS instance
dig @127.0.0.1 google.com

echo -e "${GREEN}CoreDNS installation completed successfully!${NC}"
echo -e "${YELLOW}You can now change your system's or other devices' DNS to your server's IP.${NC}"
echo -e "${YELLOW}To check CoreDNS status: sudo systemctl status coredns${NC}"
echo -e "${YELLOW}To view logs: sudo journalctl -u coredns --no-pager${NC}"
echo -e "${YELLOW}Prometheus monitoring port: ${PROMETHEUS_PORT}${NC}"
echo -e "${YELLOW}To manage blocked domains and for the UI, you will need to proceed with the API Backend and Frontend sections.${NC}"
echo -e "${YELLOW}Good luck!${NC}"
