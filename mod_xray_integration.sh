#!/bin/bash

# ANSI escape codes for colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}--- Xray DNS Proxy Integration Script ---${NC}"
echo -e "${YELLOW}This script integrates Xray as a DNS proxy for selective routing.${NC}"
echo -e "${YELLOW}It installs Xray, configures it, and updates your API Backend for control.${NC}"
echo -e "${YELLOW}This process overwrites models.py and main.py files.${NC}"
echo -e "${YELLOW}Please back up your API Backend files before proceeding.${NC}"
echo -e "${YELLOW}Tested on Debian/Ubuntu based systems.${NC}"

# --- Check for root privileges ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run with root privileges. Please use 'sudo bash mod_xray_integration.sh'.${NC}"
    exit 1
fi

# --- Get Xray Configuration Details ---
echo -e "${YELLOW}Please provide your Xray server details for the local DNS proxy setup.${NC}"
read -p "Remote Xray Server IP/Domain (e.g., your.xray.server.com): " REMOTE_XRAY_SERVER_ADDRESS
while [ -z "$REMOTE_XRAY_SERVER_ADDRESS" ]; do
    echo -e "${RED}Error: Remote Xray Server address cannot be empty.${NC}"
    read -p "Remote Xray Server IP/Domain: " REMOTE_XRAY_SERVER_ADDRESS
done

read -p "Remote Xray Server Port (e.g., 443): " REMOTE_XRAY_SERVER_PORT
REMOTE_XRAY_SERVER_PORT=${REMOTE_XRAY_SERVER_PORT:-443}

read -p "Xray UUID (e.g., a0e43d83-4ee1-4d1a-9f5b-6f8c4d1e2a3b): " XRAY_UUID
while [ -z "$XRAY_UUID" ]; do
    echo -e "${RED}Error: Xray UUID cannot be empty.${NC}"
    read -p "Xray UUID: " XRAY_UUID
done

read -p "Xray Protocol (e.g., vmess, vless, trojan - default: vmess): " XRAY_PROTOCOL
XRAY_PROTOCOL=${XRAY_PROTOCOL:-vmess}

read -p "Xray Network (e.g., ws, tcp, kcp - default: ws): " XRAY_NETWORK
XRAY_NETWORK=${XRAY_NETWORK:-ws}

read -p "Xray TLS (true/false - default: true): " XRAY_TLS
XRAY_TLS=${XRAY_TLS:-true}

XRAY_TLS_SETTINGS=""
if [[ "$XRAY_TLS" == "true" ]]; then
  read -p "Xray Server Name (if using TLS, e.g., your.xray.server.com - leave empty if not specific): " XRAY_SERVER_NAME
  XRAY_TLS_SETTINGS="\"security\": \"tls\","
  if [ -n "$XRAY_SERVER_NAME" ]; then
    XRAY_TLS_SETTINGS="${XRAY_TLS_SETTINGS}\"tlsSettings\": {\"allowInsecure\": false, \"serverName\": \"${XRAY_SERVER_NAME}\"},"
  fi
fi

XRAY_WS_PATH=""
if [[ "$XRAY_NETWORK" == "ws" ]]; then
  read -p "Xray WebSocket Path (e.g., /your_path - default: /): " XRAY_WS_PATH_INPUT
  XRAY_WS_PATH=${XRAY_WS_PATH_INPUT:-/}
  XRAY_WS_SETTINGS="\"wsSettings\": {\"path\": \"${XRAY_WS_PATH}\"}"
fi

# Define paths
API_DIR="/opt/dns_bypass_api"
XRAY_INSTALL_PATH="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_FILE="$XRAY_CONFIG_DIR/config.json"
API_MODELS_FILE="$API_DIR/models.py"
API_MAIN_FILE="$API_DIR/main.py"

# --- Backup existing API files ---
echo -e "${GREEN}Backing up existing API Backend files...${NC}"
cp "$API_MODELS_FILE" "$API_MODELS_FILE.bak_xray.$(date +%Y%m%d%H%M%S)"
cp "$API_MAIN_FILE" "$API_MAIN_FILE.bak_xray.$(date +%Y%m%d%H%M%S)"
echo -e "${GREEN}API Backend file backups created with .bak_xray.TIMESTAMP extension.${NC}"

