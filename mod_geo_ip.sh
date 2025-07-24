#!/bin/bash

# ANSI escape codes for colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}--- CoreDNS Geo-IP/Geo-Site Mod Script ---${NC}"
echo -e "${YELLOW}This script adds Geo-IP/Geo-Site capabilities to your CoreDNS and API Backend.${NC}"
echo -e "${YELLOW}This process involves overwriting models.py, main.py, and Corefile.${NC}"
echo -e "${YELLOW}Please back up your files before proceeding.${NC}"
echo -e "${YELLOW}Tested on Debian/Ubuntu based systems.${NC}"

# --- Check for root privileges ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run with root privileges. Please use 'sudo bash mod_geo_ip.sh'.${NC}"
    exit 1
fi

# --- Get user inputs ---
read -p "Enter the IP address or hostname of your CoreDNS/API Backend server (e.g., 192.168.1.1 or yourdomain.com): " YOUR_SERVER_IP

read -p "Enter your MaxMind License Key (type NO to skip): " MAXMIND_LICENSE_KEY
if [[ "$MAXMIND_LICENSE_KEY" == "NO" || "$MAXMIND_LICENSE_KEY" == "no" ]]; then
    MAXMIND_LICENSE_KEY=""
    echo -e "${YELLOW}You chose to skip MaxMind License Key. GeoIP database update functionality will not work.${NC}"
else
    echo -e "${YELLOW}Please ensure your MaxMind License Key is valid.${NC}"
fi

read -p "What is your internal API Backend URL? (e.g., http://localhost:8000 or http://127.0.0.1:8000): " API_INTERNAL_URL
while [[ -z "$API_INTERNAL_URL" || ! "$API_INTERNAL_URL" =~ ^http(s)?://[a-zA-Z0-9\.-]+(:[0-9]+)?/?$ ]]; do
    echo -e "${RED}Error: Invalid internal API Backend URL. Please enter a valid URL.${NC}"
    read -p "Enter your internal API Backend URL: " API_INTERNAL_URL
done

# --- Define paths ---
API_DIR="/opt/dns_bypass_api"
COREDNS_CONFIG_DIR="/etc/coredns"
COREDNS_COREFILE="$COREDNS_CONFIG_DIR/Corefile"
API_ENV_FILE="$API_DIR/.env"
API_DATABASE_FILE="$API_DIR/database.py"
API_MODELS_FILE="$API_DIR/models.py"
API_MAIN_FILE="$API_DIR/main.py"
GEOIP_DB_PATH="$COREDNS_CONFIG_DIR/GeoLite2-City.mmdb"

# --- Backup existing files ---
echo -e "${GREEN}Backing up existing files...${NC}"
cp "$COREDNS_COREFILE" "$COREDNS_COREFILE.bak.$(date +%Y%m%d%H%M%S)"
cp "$API_ENV_FILE" "$API_ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
cp "$API_DATABASE_FILE" "$API_DATABASE_FILE.bak.$(date +%Y%m%d%H%M%S)"
cp "$API_MODELS_FILE" "$API_MODELS_FILE.bak.$(date +%Y%m%d%H%M%S)"
cp "$API_MAIN_FILE" "$API_MAIN_FILE.bak.$(date +%Y%m%d%H%M%S)"
echo -e "${GREEN}Backups created with .bak.TIMESTAMP extension.${NC}"

# --- 1. Install new Python dependencies for API Backend ---
echo -e "${GREEN}Installing new Python dependencies (httpx, geoip2)...${NC}"
cd "$API_DIR" || { echo -e "${RED}Error: API directory not found at $API_DIR. Exiting.${NC}"; exit 1; }
source venv/bin/activate
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Could not activate virtual environment. Make sure it exists.${NC}"
    exit 1
fi
pip install httpx geoip2
if [ $? -ne 0 ]; then
    echo -e "${RED}Error installing httpx and geoip2. Please check your internet connection.${NC}"
    deactivate
    exit 1
fi
echo -e "${GREEN}New Python dependencies installed successfully.${NC}"

# --- 2. Update .env file for API Backend ---
echo -e "${GREEN}Updating .env file...${NC}"
# Read existing DATABASE_URL
DB_URL_EXISTING=$(grep ^DATABASE_URL "$API_ENV_FILE.bak.$(ls -t "$API_ENV_FILE.bak."* | head -1 | cut -d'.' -f3-)" | cut -d'=' -f2-)

cat <<EOF > "$API_ENV_FILE"
DATABASE_URL=$DB_URL_EXISTING
COREDNS_CONFIG_PATH="/etc/coredns/Corefile"
COREDNS_RELOAD_COMMAND="sudo systemctl reload coredns"
MAXMIND_LICENSE_KEY="$MAXMIND_LICENSE_KEY"
COREDNS_GEOIP_DB_PATH="$GEOIP_DB_PATH"
EOF
echo -e "${GREEN}.env file updated successfully.${NC}"

# --- 3. Overwrite models.py with Geo-IP/Geo-Site models ---
echo -e "${GREEN}Overwriting models.py file...${NC}"
cat <<EOF > "$API_MODELS_FILE"
from sqlalchemy import Column, Integer, String, Boolean, Enum
from database import Base

class Domain(Base):
    __tablename__ = "domains"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, unique=True, index=True)
    bypass_ips = Column(String) # Comma-separated IPs

class GeoIPRule(Base):
    __tablename__ = "geoip_rules"
    id = Column(Integer, primary_key=True, index=True)
    country_code = Column(String, unique=True, index=True) # e.g., "IR", "US", "CN"
    # Action type, e.g., "forward_to_custom_dns", "block", "forward_to_default"
    action_type = Column(String, default="forward_to_custom_dns")
    # Specific bypass DNS servers for this country, if action_type is forward_to_custom_dns
    bypass_ips = Column(String, nullable=True)

class GeoSiteList(Base):
    __tablename__ = "geosite_lists"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, unique=True, index=True) # e.g., "Iranian_Sites", "US_Streaming"
    domains_list = Column(String) # Comma-separated domains or a reference to an external list
    bypass_ips = Column(String) # Specific DNS for these sites
