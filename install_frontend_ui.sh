#!/bin/bash

# ANSI escape codes for colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}--- Frontend UI Installation Script (React) ---${NC}"
echo -e "${YELLOW}این اسکریپت رابط کاربری Frontend را با استفاده از React برای مدیریت CoreDNS API نصب و پیکربندی می‌کند.${NC}"
echo -e "${YELLOW}این اسکریپت فرض می‌کند که Node.js و npm قبلاً نصب شده‌اند.${NC}"
echo -e "${YELLOW}همچنین فرض می‌شود که API Backend روی پورت 8000 فعال است.${NC}"
echo -e "${YELLOW}روی سیستم‌های Debian/Ubuntu تست شده است.${NC}"

# --- Check for root privileges (for Nginx/UFW, not strictly for React app itself) ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script needs root privileges for Nginx and UFW configuration. Please use 'sudo bash install_frontend_ui.sh'.${NC}"
    exit 1
fi

# --- Get user inputs ---
read -p "Enter the IP address or hostname of your API Backend (e.g., http://your_server_ip:8000): " API_BASE_URL
while [[ -z "$API_BASE_URL" || ! "$API_BASE_URL" =~ ^http(s)?://[a-zA-Z0-9\.-]+(:[0-9]+)?/?$ ]]; do
    echo -e "${RED}Error: Invalid API Backend URL. Please enter a valid URL (e.g., http://your_server_ip:8000).${NC}"
    read -p "Enter the IP address or hostname of your API Backend: " API_BASE_URL
done

read -p "Enter the port for the Nginx web server (default: 80): " NGINX_PORT
NGINX_PORT=${NGINX_PORT:-80}

read -p "Do you want to configure UFW (firewall) for the Nginx port? (y/n): " CONFIGURE_UFW_NGINX

# --- 1. Install Node.js and npm (if not already installed) ---
echo -e "${GREEN}Checking for Node.js and npm installation...${NC}"
if ! command -v node &> /dev/null || ! command -v npm &> /dev/null; then
    echo -e "${YELLOW}Node.js or npm not found. Installing Node.js LTS version...${NC}"
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

# --- 2. Create React App ---
echo -e "${GREEN}Creating React application...${NC}"
FRONTEND_DIR="/opt/dns_bypass_frontend" # Recommended path for application
mkdir -p "$FRONTEND_DIR"
cd "$FRONTEND_DIR"

# Use npx to create a new React app
npm install -g create-react-app # Install create-react-app globally if not present
create-react-app . # Create app in current directory
if [ $? -ne 0 ]; then
    echo -e "${RED}Error creating React application. Please check npm logs.${NC}"
    exit 1
fi
echo -e "${GREEN}React application created successfully.${NC}"

# --- 3. Configure React App to connect to API Backend ---
echo -e "${GREEN}Configuring React app to connect to the API Backend...${NC}"

# Create .env.production file for React app (for production build)
cat <<EOF > "$FRONTEND_DIR/.env.production"
REACT_APP_API_BASE_URL=$API_BASE_URL
EOF
echo -e "${YELLOW}React .env.production file created with API_BASE_URL.${NC}"

# --- 4. Add React Components and Styles ---
echo -e "${GREEN}Adding React components and styles...${NC}"

# Overwrite src/App.js
cat <<EOF > "$FRONTEND_DIR/src/App.js"
import React, { useState, useEffect } from 'react';
import './App.css';

const API_BASE_URL = process.env.REACT_APP_API_BASE_URL || 'http://localhost:8000';

function App() {
  const [domains, setDomains] = useState([]);
  const [newDomainName, setNewDomainName] = useState('');
  const [newBypassIps, setNewBypassIps] = useState('');
  const [editingDomain, setEditingDomain] = useState(null);
  const [message, setMessage] = useState('');
  const [messageType, setMessageType] = useState(''); // 'success' or 'error'

  useEffect(() => {
    fetchDomains();
  }, []);

  const showMessage = (msg, type) => {
    setMessage(msg);
    setMessageType(type);
    setTimeout(() => {
      setMessage('');
      setMessageType('');
    }, 3000); // Message disappears after 3 seconds
  };

  const fetchDomains = async () => {
    try {
      const response = await fetch(\`\${API_BASE_URL}/domains/\`);
      if (!response.ok) {
        throw new Error(\`HTTP error! status: \${response.status}\`);
      }
      const data = await response.json();
      setDomains(data);
    } catch (error) {
      console.error("Error fetching domains:", error);
      showMessage(\`Error fetching domains: \${error.message}\`, 'error');
    }
  };

  const handleCreateOrUpdateDomain = async (e) => {
    e.preventDefault();
    const domainData = { name: newDomainName, bypass_ips: newBypassIps };
    let response;

    try {
      if (editingDomain) {
        // Update existing domain
        response = await fetch(\`\${API_BASE_URL}/domains/\${editingDomain.id}\`, {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(domainData),
        });
      } else {
        // Create new domain
        response = await fetch(\`\${API_BASE_URL}/domains/\`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(domainData),
        });
      }

      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.detail || \`HTTP error! status: \${response.status}\`);
      }

      const result = await response.json();
      showMessage(\`Domain \${editingDomain ? 'updated' : 'added'} successfully!\`, 'success');
      setNewDomainName('');
      setNewBypassIps('');
      setEditingDomain(null);
      fetchDomains(); // Refresh the list
    } catch (error) {
      console.error("Error creating/updating domain:", error);
      showMessage(\`Error: \${error.message}\`, 'error');
    }
  };

  const handleDeleteDomain = async (id) => {
    if (!window.confirm("Are you sure you want to delete this domain?")) {
      return;
    }
    try {
      const response = await fetch(\`\${API_BASE_URL}/domains/\${id}\`, {
        method: 'DELETE',
      });
      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.detail || \`HTTP error! status: \${response.status}\`);
      }
      showMessage('Domain deleted successfully!', 'success');
      fetchDomains(); // Refresh the list
    } catch (error) {
      console.error("Error deleting domain:", error);
      showMessage(\`Error: \${error.message}\`, 'error');
    }
  };

  const handleEditClick = (domain) => {
    setEditingDomain(domain);
    setNewDomainName(domain.name);
    setNewBypassIps(domain.bypass_ips);
  };

  const handleCancelEdit = () => {
    setEditingDomain(null);
    setNewDomainName('');
    setNewBypassIps('');
  };

  const handleApplyChanges = async () => {
    try {
      const response = await fetch(\`\${API_BASE_URL}/config/apply_changes/\`, {
        method: 'POST',
      });
      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.detail || \`HTTP error! status: \${response.status}\`);
      }
      showMessage('CoreDNS configuration reloaded successfully!', 'success');
    } catch (error) {
      console.error("Error applying changes:", error);
      showMessage(\`Error applying changes: \${error.message}\`, 'error');
    }
  };

  return (
    <div className="App">
      <header className="App-header">
        <h1>CoreDNS Bypass Manager</h1>
        <button onClick={handleApplyChanges} className="apply-changes-button">Apply CoreDNS Changes</button>
      </header>

      {message && (
        <div className={\`message \${messageType}\`}>
          {message}
        </div>
      )}

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
              required
            />
          </div>
          <button type="submit" className="submit-button">
            {editingDomain ? 'Update Domain' : 'Add Domain'}
          </button>
          {editingDomain && (
            <button type="button" onClick={handleCancelEdit} className="cancel-button">
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
                <span className="domain-ips">{domain.bypass_ips}</span>
                <div className="domain-actions">
                  <button onClick={() => handleEditClick(domain)} className="edit-button">Edit</button>
                  <button onClick={() => handleDeleteDomain(domain.id)} className="delete-button">Delete</button>
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
echo -e "${YELLOW}src/App.js updated.${NC}"

# Overwrite src/App.css
cat <<EOF > "$FRONTEND_DIR/src/App.css"
.App {
  font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
  text-align: center;
  background-color: #f4f7f6;
  min-height: 100vh;
  padding: 20px;
  color: #333;
}

.App-header {
  background-color: #28a745; /* Green header */
  padding: 20px;
  border-radius: 8px;
  margin-bottom: 30px;
  color: white;
  box-shadow: 0 4px 8px rgba(0, 0, 0, 0.1);
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.App-header h1 {
  margin: 0;
  font-size: 2.2em;
}

.apply-changes-button {
  background-color: #007bff; /* Blue */
  color: white;
  padding: 10px 20px;
  border: none;
  border-radius: 5px;
  cursor: pointer;
  font-size: 1em;
  transition: background-color 0.3s ease;
}

.apply-changes-button:hover {
  background-color: #0056b3;
}

.message {
  padding: 10px;
  margin: 10px auto;
  border-radius: 5px;
  width: 80%;
  max-width: 600px;
  font-weight: bold;
  opacity: 1;
  transition: opacity 0.5s ease-in-out;
}

.message.success {
  background-color: #d4edda;
  color: #155724;
  border: 1px solid #c3e6cb;
}

.message.error {
  background-color: #f8d7da;
  color: #721c24;
  border: 1px solid #f5c6cb;
}

.form-container, .domain-list-container {
  background-color: white;
  padding: 30px;
  border-radius: 8px;
  box-shadow: 0 4px 8px rgba(0, 0, 0, 0.05);
  margin: 20px auto;
  max-width: 700px;
}

.form-container h2, .domain-list-container h2 {
  color: #28a745;
  margin-top: 0;
  margin-bottom: 25px;
  font-size: 1.8em;
}

.form-group {
  margin-bottom: 18px;
  text-align: left;
}

.form-group label {
  display: block;
  margin-bottom: 8px;
  font-weight: bold;
  color: #555;
}

.form-group input[type="text"] {
  width: calc(100% - 20px);
  padding: 12px;
  border: 1px solid #ccc;
  border-radius: 5px;
  font-size: 1em;
}

.submit-button, .cancel-button {
  background-color: #28a745; /* Green */
  color: white;
  padding: 12px 25px;
  border: none;
  border-radius: 5px;
  cursor: pointer;
  font-size: 1.1em;
  margin-top: 15px;
  margin-right: 10px;
  transition: background-color 0.3s ease;
}

.submit-button:hover {
  background-color: #218838;
}

.cancel-button {
  background-color: #6c757d; /* Gray */
}

.cancel-button:hover {
  background-color: #5a6268;
}

.domain-list {
  list-style: none;
  padding: 0;
  margin-top: 20px;
}

.domain-item {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 15px 20px;
  border: 1px solid #eee;
  border-radius: 5px;
  margin-bottom: 10px;
  background-color: #fdfdfd;
  box-shadow: 0 2px 4px rgba(0, 0, 0, 0.03);
}

.domain-name {
  font-weight: bold;
  color: #007bff; /* Blue */
  flex-grow: 1;
  text-align: left;
}

.domain-ips {
  color: #666;
  margin-left: 20px;
}

.domain-actions button {
  background-color: #ffc107; /* Yellow for edit */
  color: #333;
  padding: 8px 15px;
  border: none;
  border-radius: 4px;
  cursor: pointer;
  font-size: 0.9em;
  margin-left: 10px;
  transition: background-color 0.3s ease;
}

.domain-actions button:hover {
  background-color: #e0a800;
}

.domain-actions .delete-button {
  background-color: #dc3545; /* Red for delete */
  color: white;
}

.domain-actions .delete-button:hover {
  background-color: #c82333;
}
EOF
echo -e "${YELLOW}src/App.css updated.${NC}"
echo -e "${GREEN}React components and styles added successfully.${NC}"

# --- 5. Build React App for Production ---
echo -e "${GREEN}Building React application for production...${NC}"
cd "$FRONTEND_DIR"
npm run build
if [ $? -ne 0 ]; then
    echo -e "${RED}Error building React application. Please check npm build logs.${NC}"
    exit 1
fi
echo -e "${GREEN}React application built successfully. Static files are in '$FRONTEND_DIR/build'.${NC}"

# --- 6. Install and Configure Nginx to Serve React App ---
echo -e "${GREEN}Installing and configuring Nginx to serve the React app...${NC}"
apt install nginx -y
if [ $? -ne 0 ]; then
    echo -e "${RED}Error installing Nginx. Please check for issues.${NC}"
    exit 1
fi
echo -e "${GREEN}Nginx installed successfully.${NC}"

# Configure Nginx site
NGINX_CONF_FILE="/etc/nginx/sites-available/dns_frontend"
cat <<EOF > "$NGINX_CONF_FILE"
server {
    listen $NGINX_PORT;
    server_name _; # Listen on all available hostnames/IPs

    root $FRONTEND_DIR/build;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Optional: If you want to proxy API requests through Nginx
    # This is useful if your API is on the same server but on a different port,
    # and you want to avoid CORS issues or simplify domain management.
    # For this setup, we assume direct API access via REACT_APP_API_BASE_URL.
    # If you enable this, you would change REACT_APP_API_BASE_URL to point to /api
    # location /api/ {
    #     proxy_pass $API_BASE_URL/; # Ensure trailing slash for proxy_pass
    #     proxy_set_header Host \$host;
    #     proxy_set_header X-Real-IP \$remote_addr;
    #     proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    #     proxy_set_header X-Forwarded-Proto \$scheme;
    # }
}
EOF
echo -e "${YELLOW}Nginx configuration file created at $NGINX_CONF_FILE.${NC}"

# Create symlink to enable the site
ln -sf "$NGINX_CONF_FILE" /etc/nginx/sites-enabled/
# Remove default Nginx site
rm -f /etc/nginx/sites-enabled/default

# Test Nginx configuration
nginx -t
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Nginx configuration test failed. Please check the Nginx config file for syntax errors.${NC}"
    exit 1
fi

# Restart Nginx
systemctl restart nginx
if [ $? -ne 0 ]; then
    echo -e "${RED}Error restarting Nginx service. Please check Nginx logs.${NC}"
    exit 1
fi
echo -e "${GREEN}Nginx configured and restarted successfully.${NC}"

# --- 7. Configure Firewall (UFW) for Nginx ---
if [[ "$CONFIGURE_UFW_NGINX" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Configuring firewall (UFW) for Nginx port...${NC}"
    if ! command -v ufw &> /dev/null; then
        echo -e "${YELLOW}UFW not found. Installing UFW...${NC}"
        apt install ufw -y
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error installing UFW. Please install manually.${NC}"
        fi
    fi
    ufw allow "$NGINX_PORT"/tcp
    ufw enable
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error enabling UFW. UFW might already be active or there's an issue.${NC}"
    fi
    echo -e "${GREEN}Firewall (UFW) configured successfully for Nginx port.${NC}"
else
    echo -e "${YELLOW}Firewall configuration for Nginx port skipped. Please ensure port $NGINX_PORT is open.${NC}"
fi

# --- Final Steps ---
echo -e "${GREEN}--- Frontend UI installation completed successfully! ---${NC}"
echo -e "${YELLOW}Your CoreDNS Bypass Manager UI is now accessible at http://your_server_ip:$NGINX_PORT.${NC}"
echo -e "${YELLOW}Remember to replace 'your_server_ip' with your actual server's IP address or domain name.${NC}"
echo -e "${YELLOW}You can now manage your blocked domains visually through the web interface.${NC}"
echo -e "${YELLOW}Good luck!${NC}"