# --- 1. Install Xray ---
echo -e "${GREEN}Installing Xray...${NC}"
bash -c "$(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)"
if [ $? -ne 0 ]; then
    echo -e "${RED}Error installing Xray. Please check the Xray installation script.${NC}"
    exit 1
fi
echo -e "${GREEN}Xray installed successfully.${NC}"

# --- 2. Configure Xray for local DNS proxy ---
echo -e "${GREEN}Configuring Xray for local DNS proxy...${NC}"
mkdir -p "$XRAY_CONFIG_DIR"
cat <<EOF > "$XRAY_CONFIG_FILE"
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 1053,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "port": 53,
        "network": "udp,tcp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["dns"]
      },
      "tag": "dns_inbound"
    }
  ],
  "outbounds": [
    {
      "protocol": "$XRAY_PROTOCOL",
      "settings": {
        "vnext": [
          {
            "address": "$REMOTE_XRAY_SERVER_ADDRESS",
            "port": $REMOTE_XRAY_SERVER_PORT,
            "users": [
              {
                "id": "$XRAY_UUID",
                "alterId": 0,
                "security": "auto"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "$XRAY_NETWORK",
        $XRAY_TLS_SETTINGS
        $XRAY_WS_SETTINGS
      },
      "tag": "proxy_out"
    },
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "direct_out"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["dns_inbound"],
        "port": 53,
        "outboundTag": "proxy_out"
      },
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "direct_out"
      }
    ]
  }
}
EOF
echo -e "${GREEN}Xray configuration file created at $XRAY_CONFIG_FILE.${NC}"

# Restart Xray service to apply changes
echo -e "${YELLOW}Restarting Xray service...${NC}"
systemctl restart xray
if [ $? -ne 0 ]; then
    echo -e "${RED}Error restarting Xray service. Please check Xray logs: sudo journalctl -u xray --no-pager${NC}"
    exit 1
fi
echo -e "${GREEN}Xray service restarted successfully and running on port 1053 for DNS proxy.${NC}"

# --- 3. Update API Backend models.py ---
echo -e "${GREEN}Updating API Backend models.py for Xray integration...${NC}"
cd "$API_DIR"
source venv/bin/activate
cat <<EOF > "$API_MODELS_FILE"
from sqlalchemy import Column, Integer, String, Boolean, Enum
from database import Base

class Domain(Base):
    __tablename__ = "domains"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, unique=True, index=True)
    bypass_ips = Column(String, nullable=True) # IPs if not using Xray, or specific Xray outbounds
    use_xray_proxy = Column(Boolean, default=False) # New field

class GeoIPRule(Base):
    __tablename__ = "geoip_rules"
    id = Column(Integer, primary_key=True, index=True)
    country_code = Column(String, unique=True, index=True) # e.g., "IR", "US", "CN"
    action_type = Column(String, default="forward_to_custom_dns") # e.g., "forward_to_custom_dns", "block", "forward_to_default"
    bypass_ips = Column(String, nullable=True) # Specific bypass DNS servers for this country, if action_type is forward_to_custom_dns
    use_xray_proxy = Column(Boolean, default=False) # New field for GeoIP rules

class GeoSiteList(Base):
    __tablename__ = "geosite_lists"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, unique=True, index=True) # e.g., "Iranian_Sites", "US_Streaming"
    domains_list = Column(String) # Comma-separated domains
    bypass_ips = Column(String, nullable=True) # IPs if not using Xray
    use_xray_proxy = Column(Boolean, default=False) # New field for GeoSite lists
EOF
echo -e "${GREEN}models.py updated successfully.${NC}"

# --- 4. Update API Backend main.py ---
echo -e "${GREEN}Updating API Backend main.py for Xray integration logic...${NC}"
cat <<EOF > "$API_MAIN_FILE"
import os
import subprocess
import tarfile
from typing import List, Optional
from fastapi import FastAPI, Depends, HTTPException, status
from sqlalchemy.orm import Session
from pydantic import BaseModel
from dotenv import load_dotenv
import httpx
import geoip2.database

import models
from database import engine, get_db

load_dotenv()

models.Base.metadata.create_all(bind=engine)