EOF
echo -e "${GREEN}models.py file overwritten successfully.${NC}"

# --- 4. Overwrite main.py with Geo-IP/Geo-Site logic and endpoints ---
echo -e "${GREEN}Overwriting main.py file...${NC}"
cat <<EOF > "$API_MAIN_FILE"
import os
import subprocess
import tarfile
from typing import List, Optional
from fastapi import FastAPI, Depends, HTTPException, status
from sqlalchemy.orm import Session
from pydantic import BaseModel
from dotenv import load_dotenv
import httpx # For downloading GeoIP DB
import geoip2.database # For GeoIP DB verification (optional, but good for testing)

import models
from database import engine, get_db

# Load environment variables from .env file
load_dotenv()

# Create all tables in the database (if they don't exist)
models.Base.metadata.create_all(bind=engine)

app = FastAPI()

COREDNS_CONFIG_PATH = os.getenv("COREDNS_CONFIG_PATH")
COREDNS_RELOAD_COMMAND = os.getenv("COREDNS_RELOAD_COMMAND")
MAXMIND_LICENSE_KEY = os.getenv("MAXMIND_LICENSE_KEY")
COREDNS_GEOIP_DB_PATH = os.getenv("COREDNS_GEOIP_DB_PATH")

if not COREDNS_CONFIG_PATH or not COREDNS_RELOAD_COMMAND:
    raise ValueError("COREDNS_CONFIG_PATH or COREDNS_RELOAD_COMMAND is not set in .env")

# Pydantic models for request/response data validation
class DomainBase(BaseModel):
    name: str
    bypass_ips: str

class DomainCreate(DomainBase):
    pass

