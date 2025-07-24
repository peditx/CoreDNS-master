#!/bin/bash

# ANSI escape codes for colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}--- Xray Config Management UI Integration Script ---${NC}"
echo -e "${YELLOW}This script adds Xray config management functionality to your API Backend and Frontend UI.${NC}"
echo -e "${YELLOW}It will overwrite main.py in your API and App.js in your React app.${NC}"
echo -e "${YELLOW}Please back up your files before proceeding.${NC}"
echo -e "${YELLOW}Tested on Debian/Ubuntu based systems.${NC}"

# --- Check for root privileges ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run with root privileges. Please use 'sudo bash update_xray_ui_integration.sh'.${NC}"
    exit 1
fi

# --- Define paths ---
API_DIR="/opt/dns_bypass_api"
FRONTEND_DIR="/opt/dns_bypass_frontend"
XRAY_CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_RESTART_COMMAND="sudo systemctl restart xray"

API_ENV_FILE="$API_DIR/.env"
API_MAIN_FILE="$API_DIR/main.py"
FRONTEND_APP_JS="$FRONTEND_DIR/src/App.js"

# --- Backup existing files ---
echo -e "${GREEN}Backing up existing files...${NC}"
cp "$API_ENV_FILE" "$API_ENV_FILE.bak_xray_ui.$(date +%Y%m%d%H%M%S)"
cp "$API_MAIN_FILE" "$API_MAIN_FILE.bak_xray_ui.$(date +%Y%m%d%H%M%S)"
cp "$FRONTEND_APP_JS" "$FRONTEND_APP_JS.bak_xray_ui.$(date +%Y%m%d%H%M%S)"
echo -e "${GREEN}Backups created with .bak_xray_ui.TIMESTAMP extension.${NC}"

# --- 1. Update .env file for API Backend ---
echo -e "${GREEN}Updating .env file for API Backend...${NC}"
# Append new variables if they don't exist, otherwise update them
if ! grep -q "^XRAY_CONFIG_FILE=" "$API_ENV_FILE"; then
    echo "XRAY_CONFIG_FILE=\"$XRAY_CONFIG_FILE\"" >> "$API_ENV_FILE"
else
    sed -i "s|^XRAY_CONFIG_FILE=.*|XRAY_CONFIG_FILE=\"$XRAY_CONFIG_FILE\"|" "$API_ENV_FILE"
fi

if ! grep -q "^XRAY_RESTART_COMMAND=" "$API_ENV_FILE"; then
    echo "XRAY_RESTART_COMMAND=\"$XRAY_RESTART_COMMAND\"" >> "$API_ENV_FILE"
else
    sed -i "s|^XRAY_RESTART_COMMAND=.*|XRAY_RESTART_COMMAND=\"$XRAY_RESTART_COMMAND\"|" "$API_ENV_FILE"
fi
echo -e "${GREEN}.env file updated successfully.${NC}"

# --- 2. Overwrite main.py with Xray config management logic and endpoints ---
echo -e "${GREEN}Overwriting API Backend main.py for Xray config management...${NC}"
# Use the content from the previous generation for main.py,
# and add the new Xray config management endpoints.
cat <<EOF > "$API_MAIN_FILE"
import os
import subprocess
import tarfile
from typing import List, Optional
from fastapi import FastAPI, Depends, HTTPException, status
from sqlalchemy.orm import Session
from pydantic import BaseModel, HttpUrl, root_validator
from dotenv import load_dotenv
import httpx
import geoip2.database
import json # Added for JSON validation

import models
from database import engine, get_db

load_dotenv()

models.Base.metadata.create_all(bind=engine)

app = FastAPI()

COREDNS_CONFIG_PATH = os.getenv("COREDNS_CONFIG_PATH")
COREDNS_RELOAD_COMMAND = os.getenv("COREDNS_RELOAD_COMMAND")
MAXMIND_LICENSE_KEY = os.getenv("MAXMIND_LICENSE_KEY")
COREDNS_GEOIP_DB_PATH = os.getenv("COREDNS_GEOIP_DB_PATH")
XRAY_CONFIG_FILE = os.getenv("XRAY_CONFIG_FILE")
XRAY_RESTART_COMMAND = os.getenv("XRAY_RESTART_COMMAND")

# New constant for Xray DNS proxy
XRAY_DNS_PROXY_ADDRESS = "127.0.0.1:1053"

if not COREDNS_CONFIG_PATH or not COREDNS_RELOAD_COMMAND or \\
   not XRAY_CONFIG_FILE or not XRAY_RESTART_COMMAND:
    raise ValueError("Missing essential environment variables in .env")

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