app = FastAPI()

COREDNS_CONFIG_PATH = os.getenv("COREDNS_CONFIG_PATH")
COREDNS_RELOAD_COMMAND = os.getenv("COREDNS_RELOAD_COMMAND")
MAXMIND_LICENSE_KEY = os.getenv("MAXMIND_LICENSE_KEY")
COREDNS_GEOIP_DB_PATH = os.getenv("COREDNS_GEOIP_DB_PATH")

# New constant for Xray DNS proxy
XRAY_DNS_PROXY_ADDRESS = "127.0.0.1:1053"

if not COREDNS_CONFIG_PATH or not COREDNS_RELOAD_COMMAND:
    raise ValueError("COREDNS_CONFIG_PATH or COREDNS_RELOAD_COMMAND is not set in .env")

# Pydantic models (updated with use_xray_proxy)
class DomainBase(BaseModel):
    name: str
    bypass_ips: Optional[str] = None
    use_xray_proxy: bool = False

class DomainCreate(DomainBase):
    pass

class Domain(DomainBase):
    id: int
    class Config:
        from_attributes = True

class GeoIPRuleBase(BaseModel):
    country_code: str
    action_type: str = "forward_to_custom_dns"
    bypass_ips: Optional[str] = None
    use_xray_proxy: bool = False

class GeoIPRuleCreate(GeoIPRuleBase):
    pass

class GeoIPRule(GeoIPRuleBase):
    id: int
    class Config:
        from_attributes = True

class GeoSiteListBase(BaseModel):
    name: str
    domains_list: str
    bypass_ips: Optional[str] = None
    use_xray_proxy: bool = False

class GeoSiteListCreate(GeoSiteListBase):
    pass

class GeoSiteList(GeoSiteListBase):
    id: int
    class Config:
        from_attributes = True


@app.on_event("startup")
async def startup_event():
    """Ensures the initial Corefile exists."""
    if not os.path.exists(COREDNS_CONFIG_PATH):
        initial_corefile_content = """
. {
    bind 0.0.0.0
    forward . 8.8.8.8 8.8.4.4 { prefer_udp }
    cache 300
    log
    errors
    reload 30s
    prometheus 0.0.0.0:9153
}
        """
        try:
            with open(COREDNS_CONFIG_PATH, "w") as f:
                f.write(initial_corefile_content.strip())
            print(f"INFO: Initial Corefile created at {COREDNS_CONFIG_PATH}")
        except Exception as e:
            print(f"ERROR: Failed to create initial Corefile: {e}")