class Domain(DomainBase):
    id: int
    class Config:
        from_attributes = True

class GeoIPRuleBase(BaseModel):
    country_code: str
    action_type: str = "forward_to_custom_dns" # "forward_to_custom_dns", "block", "forward_to_default"
    bypass_ips: Optional[str] = None # Comma-separated IPs if action is custom_dns

class GeoIPRuleCreate(GeoIPRuleBase):
    pass

class GeoIPRule(GeoIPRuleBase):
    id: int
    class Config:
        from_attributes = True

class GeoSiteListBase(BaseModel):
    name: str
    domains_list: str # Comma-separated domains
    bypass_ips: str # Comma-separated IPs

class GeoSiteListCreate(GeoSiteListBase):
    pass

class GeoSiteList(GeoSiteListBase):
    id: int
    class Config:
        from_attributes = True

@app.on_event("startup")
async def startup_event():
    """
    Ensures the initial Corefile exists and contains base configuration.
    This is a fallback; the CoreDNS installation script should ideally create it.
    """
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
            # This error might prevent the API from starting correctly,
            # depending on permissions. Handle carefully.


def generate_coredns_config(db: Session) -> str:
    """Generates the CoreDNS configuration content based on database entries."""
    domains = db.query(models.Domain).all()
    geoip_rules = db.query(models.GeoIPRule).all()
    geosite_lists = db.query(models.GeoSiteList).all()

    config_parts = []

    # Base CoreDNS configuration including Prometheus and general forwarding
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

    # Add GeoIP Policy plugin if GeoIP DB path is set
    if COREDNS_GEOIP_DB_PATH and os.path.exists(COREDNS_GEOIP_DB_PATH):
        policy_block_lines = []
        policy_block_lines.append(f"    policy {{")
        policy_block_lines.append(f"        geoip {{ db {COREDNS_GEOIP_DB_PATH} }}")

        # Add rules based on geoip_rules from DB
        for rule in geoip_rules:
            if rule.action_type == "forward_to_custom_dns" and rule.bypass_ips:
                ips_formatted = rule.bypass_ips.replace(',', ' ')
                policy_block_lines.append(f"""
        if {{geoip country_code}} is "{rule.country_code}" {{
            forward . {ips_formatted} {{
                prefer_udp
                health_check 10s
            }}
        }}""")
            elif rule.action_type == "block":
                policy_block_lines.append(f"""
        if {{geoip country_code}} is "{rule.country_code}" {{
            fallthrough # or 'error' to block, 'refuse' etc. 'fallthrough' means continue to next rule.
        }}""")
            # "forward_to_default" is handled by the final else block

        # Default policy for countries not explicitly handled by a rule, or other actions
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

    # Add GeoSite specific forward zones
    for geosite in geosite_lists:
        domains_list_items = [d.strip() for d in geosite.domains_list.split(',') if d.strip()]
        ips_formatted = geosite.bypass_ips.replace(',', ' ')
        for domain_name in domains_list_items:
            config_parts.append(f"""
{domain_name} {{
    forward . {ips_formatted} {{
        prefer_udp
        health_check 10s
    }}
}}
""")

    # Add specific domain bypass rules (existing functionality)
    for domain in domains:
        ips_formatted = domain.bypass_ips.replace(',', ' ')
        config_parts.append(f"""
{domain.name} {{
    forward . {ips_formatted} {{
        prefer_udp
        health_check 10s
    }}
}}
""")

    return "\n".join(config_parts)