class XrayConfigInput(BaseModel):
    config_url: Optional[HttpUrl] = None
    config_json: Optional[str] = None

    @root_validator(pre=True)
    def check_either_url_or_json(cls, values):
        config_url, config_json = values.get('config_url'), values.get('config_json')
        if not (config_url or config_json):
            raise ValueError('Either config_url or config_json must be provided')
        if config_url and config_json:
            raise ValueError('Only one of config_url or config_json can be provided')
        return values

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
                target_ips = "8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1"

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
            error
        }}""")

        policy_block_lines.append("""
        else {
            forward . 8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 {
                prefer_udp
                health_check 10s
            }
        }""")
        policy_block_lines.append(f"    }}")
        config_parts.append("\n".join(policy_block_lines))

    config_parts.append("}")

    all_forward_rules = []

    for domain in domains:
        target_ips = ""
        if domain.use_xray_proxy:
            target_ips = XRAY_DNS_PROXY_ADDRESS
        elif domain.bypass_ips:
            target_ips = domain.bypass_ips.replace(',', ' ')
        else:
            target_ips = "8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1"

        all_forward_rules.append(f"""
{domain.name} {{
    forward . {target_ips} {{
        prefer_udp
        health_check 10s
    }}
}}
""")

    for geosite in geosite_lists:
        target_ips = ""
        if geosite.use_xray_proxy:
            target_ips = XRAY_DNS_PROXY_ADDRESS
        elif geosite.bypass_ips:
            target_ips = geosite.bypass_ips.replace(',', ' ')
        else:
            target_ips = "8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1"

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
        print(f"INFO: Downloading GeoIP database from MaxMind...")
        async with httpx.AsyncClient() as client:
            response = await client.get(GEOIP_DB_DOWNLOAD_URL, follow_redirects=True, timeout=30)
            response.raise_for_status()
            with open(TEMP_TAR_GZ, "wb") as f:
                f.write(response.content)
        print(f"INFO: Downloaded to {TEMP_TAR_GZ}")

        print(f"INFO: Extracting GeoIP database...")
        os.makedirs(TEMP_EXTRACT_DIR, exist_ok=True)
        with tarfile.open(TEMP_TAR_GZ, "r:gz") as tar:
            mmdb_member = [m for m in tar.getmembers() if m.name.endswith('.mmdb')]
            if not mmdb_member:
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="No .mmdb file found in the downloaded tarball.")
            
            tar.extract(mmdb_member[0], path=TEMP_EXTRACT_DIR)
            extracted_mmdb_path = os.path.join(TEMP_EXTRACT_DIR, mmdb_member[0].name)
            
            os.makedirs(os.path.dirname(COREDNS_GEOIP_DB_PATH), exist_ok=True)
            
            os.replace(extracted_mmdb_path, COREDNS_GEOIP_DB_PATH)
        print(f"INFO: GeoIP database moved to {COREDNS_GEOIP_DB_PATH}")

        try:
            reader = geoip2.database.Reader(COREDNS_GEOIP_DB_PATH)
            reader.close()
            print("INFO: GeoIP database integrity verified.")
        except Exception as e:
            print(f"WARN: GeoIP database verification failed: {e}. The file might be corrupted or in an unexpected format.")

        os.remove(TEMP_TAR_GZ)
        subprocess.run(["rm", "-rf", TEMP_EXTRACT_DIR], check=True)
        print(f"INFO: Cleaned up temporary files.")

        apply_coredns_config()

        return {"message": "GeoIP database updated successfully and CoreDNS config reloaded."}
    except httpx.HTTPStatusError as e:
        print(f"ERROR: HTTP error during GeoIP DB download: {e.response.status_code} - {e.response.text}")
        raise HTTPException(status_code=e.response.status_code, detail=f"Failed to download GeoIP DB: {e.response.text.strip()}")
    except Exception as e:
        print(f"ERROR: An unexpected error occurred during GeoIP DB update: {e}")
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"An unexpected error occurred: {e}")

# --- New API Endpoint for Xray Config Management ---
@app.post("/xray/config/", status_code=status.HTTP_200_OK)
async def update_xray_config_endpoint(config_input: XrayConfigInput):
    """
    Updates the Xray configuration file and restarts the Xray service.
    Accepts either a URL to a config.json or the JSON content directly.
    """
    try:
        config_content = ""
        if config_input.config_url:
            print(f"INFO: Downloading Xray config from URL: {config_input.config_url}")
            async with httpx.AsyncClient() as client:
                response = await client.get(str(config_input.config_url), timeout=30)
                response.raise_for_status()
                config_content = response.text
        elif config_input.config_json:
            print("INFO: Using provided Xray config JSON string.")
            config_content = config_input.config_json
        
        # Validate if it's valid JSON (optional but recommended)
        try:
            json.loads(config_content)
        except json.JSONDecodeError:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Provided config is not valid JSON.")

        with open(XRAY_CONFIG_FILE, "w") as f:
            f.write(config_content)
        print(f"INFO: Xray config updated at {XRAY_CONFIG_FILE}")

        result = subprocess.run(XRAY_RESTART_COMMAND.split(), capture_output=True, text=True, check=True)
        print(f"INFO: Xray restart successful: {result.stdout}")
        if result.stderr:
            print(f"WARN: Xray restart stderr: {result.stderr}")
        
        return {"message": "Xray configuration updated and service restarted successfully"}

    except subprocess.CalledProcessError as e:
        print(f"ERROR: Xray restart failed. Stderr: {e.stderr}. Stdout: {e.stdout}")
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"Failed to restart Xray: {e.stderr.strip()}")
    except httpx.HTTPStatusError as e:
        print(f"ERROR: HTTP error during Xray config download: {e.response.status_code} - {e.response.text}")
        raise HTTPException(status_code=e.response.status_code, detail=f"Failed to download Xray config from URL: {e.response.text.strip()}")
    except IOError as e:
        print(f"ERROR: Failed to write Xray config file: {e}")
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"Failed to write Xray config file: {e}")
    except Exception as e:
        print(f"ERROR: An unexpected error occurred during Xray config update: {e}")
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"An unexpected error occurred: {e}")

@app.get("/xray/config/", status_code=status.HTTP_200_OK)
async def get_xray_config_endpoint():
    """Reads the current Xray configuration file."""
    try:
        with open(XRAY_CONFIG_FILE, "r") as f:
            content = f.read()
        # Optionally, validate JSON before returning
        json.loads(content) # Check if it's valid JSON
        return {"config_json": content}
    except FileNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Xray config file not found.")
    except json.JSONDecodeError:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Xray config file contains invalid JSON.")
    except Exception as e:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"Failed to read Xray config file: {e}")


@app.post("/config/apply_changes/", status_code=status.HTTP_200_OK)
def apply_changes_endpoint():
    """Manually trigger CoreDNS configuration reload."""
    return apply_coredns_config()
EOF
echo -e "${GREEN}main.py updated successfully.${NC}"

# --- 3. Overwrite App.js with Xray config management UI ---
echo -e "${GREEN}Overwriting Frontend App.js for Xray config management UI...${NC}"
cat <<EOF > "$FRONTEND_APP_JS"
import React, { useState, useEffect } from 'react';
import './App.css';

const API_BASE_URL = process.env.REACT_APP_API_BASE_URL || 'http://localhost:8000';

function App() {
  const [domains, setDomains] = useState([]);
  const [newDomainName, setNewDomainName] = useState('');
  const [newBypassIps, setNewBypassIps] = useState('');
  const [useXrayProxy, setUseXrayProxy] = useState(false); // New state for Xray proxy
  const [editingDomain, setEditingDomain] = useState(null);

  const [geoipRules, setGeoipRules] = useState([]);
  const [newCountryCode, setNewCountryCode] = useState('');
  const [newGeoipAction, setNewGeoipAction] = useState('forward_to_custom_dns');
  const [newGeoipBypassIps, setNewGeoipBypassIps] = useState('');
  const [useGeoipXrayProxy, setUseGeoipXrayProxy] = useState(false);
  const [editingGeoipRule, setEditingGeoipRule] = useState(null);

  const [geositeLists, setGeositeLists] = useState([]);
  const [newGeositeName, setNewGeositeName] = useState('');
  const [newGeositeDomains, setNewGeositeDomains] = useState('');
  const [newGeositeBypassIps, setNewGeositeBypassIps] = useState('');
  const [useGeositeXrayProxy, setUseGeositeXrayProxy] = useState(false);
  const [editingGeositeList, setEditingGeositeList] = useState(null);

  const [xrayConfigUrl, setXrayConfigUrl] = useState('');
  const [xrayConfigJson, setXrayConfigJson] = useState('');
  const [currentXrayConfig, setCurrentXrayConfig] = useState('');

  const [message, setMessage] = useState('');
  const [messageType, setMessageType] = useState(''); // 'success' or 'error'

  useEffect(() => {
    fetchDomains();
    fetchGeoipRules();
    fetchGeositeLists();
    fetchCurrentXrayConfig();
  }, []);

  const showMessage = (msg, type) => {
    setMessage(msg);
    setMessageType(type);
    setTimeout(() => {
      setMessage('');
      setMessageType('');
    }, 3000);
  };

  // --- Domain Management ---
  const fetchDomains = async () => {
    try {
      const response = await fetch(\`\${API_BASE_URL}/domains/\`);
      if (!response.ok) throw new Error(\`HTTP error! status: \${response.status}\`);
      setDomains(await response.json());
    } catch (error) {
      console.error("Error fetching domains:", error);
      showMessage(\`Error fetching domains: \${error.message}\`, 'error');
    }
  };

  const handleCreateOrUpdateDomain = async (e) => {
    e.preventDefault();
    const domainData = { name: newDomainName, bypass_ips: newBypassIps, use_xray_proxy: useXrayProxy };
    try {
      const response = await fetch(
        editingDomain ? \`\${API_BASE_URL}/domains/\${editingDomain.id}\` : \`\${API_BASE_URL}/domains/\`,
        {
          method: editingDomain ? 'PUT' : 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(domainData),
        }
      );
      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.detail || \`HTTP error! status: \${response.status}\`);
      }
      showMessage(\`Domain \${editingDomain ? 'updated' : 'added'} successfully!\`, 'success');
      resetDomainForm();
      fetchDomains();
    } catch (error) {
      console.error("Error creating/updating domain:", error);
      showMessage(\`Error: \${error.message}\`, 'error');
    }
  };

  const handleDeleteDomain = async (id) => {
    if (!window.confirm("Are you sure you want to delete this domain?")) return;
    try {
      const response = await fetch(\`\${API_BASE_URL}/domains/\${id}\`, { method: 'DELETE' });
      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.detail || \`HTTP error! status: \${response.status}\`);
      }
      showMessage('Domain deleted successfully!', 'success');
      fetchDomains();
    } catch (error) {
      console.error("Error deleting domain:", error);
      showMessage(\`Error: \${error.message}\`, 'error');
    }
  };

  const handleEditDomainClick = (domain) => {
    setEditingDomain(domain);
    setNewDomainName(domain.name);
    setNewBypassIps(domain.bypass_ips);
    setUseXrayProxy(domain.use_xray_proxy);
  };

  const resetDomainForm = () => {
    setEditingDomain(null);
    setNewDomainName('');
    setNewBypassIps('');
    setUseXrayProxy(false);
  };

  // --- GeoIP Rule Management ---
  const fetchGeoipRules = async () => {
    try {
      const response = await fetch(\`\${API_BASE_URL}/geoip_rules/\`);
      if (!response.ok) throw new Error(\`HTTP error! status: \${response.status}\`);
      setGeoipRules(await response.json());
    } catch (error) {
      console.error("Error fetching GeoIP rules:", error);
      showMessage(\`Error fetching GeoIP rules: \${error.message}\`, 'error');
    }
  };

  const handleCreateOrUpdateGeoipRule = async (e) => {
    e.preventDefault();
    const ruleData = {
      country_code: newCountryCode,
      action_type: newGeoipAction,
      bypass_ips: newGeoipBypassIps,
      use_xray_proxy: useGeoipXrayProxy
    };
    try {
      const response = await fetch(
        editingGeoipRule ? \`\${API_BASE_URL}/geoip_rules/\${editingGeoipRule.id}\` : \`\${API_BASE_URL}/geoip_rules/\`,
        {
          method: editingGeoipRule ? 'PUT' : 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(ruleData),
        }
      );
      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.detail || \`HTTP error! status: \${response.status}\`);
      }
      showMessage(\`GeoIP Rule \${editingGeoipRule ? 'updated' : 'added'} successfully!\`, 'success');
      resetGeoipRuleForm();
      fetchGeoipRules();
    } catch (error) {
      console.error("Error creating/updating GeoIP rule:", error);
      showMessage(\`Error: \${error.message}\`, 'error');
    }
  };

  const handleDeleteGeoipRule = async (id) => {
    if (!window.confirm("Are you sure you want to delete this GeoIP rule?")) return;
    try {
      const response = await fetch(\`\${API_BASE_URL}/geoip_rules/\${id}\`, { method: 'DELETE' });
      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.detail || \`HTTP error! status: \${response.status}\`);
      }
      showMessage('GeoIP Rule deleted successfully!', 'success');
      fetchGeoipRules();
    } catch (error) {
      console.error("Error deleting GeoIP rule:", error);
      showMessage(\`Error: \${error.message}\`, 'error');
    }
  };

  const handleEditGeoipRuleClick = (rule) => {
    setEditingGeoipRule(rule);
    setNewCountryCode(rule.country_code);
    setNewGeoipAction(rule.action_type);
    setNewGeoipBypassIps(rule.bypass_ips || '');
    setUseGeoipXrayProxy(rule.use_xray_proxy);
  };

  const resetGeoipRuleForm = () => {
    setEditingGeoipRule(null);
    setNewCountryCode('');
    setNewGeoipAction('forward_to_custom_dns');
    setNewGeoipBypassIps('');
    setUseGeoipXrayProxy(false);
  };

  const handleUpdateGeoipDatabase = async () => {
    if (!window.confirm("This will download the latest GeoIP database. Continue?")) return;
    try {
      const response = await fetch(\`\${API_BASE_URL}/geoip/update_database/\`, { method: 'POST' });
      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.detail || \`HTTP error! status: \${response.status}\`);
      }
      showMessage('GeoIP database updated successfully!', 'success');
    } catch (error) {
      console.error("Error updating GeoIP database:", error);
      showMessage(\`Error updating GeoIP database: \${error.message}\`, 'error');
    }
  };

  // --- GeoSite List Management ---
  const fetchGeositeLists = async () => {
    try {
      const response = await fetch(\`\${API_BASE_URL}/geosite_lists/\`);
      if (!response.ok) throw new Error(\`HTTP error! status: \${response.status}\`);
      setGeositeLists(await response.json());
    } catch (error) {
      console.error("Error fetching GeoSite lists:", error);
      showMessage(\`Error fetching GeoSite lists: \${error.message}\`, 'error');
    }
  };

  const handleCreateOrUpdateGeositeList = async (e) => {
    e.preventDefault();
    const geositeData = {
      name: newGeositeName,
      domains_list: newGeositeDomains,
      bypass_ips: newGeositeBypassIps,
      use_xray_proxy: useGeositeXrayProxy
    };
    try {
      const response = await fetch(
        editingGeositeList ? \`\${API_BASE_URL}/geosite_lists/\${editingGeositeList.id}\` : \`\${API_BASE_URL}/geosite_lists/\`,
        {
          method: editingGeositeList ? 'PUT' : 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(geositeData),
        }
      );
      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.detail || \`HTTP error! status: \${response.status}\`);
      }
      showMessage(\`GeoSite List \${editingGeositeList ? 'updated' : 'added'} successfully!\`, 'success');
      resetGeositeListForm();
      fetchGeositeLists();
    } catch (error) {
      console.error("Error creating/updating GeoSite list:", error);
      showMessage(\`Error: \${error.message}\`, 'error');
    }
  };

  const handleDeleteGeositeList = async (id) => {
    if (!window.confirm("Are you sure you want to delete this GeoSite list?")) return;
    try {
      const response = await fetch(\`\${API_BASE_URL}/geosite_lists/\${id}\`, { method: 'DELETE' });
      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.detail || \`HTTP error! status: \${response.status}\`);
      }
      showMessage('GeoSite List deleted successfully!', 'success');
      fetchGeositeLists();
    } catch (error) {
      console.error("Error deleting GeoSite list:", error);
      showMessage(\`Error: \${error.message}\`, 'error');
    }
  };

  const handleEditGeositeListClick = (geosite) => {
    setEditingGeositeList(geosite);
    setNewGeositeName(geosite.name);
    setNewGeositeDomains(geosite.domains_list);
    setNewGeositeBypassIps(geosite.bypass_ips || '');
    setUseGeositeXrayProxy(geosite.use_xray_proxy);
  };

  const resetGeositeListForm = () => {
    setEditingGeositeList(null);
    setNewGeositeName('');
    setNewGeositeDomains('');
    setNewGeositeBypassIps('');
    setUseGeositeXrayProxy(false);
  };

  // --- Global Apply Changes ---
  const handleApplyCoreDnsChanges = async () => {
    try {
      const response = await fetch(\`\${API_BASE_URL}/config/apply_changes/\`, { method: 'POST' });
      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.detail || \`HTTP error! status: \${response.status}\`);
      }
      showMessage('CoreDNS configuration reloaded successfully!', 'success');
    } catch (error) {
      console.error("Error applying CoreDNS changes:", error);
      showMessage(\`Error applying CoreDNS changes: \${error.message}\`, 'error');
    }
  };

  // --- Xray Config Management ---
  const fetchCurrentXrayConfig = async () => {
    try {
      const response = await fetch(\`\${API_BASE_URL}/xray/config/\`);
      if (!response.ok) {
        if (response.status === 404) {
          setCurrentXrayConfig('No Xray config found. Please upload or paste one.');
        } else {
          throw new Error(\`HTTP error! status: \${response.status}\`);
        }
      } else {
        const data = await response.json();
        setCurrentXrayConfig(JSON.stringify(JSON.parse(data.config_json), null, 2)); // Pretty print
      }
    } catch (error) {
      console.error("Error fetching current Xray config:", error);
      showMessage(\`Error fetching Xray config: \${error.message}\`, 'error');
      setCurrentXrayConfig('Failed to load current Xray config.');
    }
  };

  const handleUpdateXrayConfig = async (e) => {
    e.preventDefault();
    const configData = {};
    if (xrayConfigUrl) {
      configData.config_url = xrayConfigUrl;
    } else if (xrayConfigJson) {
      try {
        JSON.parse(xrayConfigJson); // Basic validation
        configData.config_json = xrayConfigJson;
      } catch (err) {
        showMessage('Error: Invalid JSON provided.', 'error');
        return;
      }
    } else {
      showMessage('Error: Please provide either a URL or JSON content for Xray config.', 'error');
      return;
    }

    try {
      const response = await fetch(\`\${API_BASE_URL}/xray/config/\`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(configData),
      });
      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.detail || \`HTTP error! status: \${response.status}\`);
      }
      showMessage('Xray configuration updated and service restarted successfully!', 'success');
      setXrayConfigUrl('');
      setXrayConfigJson('');
      fetchCurrentXrayConfig(); // Fetch updated config
    } catch (error) {
      console.error("Error updating Xray config:", error);
      showMessage(\`Error updating Xray config: \${error.message}\`, 'error');
    }
  };

  return (
    <div className="App">
      <header className="App-header">
        <h1>CoreDNS Bypass Manager</h1>
        <div className="header-buttons">
          <button onClick={handleApplyCoreDnsChanges} className="apply-changes-button">Apply CoreDNS Changes</button>
          <button onClick={handleUpdateGeoipDatabase} className="apply-changes-button">Update GeoIP DB</button>
        </div>
      </header>

      {message && (
        <div className={\`message \${messageType}\`}>
          {message}
        </div>
      )}

      {/* Xray Configuration Management */}
      <div className="form-container">
        <h2>Xray Configuration</h2>
        <form onSubmit={handleUpdateXrayConfig}>
          <div className="form-group">
            <label htmlFor="xrayConfigUrl">Xray Config URL (optional):</label>
            <input
              type="url"
              id="xrayConfigUrl"
              value={xrayConfigUrl}
              onChange={(e) => { setXrayConfigUrl(e.target.value); setXrayConfigJson(''); }}
              placeholder="e.g., https://yourdomain.com/config.json"
            />
          </div>
          <div className="form-group">
            <label htmlFor="xrayConfigJson">Or Paste Xray Config JSON:</label>
            <textarea
              id="xrayConfigJson"
              rows="10"
              value={xrayConfigJson}
              onChange={(e) => { setXrayConfigJson(e.target.value); setXrayConfigUrl(''); }}
              placeholder="{...your Xray JSON config...}"
            ></textarea>
          </div>
          <button type="submit" className="submit-button">Apply Xray Config</button>
        </form>
        <div className="current-xray-config">
          <h3>Current Xray Config:</h3>
          <pre>{currentXrayConfig}</pre>
        </div>
      </div>

      {/* Domain Management */}
      <div className="form-container">
        <h2>{editingDomain ? 'Edit Domain' : 'Add New Domain'}</h2>
        <form onSubmit={handleCreateOrUpdateDomain}>
          <div className="form-group">
            <label htmlFor="domainName">Domain Name:</label>
            <input
              type="text"
              id="domainName"
              value={newDomainName}
              onChange={(e) => setNewDomainName(e.target.value)}
              placeholder="e.g., example.com"
              required
            />
          </div>
          <div className="form-group">
            <label htmlFor="bypassIps">Bypass IPs (comma-separated):</label>
            <input
              type="text"
              id="bypassIps"
              value={newBypassIps}
              onChange={(e) => setNewBypassIps(e.target.value)}
              placeholder="e.g., 1.2.3.4,5.6.7.8"
            />
          </div>
          <div className="form-group checkbox-group">
            <input
              type="checkbox"
              id="useXrayProxy"
              checked={useXrayProxy}
              onChange={(e) => setUseXrayProxy(e.target.checked)}
            />
            <label htmlFor="useXrayProxy">Use Xray Proxy for this domain</label>
          </div>
          <button type="submit" className="submit-button">
            {editingDomain ? 'Update Domain' : 'Add Domain'}
          </button>
          {editingDomain && (
            <button type="button" onClick={resetDomainForm} className="cancel-button">
              Cancel Edit
            </button>
          )}
        </form>
      </div>

      <div className="domain-list-container">
        <h2>Managed Domains</h2>
        {domains.length === 0 ? (
          <p>No domains added yet.</p>
        ) : (
          <ul className="domain-list">
            {domains.map((domain) => (
              <li key={domain.id} className="domain-item">
                <span className="domain-name">{domain.name}</span>
                <span className="domain-ips">
                  {domain.use_xray_proxy ? 'Via Xray Proxy' : (domain.bypass_ips || 'Default Upstream')}
                </span>
                <div className="domain-actions">
                  <button onClick={() => handleEditDomainClick(domain)} className="edit-button">Edit</button>
                  <button onClick={() => handleDeleteDomain(domain.id)} className="delete-button">Delete</button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>

      {/* GeoIP Rule Management */}
      <div className="form-container">
        <h2>{editingGeoipRule ? 'Edit GeoIP Rule' : 'Add New GeoIP Rule'}</h2>
        <form onSubmit={handleCreateOrUpdateGeoipRule}>
          <div className="form-group">
            <label htmlFor="countryCode">Country Code (e.g., US, IR):</label>
            <input
              type="text"
              id="countryCode"
              value={newCountryCode}
              onChange={(e) => setNewCountryCode(e.target.value.toUpperCase())}
              placeholder="e.g., US"
              maxLength="2"
              required
            />
          </div>
          <div className="form-group">
            <label htmlFor="geoipAction">Action:</label>
            <select id="geoipAction" value={newGeoipAction} onChange={(e) => setNewGeoipAction(e.target.value)} required>
              <option value="forward_to_custom_dns">Forward to Custom DNS / Xray</option>
              <option value="forward_to_default">Forward to Default Upstream</option>
              <option value="block">Block (Error Response)</option>
            </select>
          </div>
          {newGeoipAction === 'forward_to_custom_dns' && (
            <>
              <div className="form-group">
                <label htmlFor="geoipBypassIps">Bypass IPs (comma-separated, optional):</label>
                <input
                  type="text"
                  id="geoipBypassIps"
                  value={newGeoipBypassIps}
                  onChange={(e) => setNewGeoipBypassIps(e.target.value)}
                  placeholder="e.g., 1.2.3.4,5.6.7.8"
                />
              </div>
              <div className="form-group checkbox-group">
                <input
                  type="checkbox"
                  id="useGeoipXrayProxy"
                  checked={useGeoipXrayProxy}
                  onChange={(e) => setUseGeoipXrayProxy(e.target.checked)}
                />
                <label htmlFor="useGeoipXrayProxy">Use Xray Proxy for this country</label>
              </div>
            </>
          )}
          <button type="submit" className="submit-button">
            {editingGeoipRule ? 'Update Rule' : 'Add Rule'}
          </button>
          {editingGeoipRule && (
            <button type="button" onClick={resetGeoipRuleForm} className="cancel-button">
              Cancel Edit
            </button>
          )}
        </form>
      </div>

      <div className="domain-list-container">
        <h2>Managed GeoIP Rules</h2>
        {geoipRules.length === 0 ? (
          <p>No GeoIP rules added yet.</p>
        ) : (
          <ul className="domain-list">
            {geoipRules.map((rule) => (
              <li key={rule.id} className="domain-item">
                <span className="domain-name">Country: {rule.country_code}</span>
                <span className="domain-ips">
                  Action: {rule.action_type === 'forward_to_custom_dns' ?
                    (rule.use_xray_proxy ? 'Forward via Xray' : (rule.bypass_ips || 'Custom DNS')) :
                    rule.action_type
                  }
                </span>
                <div className="domain-actions">
                  <button onClick={() => handleEditGeoipRuleClick(rule)} className="edit-button">Edit</button>
                  <button onClick={() => handleDeleteGeoipRule(rule.id)} className="delete-button">Delete</button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>

      {/* GeoSite List Management */}
      <div className="form-container">
        <h2>{editingGeositeList ? 'Edit GeoSite List' : 'Add New GeoSite List'}</h2>
        <form onSubmit={handleCreateOrUpdateGeositeList}>
          <div className="form-group">
            <label htmlFor="geositeName">List Name:</label>
            <input
              type="text"
              id="geositeName"
              value={newGeositeName}
              onChange={(e) => setNewGeositeName(e.target.value)}
              placeholder="e.g., Iranian_Sites"
              required
            />
          </div>
          <div className="form-group">
            <label htmlFor="geositeDomains">Domains (comma-separated):</label>
            <textarea
              id="geositeDomains"
              rows="3"
              value={newGeositeDomains}
              onChange={(e) => setNewGeositeDomains(e.target.value)}
              placeholder="e.g., example.ir, another.ir"
              required
            ></textarea>
          </div>
          <div className="form-group">
            <label htmlFor="geositeBypassIps">Bypass IPs (comma-separated, optional):</label>
            <input
              type="text"
              id="geositeBypassIps"
              value={newGeositeBypassIps}
              onChange={(e) => setNewGeositeBypassIps(e.target.value)}
              placeholder="e.g., 1.2.3.4,5.6.7.8"
            />
          </div>
          <div className="form-group checkbox-group">
            <input
              type="checkbox"
              id="useGeositeXrayProxy"
              checked={useGeositeXrayProxy}
              onChange={(e) => setUseGeositeXrayProxy(e.target.checked)}
            />
            <label htmlFor="useGeositeXrayProxy">Use Xray Proxy for this list</label>
          </div>
          <button type="submit" className="submit-button">
            {editingGeositeList ? 'Update List' : 'Add List'}
          </button>
          {editingGeositeList && (
            <button type="button" onClick={resetGeositeListForm} className="cancel-button">
              Cancel Edit
            </button>
          )}
        </form>
      </div>

      <div className="domain-list-container">
        <h2>Managed GeoSite Lists</h2>
        {geositeLists.length === 0 ? (
          <p>No GeoSite lists added yet.</p>
        ) : (
          <ul className="domain-list">
            {geositeLists.map((geosite) => (
              <li key={geosite.id} className="domain-item">
                <span className="domain-name">List: {geosite.name}</span>
                <span className="domain-ips">
                  {geosite.use_xray_proxy ? 'Via Xray Proxy' : (geosite.bypass_ips || 'Custom DNS')}
                  <br/>
                  Domains: {geosite.domains_list}
                </span>
                <div className="domain-actions">
                  <button onClick={() => handleEditGeositeListClick(geosite)} className="edit-button">Edit</button>
                  <button onClick={() => handleDeleteGeositeList(geosite.id)} className="delete-button">Delete</button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}

export default App;
EOF
echo -e "${GREEN}App.js updated successfully.${NC}"

# --- 4. Build React App for Production ---
echo -e "${GREEN}Building React application for production...${NC}"
cd "$FRONTEND_DIR"
npm run build
if [ $? -ne 0 ]; then
    echo -e "${RED}Error building React application. Please check npm build logs.${NC}"
    exit 1
fi
echo -e "${GREEN}React application built successfully. Static files are in '$FRONTEND_DIR/build'.${NC}"

# --- 5. Restart Nginx to serve new React build ---
echo -e "${GREEN}Restarting Nginx to serve new React build...${NC}"
systemctl restart nginx
if [ $? -ne 0 ]; then
    echo -e "${RED}Error restarting Nginx service. Please check Nginx logs.${NC}"
    exit 1
fi
echo -e "${GREEN}Nginx restarted successfully.${NC}"

# --- Final Steps ---
echo -e "${GREEN}--- Xray Config Management UI Integration completed successfully! ---${NC}"
echo -e "${YELLOW}Your Frontend UI is now updated to manage Xray configuration, GeoIP rules, and GeoSite lists.${NC}"
echo -e "${YELLOW}Go to your UI URL (e.g., http://your_server_ip:80) to access the new features.${NC}"
echo -e "${YELLOW}Remember to configure API user permissions for Xray config file and restart command if you haven't already:${NC}"
echo -e "${YELLOW}  - sudo adduser --system --no-create-home --group api_user (if not exists)${NC}"
echo -e "${YELLOW}  - sudo chown -R api_user:api_user /usr/local/etc/xray${NC}"
echo -e "${YELLOW}  - sudo visudo -f /etc/sudoers.d/dns_api_xray_reloader (add: 'api_user ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart xray')${NC}"
echo -e "${YELLOW}Good luck!${NC}"