def generate_coredns_config(db: Session) -> str:
    """Generates the CoreDNS configuration content based on database entries."""
    domains = db.query(models.Domain).all()
    geoip_rules = db.query(models.GeoIPRule).all()
    geosite_lists = db.query(models.GeoSiteList).all()

    config_parts = []

    base_config = """
. {
    bind 0.0.0.0
    forward . 8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 {
        prefer_udp
        health_check 10s
    }
    cache 300
    log
    errors
    reload 30s
    prometheus 0.0.0.0:9153
"""
    config_parts.append(base_config)

    # Add GeoIP Policy plugin if GeoIP DB path is set and DB exists
    if COREDNS_GEOIP_DB_PATH and os.path.exists(COREDNS_GEOIP_DB_PATH):
        policy_block_lines = []
        policy_block_lines.append(f"    policy {{")
        policy_block_lines.append(f"        geoip {{ db {COREDNS_GEOIP_DB_PATH} }}")

        for rule in geoip_rules:
            target_ips = ""
            if rule.use_xray_proxy:
                target_ips = XRAY_DNS_PROXY_ADDRESS
            elif rule.bypass_ips:
                target_ips = rule.bypass_ips.replace(',', ' ')
            else:
                target_ips = "8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1" # Default upstream if no specific IPs

            if rule.action_type == "forward_to_custom_dns":
                policy_block_lines.append(f"""
        if {{geoip country_code}} is "{rule.country_code}" {{
            forward . {target_ips} {{
                prefer_udp
                health_check 10s
            }}
        }}""")
            elif rule.action_type == "block":
                policy_block_lines.append(f"""
        if {{geoip country_code}} is "{rule.country_code}" {{
            error # Block queries from this country
        }}""")
            # "forward_to_default" is handled by the final else block

        policy_block_lines.append("""
        else {
            forward . 8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 {
                prefer_udp
                health_check 10s
            }
        }""")
        policy_block_lines.append(f"    }}") # End of policy block
        config_parts.append("\n".join(policy_block_lines))

    config_parts.append("}") # Close the global '.' block

    # Add specific domain and GeoSite rules
    all_forward_rules = []

    # Process Domains
    for domain in domains:
        target_ips = ""
        if domain.use_xray_proxy:
            target_ips = XRAY_DNS_PROXY_ADDRESS
        elif domain.bypass_ips:
            target_ips = domain.bypass_ips.replace(',', ' ')
        else:
            target_ips = "8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1" # Default if no specific IPs

        all_forward_rules.append(f"""
{domain.name} {{
    forward . {target_ips} {{
        prefer_udp
        health_check 10s
    }}
}}
""")

    # Process GeoSiteLists
    for geosite in geosite_lists:
        target_ips = ""
        if geosite.use_xray_proxy:
            target_ips = XRAY_DNS_PROXY_ADDRESS
        elif geosite.bypass_ips:
            target_ips = geosite.bypass_ips.replace(',', ' ')
        else:
            target_ips = "8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1" # Default if no specific IPs

        domains_list_items = [d.strip() for d in geosite.domains_list.split(',') if d.strip()]
        for domain_name in domains_list_items:
            all_forward_rules.append(f"""
{domain_name} {{
    forward . {target_ips} {{
        prefer_udp
        health_check 10s
    }}
}}
""")
    
    config_parts.append("\n".join(all_forward_rules))

    return "\n".join(config_parts)


def apply_coredns_config():
    """Writes the new CoreDNS config and reloads the CoreDNS service."""
    try:
        db_session = next(get_db())
        new_config_content = generate_coredns_config(db_session)
        db_session.close()

        with open(COREDNS_CONFIG_PATH, "w") as f:
            f.write(new_config_content.strip())
        
        print(f"INFO: CoreDNS config updated at {COREDNS_CONFIG_PATH}")

        result = subprocess.run(COREDNS_RELOAD_COMMAND.split(), capture_output=True, text=True, check=True)
        print(f"INFO: CoreDNS reload successful: {result.stdout}")
        if result.stderr:
            print(f"WARN: CoreDNS reload stderr: {result.stderr}")
        return {"message": "CoreDNS configuration applied successfully"}
    except subprocess.CalledProcessError as e:
        print(f"ERROR: CoreDNS reload failed. Stderr: {e.stderr}. Stdout: {e.stdout}")
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"Failed to reload CoreDNS: {e.stderr.strip()}")
    except IOError as e:
        print(f"ERROR: Failed to write Corefile: {e}")
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"Failed to write CoreDNS config file: {e}")
    except Exception as e:
        print(f"ERROR: An unexpected error occurred during config application: {e}")
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"An unexpected error occurred: {e}")

# --- API Endpoints for Domain Management (Existing) ---
@app.post("/domains/", response_model=Domain, status_code=status.HTTP_201_CREATED)
def create_domain(domain: DomainCreate, db: Session = Depends(get_db)):
    """Add a new domain to the bypass list."""
    db_domain = db.query(models.Domain).filter(models.Domain.name == domain.name).first()
    if db_domain:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Domain already exists")
    db_domain = models.Domain(name=domain.name, bypass_ips=domain.bypass_ips, use_xray_proxy=domain.use_xray_proxy)
    db.add(db_domain)
    db.commit()
    db.refresh(db_domain)
    apply_coredns_config()
    return db_domain

@app.get("/domains/", response_model=List[Domain])
def read_domains(skip: int = 0, limit: int = 100, db: Session = Depends(get_db)):
    """Retrieve a list of all domains in the bypass list."""
    domains = db.query(models.Domain).offset(skip).limit(limit).all()
    return domains

@app.get("/domains/{domain_id}", response_model=Domain)
def read_domain(domain_id: int, db: Session = Depends(get_db)):
    """Retrieve a specific domain by its ID."""
    db_domain = db.query(models.Domain).filter(models.Domain.id == domain_id).first()
    if db_domain is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Domain not found")
    return db_domain