def apply_coredns_config():
    """Writes the new CoreDNS config and reloads the CoreDNS service."""
    try:
        # Obtain a new DB session for this operation
        db_session = next(get_db())
        new_config_content = generate_coredns_config(db_session)
        db_session.close()

        # Write the new config to the Corefile
        with open(COREDNS_CONFIG_PATH, "w") as f:
            f.write(new_config_content.strip())
        
        print(f"INFO: CoreDNS config updated at {COREDNS_CONFIG_PATH}")

        # Reload CoreDNS service
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
    db_domain = models.Domain(name=domain.name, bypass_ips=domain.bypass_ips)
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
    db_rule = models.GeoIPRule(country_code=rule.country_code, action_type=rule.action_type, bypass_ips=rule.bypass_ips)
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
    db_geosite = models.GeoSiteList(name=geosite.name, domains_list=geosite.domains_list, bypass_ips=geosite.bypass_ips)
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
            # Decide whether to raise an exception here or just warn

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
        print(f"ERROR: Failed to update GeoIP database: {e}")
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"An unexpected error occurred during GeoIP DB update: {e}")

@app.post("/config/apply_changes/", status_code=status.HTTP_200_OK)
def apply_changes_endpoint():
    """Manually trigger CoreDNS configuration reload."""
    return apply_coredns_config()

EOF
echo -e "${GREEN}main.py file overwritten successfully.${NC}"

# --- 5. Overwrite Corefile with Geo-IP policy block ---
echo -e "${GREEN}Overwriting CoreDNS Corefile...${NC}"
cat <<EOF > "$COREDNS_COREFILE"
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
    prometheus 0.0.0.0:${API_PORT} # Use the dynamically provided API_PORT for Prometheus

    # GeoIP Policy Plugin
    # This plugin needs MaxMind GeoLite2 City/Country database.
    # The 'db' path should point to your GeoLite2-City.mmdb file.
    # The policy block is dynamic and will be generated by the API.
    # CoreDNS will pick up changes to this section upon reload.
    policy {
        geoip {
            db $GEOIP_DB_PATH
            # This specifies where to get the client IP from.
            # If your CoreDNS is behind a proxy, you might need 'header X-Forwarded-For'
            # or 'client_ip_from_request' for actual client IP.
            # For direct client connections, 'client_ip_from_request' should be fine.
            # Use 'client_ip_from_request' if CoreDNS is directly exposed to clients.
            # If CoreDNS is behind a proxy (like Nginx, HAProxy), you might need:
            # client_ip_from_header X-Forwarded-For
        }
        # The actual rules (if/else blocks for country codes) will be dynamically generated
        # by the API Backend's generate_coredns_config function based on database rules.
        # This section will be populated during the 'apply_coredns_config' call from API.
        # Example structure (dynamically inserted):
        # if {geoip country_code} is "IR" {
        #     forward . 5.6.7.8 9.10.11.12 {
        #         prefer_udp
        #         health_check 10s
        #     }
        # } else {
        #     forward . 8.8.8.8 1.1.1.1 {
        #         prefer_udp
        #         health_check 10s
        #     }
        # }
    }
}

# Domains and GeoSite rules are generated dynamically by API and appended here or in included files.
# CoreDNS will be reloaded by the API to pick up these rules.
# Example:
# domain.com {
#     forward . 1.2.3.4 {
#         prefer_udp
#         health_check 10s
#     }
# }
EOF
echo -e "${GREEN}CoreDNS Corefile overwritten successfully.${NC}"

# --- 6. Trigger Database Table Creation and CoreDNS reload via API ---
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
echo -e "${GREEN}--- Geo-IP/Geo-Site mod process completed successfully! ---${NC}"
echo -e "${YELLOW}Your API Backend now has new endpoints for managing Geo-IP and Geo-Site rules.${NC}"
echo -e "${YELLOW}Go to http://${YOUR_SERVER_IP}:${API_PORT}/docs to view the new endpoints.${NC}"
echo -e "${YELLOW}If you entered a MaxMind License Key, you can use the /geoip/update_database/ endpoint to download the GeoIP database.${NC}"
echo -e "${YELLOW}The next step is to update the Frontend UI to interact with these new capabilities.${NC}"
echo -e "${YELLOW}Good luck!${NC}"

# Deactivate virtual environment
deactivate
