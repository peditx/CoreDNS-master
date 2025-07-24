![PeDitX Banner](https://raw.githubusercontent.com/peditx/luci-theme-peditx/refs/heads/main/luasrc/brand.png)
# PeDitX's CoreDNS-master: Advanced DNS Proxy and Bypass Manager
## Language Selection:

[**English**](README.md) | [**فارسی**](README_fa.md) | [**中文**](README_zh.md) | [**Русский**](README_ru.md)


[![GitHub license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/peditx/CoreDNS-master/blob/main/LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/peditx/CoreDNS-master.svg?style=social)](https://github.com/peditx/CoreDNS-master/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/peditx/CoreDNS-master.svg?style=social)](https://github.com/peditx/CoreDNS-master/network/members)

## Project Overview

PeDitX's CoreDNS-master is a powerful and flexible solution for managing DNS traffic, designed to bypass internet restrictions effectively. It combines **CoreDNS** as the robust DNS backend, a **FastAPI**-based API for intelligent control, and a **React.js** frontend for an intuitive user interface. This system allows for selective DNS routing, including advanced features like **Geo-IP filtering** and **Xray proxy integration** for specific domains or geographical regions.

The goal is to provide a comprehensive, easily manageable, and scalable DNS proxy solution for a large number of users, giving you granular control over DNS resolution paths.

---

## Features

* **CoreDNS Backend:** High-performance and reliable DNS resolution.
* **FastAPI Backend API:** A fast and modern API to manage all DNS configurations.
* **React.js Frontend UI:** An intuitive web interface for easy management of domains and rules.
* **Domain-based Bypass:** Route specific domains through custom DNS servers.
* **Geo-IP Based Routing:** Direct DNS queries based on the user's geographical location using MaxMind GeoLite2.
* **Geo-Site Based Routing:** Apply specific DNS rules to lists of domains categorized by region or purpose.
* **Xray Proxy Integration:** Seamlessly route DNS traffic for selected domains or regions through an Xray tunnel for advanced circumvention, managed directly from the UI.
* **Automated Configuration Management:** API dynamically generates CoreDNS configuration and reloads the service.
* **Easy Setup:** Streamlined installation and modification process via interactive shell scripts.

---

## Architecture

The project leverages a modern three-tier architecture:

* **DNS Layer:** CoreDNS acts as the primary DNS server, configured to handle requests and apply routing policies based on the backend API's instructions.
* **API Layer:** A Python FastAPI application serves as the control plane. It interacts with a PostgreSQL database to store configurations (domains, GeoIP rules, Xray settings) and dynamically updates CoreDNS's configuration files. It also manages Xray service restarts.
* **Presentation Layer:** A React.js single-page application (SPA) provides a user-friendly web interface for administrators to interact with the API, making it easy to manage complex routing rules.

---

## Installation

This project utilizes a series of sequential installation and modification scripts to set up the entire environment on **Debian/Ubuntu-based systems**.

**It's highly recommended to follow the installation steps in order to ensure a smooth setup.**

### Prerequisites

Before you begin, ensure you have:

* A fresh Debian/Ubuntu server (VPS recommended).
* Root access or a user with `sudo` privileges.
* An active internet connection on the server.
* **(Optional but recommended for Geo-IP):** A [MaxMind GeoLite2 License Key](https://www.maxmind.com/en/geolite2/downloads) to download GeoIP databases.
* **(Optional but recommended for Xray):** Details of your Xray remote server (IP/Domain, Port, UUID, Protocol, Network, TLS settings).

### Quick Installation

To install all necessary prerequisites and launch the main interactive menu, execute the following command:

```bash
rm -f setup.sh && wget https://raw.githubusercontent.com/peditx/CoreDNS-master/refs/heads/main/setup.sh && chmod +x setup.sh && sudo bash setup.sh
```

This command will:

1.  Remove any existing `setup.sh` file.
2.  Download the latest `setup.sh` script from the GitHub repository.
3.  Grant execute permissions to the downloaded script.
4.  Execute the `setup.sh` script with `sudo` privileges.

The `setup.sh` script will then:

  * Update your system and install essential tools (curl, wget, git, vim, systemctl, etc.).
  * Install **Node.js, npm, and `create-react-app`**.
  * Install **Python3, pip, and `python3-venv`**.
  * Install **PostgreSQL**.
  * Install **Nginx**.
  * Install **UFW** (Uncomplicated Firewall) and **ACL**.
  * Finally, it will download and execute the `menu.sh` script, which provides an interactive interface for installing and configuring the CoreDNS Bypass Manager components.

### Step-by-Step Installation (via `menu.sh`)

Once `setup.sh` finishes, the `menu.sh` script will launch automatically. Follow the on-screen prompts and select the options in the order listed below to fully set up your system:

1.  **Install CoreDNS (install\_coredns.sh):** Sets up the CoreDNS server.
2.  **Install API Backend (install\_api\_backend.sh):** Deploys the FastAPI application and configures PostgreSQL.
3.  **Install Frontend UI (install\_frontend\_ui.sh):** Sets up the React.js web interface and configures Nginx to serve it.
4.  **Apply Geo-IP Mod (mod\_geo\_ip.sh):** Integrates Geo-IP functionality into the API and CoreDNS.
5.  **Integrate Xray (mod\_xray\_integration.sh):** Installs Xray and sets up its local DNS proxy, configuring the API for Xray control.
6.  **Update Xray UI (update\_xray\_ui\_integration.sh):** Updates the Frontend UI to manage Xray configuration, GeoIP rules, and GeoSite lists directly.

**Important:** Each script in the menu builds upon the previous one. **Do not skip steps or run them out of order** unless you fully understand the dependencies.

-----

## Usage

After successful installation, your CoreDNS Bypass Manager UI will be accessible via your server's IP address or domain on the Nginx port (default: 80).

  * **Access the UI:** Open your web browser and navigate to `http://YOUR_SERVER_IP` (or `http://YOUR_SERVER_IP:NGINX_PORT` if you chose a non-default port).
  * **API Documentation:** The API's Swagger UI documentation will be available at `http://YOUR_SERVER_IP:API_PORT/docs` (default API\_PORT: 8000).

The UI provides interfaces to:

  * Add, edit, and delete domains for bypass.
  * Configure Geo-IP rules (by country code) for specific forwarding or blocking.
  * Manage Geo-Site lists with custom routing.
  * **Update Xray Configuration:** Provide Xray `config.json` via URL or direct paste.
  * **Update GeoIP Database:** Trigger a download of the latest MaxMind GeoLite2 database (requires license key).
  * **Apply CoreDNS Changes:** Push all database-driven configurations to CoreDNS and reload its service.

-----

## Security Considerations

  * **Firewall:** Ensure UFW is configured to only allow necessary ports (53 for DNS, 80/443 for Nginx, 8000 for API access, 9153 for Prometheus).
  * **Dedicated Users:** The installation scripts attempt to use dedicated system users (`coredns`, `api_user`) for enhanced security. Don't run services as root in production.
  * **Sudoers Configuration:** The API requires `NOPASSWD` sudo access for `systemctl reload coredns` and `systemctl restart xray`. Review and tighten these permissions as much as possible for your specific environment.
  * **MaxMind License Key:** Keep your MaxMind License Key confidential.
  * **Xray Configuration:** Your Xray `config.json` contains sensitive information (UUID, server details). Ensure it's secured and only accessible by the API.
  * **API Authentication:** For production environments, it's **highly recommended** to implement API authentication (e.g., using JWT tokens) to prevent unauthorized access to your DNS management system. This isn't included in the basic setup for simplicity but is crucial for security.

-----

## Troubleshooting

  * **Check Service Status:**
      * `sudo systemctl status coredns`
      * `sudo systemctl status dns_api`
      * `sudo systemctl status xray`
      * `sudo systemctl status nginx`
  * **View Logs:**
      * `sudo journalctl -u coredns --no-pager`
      * `sudo journalctl -u dns_api --no-pager`
      * `sudo journalctl -u xray --no-pager`
      * `sudo journalctl -u nginx --no-pager`
  * **Permission Issues:** Many issues are related to file permissions. Ensure the `api_user` has write access to `/etc/coredns` and `/usr/local/etc/xray`.
  * **API Communication:** Use `curl` to test API endpoints directly from the server to isolate issues.
  * **UI Console:** Check your browser's developer console for JavaScript errors or network issues when using the UI.

-----

## Contributing

Contributions are welcome\! If you find bugs, have feature requests, or want to improve the code, feel free to open an issue or submit a pull request on the GitHub repository.

-----

## License

This project is licensed under the MIT License - see the [LICENSE](https://www.google.com/search?q=LICENSE) file for details.