@app.put("/domains/{domain_id}", response_model=Domain)
def update_domain(domain_id: int, domain: DomainCreate, db: Session = Depends(get_db)):
    """Update an existing domain's bypass IPs."""
    db_domain = db.query(models.Domain).filter(models.Domain.id == domain_id).first()
    if db_domain is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Domain not found")
    db_domain.name = domain.name
    db_domain.bypass_ips = domain.bypass_ips
    db_domain.use_xray_proxy = domain.use_xray_proxy
    db.commit()
    db.refresh(db_domain)
    apply_coredns_config()
    return db_domain

@app.delete("/domains/{domain_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_domain(domain_id: int, db: Session = Depends(get_db)):
    """Delete a domain from the bypass list."""
    db_domain = db.query(models.Domain).filter(models.Domain.id == domain_id).first()
    if db_domain is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Domain not found")
    db.delete(db_domain)
    db.commit()
    apply_coredns_config()
    return {"message": "Domain deleted successfully"}

# --- New API Endpoints for GeoIPRule Management ---
@app.post("/geoip_rules/", response_model=GeoIPRule, status_code=status.HTTP_201_CREATED)
def create_geoip_rule(rule: GeoIPRuleCreate, db: Session = Depends(get_db)):
    """Add a new GeoIP rule."""
    db_rule = db.query(models.GeoIPRule).filter(models.GeoIPRule.country_code == rule.country_code).first()
    if db_rule:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="GeoIP rule for this country code already exists")
    db_rule = models.GeoIPRule(country_code=rule.country_code, action_type=rule.action_type, bypass_ips=rule.bypass_ips, use_xray_proxy=rule.use_xray_proxy)
    db.add(db_rule)
    db.commit()
    db.refresh(db_rule)
    apply_coredns_config()
    return db_rule

@app.get("/geoip_rules/", response_model=List[GeoIPRule])
def read_geoip_rules(skip: int = 0, limit: int = 100, db: Session = Depends(get_db)):
    """Retrieve a list of all GeoIP rules."""
    rules = db.query(models.GeoIPRule).offset(skip).limit(limit).all()
    return rules

@app.get("/geoip_rules/{rule_id}", response_model=GeoIPRule)
def read_geoip_rule(rule_id: int, db: Session = Depends(get_db)):
    """Retrieve a specific GeoIP rule by its ID."""
    db_rule = db.query(models.GeoIPRule).filter(models.GeoIPRule.id == rule_id).first()
    if db_rule is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="GeoIP rule not found")
    return db_rule

@app.put("/geoip_rules/{rule_id}", response_model=GeoIPRule)
def update_geoip_rule(rule_id: int, rule: GeoIPRuleCreate, db: Session = Depends(get_db)):
    """Update an existing GeoIP rule."""
    db_rule = db.query(models.GeoIPRule).filter(models.GeoIPRule.id == rule_id).first()
    if db_rule is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="GeoIP rule not found")
    db_rule.country_code = rule.country_code
    db_rule.action_type = rule.action_type
    db_rule.bypass_ips = rule.bypass_ips
    db_rule.use_xray_proxy = rule.use_xray_proxy
    db.commit()
    db.refresh(db_rule)
    apply_coredns_config()
    return db_rule

@app.delete("/geoip_rules/{rule_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_geoip_rule(rule_id: int, db: Session = Depends(get_db)):
    """Delete a GeoIP rule."""
    db_rule = db.query(models.GeoIPRule).filter(models.GeoIPRule.id == rule_id).first()
    if db_rule is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="GeoIP rule not found")
    db.delete(db_rule)
    db.commit()
    apply_coredns_config()
    return {"message": "GeoIP rule deleted successfully"}

# --- New API Endpoints for GeoSiteList Management ---
@app.post("/geosite_lists/", response_model=GeoSiteList, status_code=status.HTTP_201_CREATED)
def create_geosite_list(geosite: GeoSiteListCreate, db: Session = Depends(get_db)):
    """Add a new GeoSite list."""
    db_geosite = db.query(models.GeoSiteList).filter(models.GeoSiteList.name == geosite.name).first()
    if db_geosite:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="GeoSite list with this name already exists")
    db_geosite = models.GeoSiteList(name=geosite.name, domains_list=geosite.domains_list, bypass_ips=geosite.bypass_ips, use_xray_proxy=geosite.use_xray_proxy)
    db.add(db_geosite)
    db.commit()
    db.refresh(db_geosite)
    apply_coredns_config()
    return db_geosite

