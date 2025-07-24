#!/bin/bash

# ANSI escape codes for colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}--- API Backend Installation Script (FastAPI + PostgreSQL) ---${NC}"
echo -e "${YELLOW}This script installs and configures the API Backend for CoreDNS management.${NC}"
echo -e "${YELLOW}It assumes CoreDNS is already installed and active.${NC}"
echo -e "${YELLOW}Tested on Debian/Ubuntu based systems.${NC}"

# --- Check for root privileges ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run with root privileges. Please use 'sudo bash install_api_backend.sh'.${NC}"
    exit 1
fi

# --- Get user inputs ---
read -p "Enter PostgreSQL database username (default: dns_api_user): " DB_USER
DB_USER=${DB_USER:-dns_api_user}

read -p "Enter PostgreSQL database password for user $DB_USER: " DB_PASSWORD
while [ -z "$DB_PASSWORD" ]; do
    echo -e "${RED}Error: Password cannot be empty.${NC}"
    read -p "Please enter the database password: " DB_PASSWORD
done

read -p "Enter PostgreSQL database name (default: dns_bypass_db): " DB_NAME
DB_NAME=${DB_NAME:-dns_bypass_db}

read -p "Enter API port (default: 8000): " API_PORT
API_PORT=${API_PORT:-8000}

read -p "Do you want to configure UFW (firewall) for the API port? (y/n): " CONFIGURE_UFW_API

# --- 1. Install Python and Pip ---
echo -e "${GREEN}Installing Python3, pip, and python3-venv...${NC}"
apt update && apt install python3 python3-pip python3-venv -y
if [ $? -ne 0 ]; then
    echo -e "${RED}Error installing Python and required tools. Please check for issues.${NC}"
    exit 1
fi
echo -e "${GREEN}Python and its tools installed successfully.${NC}"

# --- 2. Install PostgreSQL ---
echo -e "${GREEN}Installing PostgreSQL...${NC}"
apt install postgresql postgresql-contrib -y
if [ $? -ne 0 ]; then
    echo -e "${RED}Error installing PostgreSQL. Please check for issues.${NC}"
    exit 1
fi
echo -e "${GREEN}PostgreSQL installed successfully.${NC}"

# --- 3. Configure PostgreSQL User and Database ---
echo -e "${GREEN}Configuring PostgreSQL user and database...${NC}"
# Create database user
sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"
if [ $? -ne 0 ]; then
    echo -e "${RED}Error creating database user. User '$DB_USER' might already exist.${NC}"
fi
# Create database and assign owner
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
if [ $? -ne 0 ]; then
    echo -e "${RED}Error creating database. Database '$DB_NAME' might already exist.${NC}"
fi

echo -e "${GREEN}PostgreSQL user and database configured successfully.${NC}"

# --- 4. Create Project Directory and Virtual Environment ---
echo -e "${GREEN}Creating project directory and virtual environment...${NC}"
API_DIR="/opt/dns_bypass_api" # Recommended path for application
mkdir -p "$API_DIR"
cd "$API_DIR"

python3 -m venv venv
source venv/bin/activate
echo -e "${GREEN}Project directory and virtual environment created successfully.${NC}"

# --- 5. Install Python Dependencies ---
echo -e "${GREEN}Installing Python dependencies...${NC}"
pip install fastapi uvicorn sqlalchemy psycopg2-binary python-dotenv gunicorn python-daemonize
if [ $? -ne 0 ]; then
    echo -e "${RED}Error installing Python dependencies. Please check your internet connection.${NC}"
    deactivate
    exit 1
fi
echo -e "${GREEN}Python dependencies installed successfully.${NC}"

# --- 6. Create API Backend Files ---
echo -e "${GREEN}Creating API Backend files...${NC}"