@app.get("/geosite_lists/", response_model=List[GeoSiteList])
def read_geosite_lists(skip: int = 0, limit: int = 100, db: Session = Depends(get_db)):
    """Retrieve a list of all GeoSite lists."""
    geosites = db.query(models.GeoSiteList).offset(skip).limit(limit).all()
    return geosites

@app.get("/geosite_lists/{list_id}", response_model=GeoSiteList)
def read_geosite_list(list_id: int, db: Session = Depends(get_db)):
    """Retrieve a specific GeoSite list by its ID."""
    db_geosite = db.query(models.GeoSiteList).filter(models.GeoSiteList.id == list_id).first()
    if db_geosite is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="GeoSite list not found")
    return db_geosite

@app.put("/geosite_lists/{list_id}", response_model=GeoSiteList)
def update_geosite_list(list_id: int, geosite: GeoSiteListCreate, db: Session = Depends(get_db)):
    """Update an existing GeoSite list."""
    db_geosite = db.query(models.GeoSiteList).filter(models.GeoSiteList.id == list_id).first()
    if db_geosite is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="GeoSite list not found")
    db_geosite.name = geosite.name
    db_geosite.domains_list = geosite.domains_list
    db_geosite.bypass_ips = geosite.bypass_ips
    db_geosite.use_xray_proxy = geosite.use_xray_proxy
    db.commit()
    db.refresh(db_geosite)
    apply_coredns_config()
    return db_geosite

@app.delete("/geosite_lists/{list_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_geosite_list(list_id: int, db: Session = Depends(get_db)):
    """Delete a GeoSite list."""
    db_geosite = db.query(models.GeoSiteList).filter(models.GeoSiteList.id == list_id).first()
    if db_geosite is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="GeoSite list not found")
    db.delete(db_geosite)
    db.commit()
    apply_coredns_config()
    return {"message": "GeoSite list deleted successfully"}

# --- New API Endpoint for GeoIP Database Update ---
@app.post("/geoip/update_database/", status_code=status.HTTP_200_OK)
async def update_geoip_database_endpoint():
    """
    Downloads and updates the MaxMind GeoLite2 City database.
    Requires MAXMIND_LICENSE_KEY to be set in .env.
    """
    if not MAXMIND_LICENSE_KEY:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="MAXMIND_LICENSE_KEY is not set in .env file. Please add it.")
    if not COREDNS_GEOIP_DB_PATH:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="COREDNS_GEOIP_DB_PATH is not set in .env file.")

    GEOIP_DB_DOWNLOAD_URL = f"https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&license_key={MAXMIND_LICENSE_KEY}&suffix=tar.gz"
    TEMP_TAR_GZ = "/tmp/GeoLite2-City.tar.gz"
    TEMP_EXTRACT_DIR = "/tmp/maxmind_extract"

    try:
        # 1. Download the database
        print(f"INFO: Downloading GeoIP database from MaxMind...")
        async with httpx.AsyncClient() as client:
            response = await client.get(GEOIP_DB_DOWNLOAD_URL, follow_redirects=True, timeout=30)
            response.raise_for_status() # Raise an exception for HTTP errors (4xx or 5xx)
            with open(TEMP_TAR_GZ, "wb") as f:
                f.write(response.content)
        print(f"INFO: Downloaded to {TEMP_TAR_GZ}")

        # 2. Extract the database
        print(f"INFO: Extracting GeoIP database...")
        os.makedirs(TEMP_EXTRACT_DIR, exist_ok=True)
        with tarfile.open(TEMP_TAR_GZ, "r:gz") as tar:
            # Find the .mmdb file within the tarball
            mmdb_member = [m for m in tar.getmembers() if m.name.endswith('.mmdb')]
            if not mmdb_member:
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="No .mmdb file found in the downloaded tarball.")
            
            tar.extract(mmdb_member[0], path=TEMP_EXTRACT_DIR)
            extracted_mmdb_path = os.path.join(TEMP_EXTRACT_DIR, mmdb_member[0].name)
            
            # Ensure target directory exists for CoreDNS DB
            os.makedirs(os.path.dirname(COREDNS_GEOIP_DB_PATH), exist_ok=True)
            
            # Move the .mmdb file to the CoreDNS config directory
            os.replace(extracted_mmdb_path, COREDNS_GEOIP_DB_PATH) # os.replace for atomic move
        print(f"INFO: GeoIP database moved to {COREDNS_GEOIP_DB_PATH}")

        # Optional: Verify DB (requires geoip2.database)
        try:
            reader = geoip2.database.Reader(COREDNS_GEOIP_DB_PATH)
            reader.close()
            print("INFO: GeoIP database integrity verified.")
        except Exception as e:
            print(f"WARN: GeoIP database verification failed: {e}. The file might be corrupted or in an unexpected format.")

        # 3. Clean up temporary files
        os.remove(TEMP_TAR_GZ)
        subprocess.run(["rm", "-rf", TEMP_EXTRACT_DIR], check=True)
        print(f"INFO: Cleaned up temporary files.")

        # 4. Apply CoreDNS config to reload with new DB
        apply_coredns_config()

        return {"message": "GeoIP database updated successfully and CoreDNS config reloaded."}
    except httpx.HTTPStatusError as e:
        print(f"ERROR: HTTP error during GeoIP DB download: {e.response.status_code} - {e.response.text}")
        raise HTTPException(status_code=e.response.status_code, detail=f"Failed to download GeoIP DB: {e.response.text.strip()}")
    except Exception as e:
        print(f"ERROR: An unexpected error occurred during GeoIP DB update: {e}")
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"An unexpected error occurred: {e}")

@app.post("/config/apply_changes/", status_code=status.HTTP_200_OK)
def apply_changes_endpoint():
    """Manually trigger CoreDNS configuration reload."""
    return apply_coredns_config()
EOF
echo -e "${GREEN}main.py file overwritten successfully.${NC}"

# --- 5. Trigger Database Table Creation and CoreDNS reload via API ---
echo -e "${GREEN}Activating new database tables and applying CoreDNS configuration...${NC}"
# Deactivate current venv (if active) to ensure clean run for Gunicorn
if command -v deactivate &> /dev/null; then
    deactivate
fi

# We need to restart the API service to pick up new code and environment variables
echo -e "${YELLOW}Restarting API service to apply code changes...${NC}"
systemctl restart dns_api
if [ $? -ne 0 ]; then
    echo -e "${RED}Error restarting API service. Please check the logs:${NC}"
    echo -e "${YELLOW}sudo journalctl -u dns_api --no-pager${NC}"
    exit 1
fi
echo -e "${GREEN}API service restarted successfully.${NC}"

echo -e "${YELLOW}Calling API to create database tables and apply initial CoreDNS config...${NC}"
# Give API a moment to start
sleep 10
# Call the API to create tables and apply initial CoreDNS config
# This will call models.Base.metadata.create_all and generate_coredns_config
# We use the internal API URL here
curl -X POST "$API_INTERNAL_URL/config/apply_changes/"
if [ $? -ne 0 ]; then
    echo -e "${RED}Error calling API for initial changes. Please check API status.${NC}"
    exit 1
fi
echo -e "${GREEN}Database tables created and initial CoreDNS config applied.${NC}"


# --- Final Steps ---
echo -e "${GREEN}--- Xray DNS Proxy Integration completed successfully! ---${NC}"
echo -e "${YELLOW}Xray DNS proxy is now running on port 1053.${NC}"
echo -e "${YELLOW}Your API Backend has new fields (use_xray_proxy) for Domain, GeoIPRule, and GeoSiteList models.${NC}"
echo -e "${YELLOW}Go to http://${YOUR_SERVER_IP}:${API_PORT}/docs to view the updated API endpoints and models.${NC}"
echo -e "${YELLOW}The next step is to update the Frontend UI to interact with these new capabilities.${NC}"
echo -e "${YELLOW}Good luck!${NC}"

# Deactivate virtual environment
deactivate