# Create .env file
cat <<EOF > "$API_DIR/.env"
DATABASE_URL="postgresql://$DB_USER:$DB_PASSWORD@localhost/$DB_NAME"
COREDNS_CONFIG_PATH="/etc/coredns/Corefile"
COREDNS_RELOAD_COMMAND="sudo systemctl reload coredns"
EOF
echo -e "${YELLOW}.env file created.${NC}"

# Create database.py
cat <<EOF > "$API_DIR/database.py"
import os
from sqlalchemy import create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
from dotenv import load_dotenv

load_dotenv() # Load environment variables from .env file

DATABASE_URL = os.getenv("DATABASE_URL")

if not DATABASE_URL:
    raise ValueError("DATABASE_URL is not set in the .env file")

engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

def get_db():
    """Dependency to get a database session for FastAPI endpoints."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
EOF
echo -e "${YELLOW}database.py file created.${NC}"

# Create models.py
cat <<EOF > "$API_DIR/models.py"
from sqlalchemy import Column, Integer, String
from database import Base

class Domain(Base):
    __tablename__ = "domains"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, unique=True, index=True)
    bypass_ips = Column(String) # Comma-separated IPs, e.g., "5.6.7.8,9.10.11.12"
EOF
echo -e "${YELLOW}models.py file created.${NC}"

# Create main.py
cat <<EOF > "$API_DIR/main.py"
import os
import subprocess
from typing import List
from fastapi import FastAPI, Depends, HTTPException, status
from sqlalchemy.orm import Session
from pydantic import BaseModel
from dotenv import load_dotenv

import models
from database import engine, get_db

# Load environment variables from .env file
load_dotenv()

# Create all tables in the database (if they don't exist)
models.Base.metadata.create_all(bind=engine)

app = FastAPI()

COREDNS_CONFIG_PATH = os.getenv("COREDNS_CONFIG_PATH")
COREDNS_RELOAD_COMMAND = os.getenv("COREDNS_RELOAD_COMMAND")

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
        from_attributes = True # FastAPI's new way to handle ORM models

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
    config_parts = [
        """
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
}
"""
    ]

    for domain in domains:
        # Replace commas with spaces for CoreDNS forward plugin
        ips_formatted = domain.bypass_ips.replace(',', ' ')
        domain_config = f"""
{domain.name} {{
    forward . {ips_formatted} {{
        prefer_udp
        health_check 10s
    }}
}}
"""
        config_parts.append(domain_config)
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
        # Assumes the user running this API has sudo NOPASSWD access for this command.
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

# --- API Endpoints ---

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
    apply_coredns_config() # Apply changes to CoreDNS
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
    apply_coredns_config() # Apply changes to CoreDNS
    return db_domain

@app.delete("/domains/{domain_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_domain(domain_id: int, db: Session = Depends(get_db)):
    """Delete a domain from the bypass list."""
    db_domain = db.query(models.Domain).filter(models.Domain.id == domain_id).first()
    if db_domain is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Domain not found")
    db.delete(db_domain)
    db.commit()
    apply_coredns_config() # Apply changes to CoreDNS
    return {"message": "Domain deleted successfully"}

@app.post("/config/apply_changes/", status_code=status.HTTP_200_OK)
def apply_changes_endpoint():
    """Manually trigger CoreDNS configuration reload."""
    return apply_coredns_config()
EOF
echo -e "${YELLOW}main.py file created.${NC}"
echo -e "${GREEN}API Backend files created successfully.${NC}"


# --- 7. Create API System User and Configure Permissions ---
echo -e "${GREEN}Creating system user for API and configuring permissions...${NC}"
API_USER="api_user" # Dedicated user for API service
sudo adduser --system --no-create-home --group "$API_USER" || true
sudo chown -R "$API_USER":"$API_USER" "$API_DIR"
echo -e "${YELLOW}User '$API_USER' created and project directory ownership set.${NC}"

# Configure sudoers for CoreDNS reload command
echo -e "${YELLOW}Configuring sudoers for API user...${NC}"
SUDOERS_FILE="/etc/sudoers.d/dns_api_reloader"
echo "$API_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload coredns" | sudo tee "$SUDOERS_FILE" > /dev/null
sudo chmod 0440 "$SUDOERS_FILE" # Set secure permissions for sudoers file
echo -e "${YELLOW}Sudoers configured successfully.${NC}"

# Grant API user write access to CoreDNS config directory
echo -e "${YELLOW}Configuring write permissions for CoreDNS config directory...${NC}"
# Install ACL if not present
if ! command -v setfacl &> /dev/null; then
    echo -e "${YELLOW}ACL (setfacl) not found. Installing...${NC}"
    apt install acl -y
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error installing ACL. Please install manually.${NC}"
    fi
fi
setfacl -m u:"$API_USER":rwx /etc/coredns
if [ $? -ne 0 ]; then
    echo -e "${RED}Error setting write permissions for CoreDNS config directory. Please check manually.${NC}"
    echo -e "${YELLOW}sudo setfacl -m u:${API_USER}:rwx /etc/coredns${NC}"
fi
echo -e "${GREEN}Permissions configured successfully.${NC}"


# --- 8. Create Systemd Service for API ---
echo -e "${GREEN}Creating Systemd service file for API...${NC}"
cat <<EOF > /etc/systemd/system/dns_api.service
[Unit]
Description=DNS Bypass API
After=network.target postgresql.service

[Service]
User=$API_USER
Group=$API_USER
WorkingDirectory=$API_DIR
ExecStart=$API_DIR/venv/bin/gunicorn main:app --workers 4 --bind 0.0.0.0:$API_PORT
Restart=on-failure
LimitNOFILE=1048576
LimitNPROC=512

[Install]
WantedBy=multi-user.target
EOF
echo -e "${GREEN}Systemd service file for API created successfully.${NC}"


# --- 9. Enable and Start API Service ---
echo -e "${GREEN}Enabling and starting API service...${NC}"
systemctl daemon-reload
systemctl enable dns_api
systemctl start dns_api

if [ $? -ne 0 ]; then
    echo -e "${RED}Error starting API service. Please check the logs:${NC}"
    echo -e "${YELLOW}sudo journalctl -u dns_api --no-pager${NC}"
    deactivate
    exit 1
fi
echo -e "${GREEN}API service enabled and started successfully.${NC}"

# --- 10. Configure Firewall for API ---
if [[ "$CONFIGURE_UFW_API" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Configuring firewall (UFW) for API port...${NC}"
    # Check if UFW is installed
    if ! command -v ufw &> /dev/null; then
        echo -e "${YELLOW}UFW not found. Installing UFW...${NC}"
        apt install ufw -y
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error installing UFW. Please install manually.${NC}"
        fi
    fi
    ufw allow "$API_PORT"/tcp
    ufw enable
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error enabling UFW. UFW might already be active or there's an issue.${NC}"
    fi
    echo -e "${GREEN}Firewall (UFW) configured successfully for API port.${NC}"
else
    echo -e "${YELLOW}Firewall configuration for API port skipped. Please ensure port $API_PORT is open.${NC}"
fi

# --- Final Steps ---
echo -e "${GREEN}--- API Backend installation completed successfully! ---${NC}"
echo -e "${YELLOW}Your API Backend is accessible at http://your_server_ip:$API_PORT/docs.${NC}"
echo -e "${YELLOW}You can test the API via Swagger UI documentation.${NC}"
echo -e "${YELLOW}To check API status: sudo systemctl status dns_api${NC}"
echo -e "${YELLOW}To view API logs: sudo journalctl -u dns_api --no-pager${NC}"
echo -e "${YELLOW}The next step is to build the Frontend UI that will interact with this API.${NC}"
echo -e "${YELLOW}Good luck!${NC}"

# Deactivate virtual environment
deactivate
