![PeDitX Banner](https://raw.githubusercontent.com/peditx/luci-theme-peditx/refs/heads/main/luasrc/brand.png)
# PeDitX's CoreDNS-master: Advanced DNS Proxy and Bypass Manager
## Language Selection:

[**English**](README.md) | [**فارسی**](README_fa.md) | [**中文**](README_zh.md) | [**Русский**](README_ru.md)


[![GitHub license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/peditx/CoreDNS-master/blob/main/LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/peditx/CoreDNS-master.svg?style=social)](https://github.com/peditx/CoreDNS-master/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/peditx/CoreDNS-master.svg?style=social)](https://github.com/peditx/CoreDNS-master/network/members)


## 项目概览

PeDitX's CoreDNS-master 是一款功能强大且灵活的DNS流量管理解决方案，旨在有效绕过互联网限制。它结合了作为强大DNS后端的 **CoreDNS**、用于智能控制的基于 **FastAPI** 的API，以及用于直观用户界面的 **React.js** 前端。该系统允许选择性DNS路由，包括高级功能，如 **Geo-IP 过滤** 和 **Xray 代理集成**，适用于特定域名或地理区域。

我们的目标是为大量用户提供一个全面、易于管理且可扩展的DNS代理解决方案，让您对DNS解析路径拥有精细的控制。

-----

## 功能特性

  * **CoreDNS 后端：** 高性能、可靠的DNS解析。
  * **FastAPI 后端API：** 快速、现代的API，用于管理所有DNS配置。
  * **React.js 前端UI：** 直观的网页界面，便于管理域名和规则。
  * **基于域名的绕过：** 将特定域名通过自定义DNS服务器进行路由。
  * **基于 Geo-IP 的路由：** 使用 MaxMind GeoLite2 根据用户地理位置直接进行DNS查询。
  * **基于 Geo-Site 的路由：** 将特定的DNS规则应用于按区域或目的分类的域名列表。
  * **Xray 代理集成：** 为选定的域名或区域通过 Xray 隧道无缝路由DNS流量，以实现高级规避，并可直接从用户界面进行管理。
  * **自动化配置管理：** API 动态生成 CoreDNS 配置并重新加载服务。
  * **简易设置：** 通过交互式Shell脚本简化安装和修改过程。

-----

## 架构

本项目采用现代三层架构：

  * **DNS 层：** CoreDNS 作为主要的DNS服务器，配置用于处理请求并根据后端API的指令应用路由策略。
  * **API 层：** 一个 Python FastAPI 应用程序作为控制平面。它与 PostgreSQL 数据库交互，存储配置（域名、GeoIP 规则、Xray 设置），并动态更新 CoreDNS 的配置文件。它还管理 Xray 服务的重启。
  * **表示层：** 一个 React.js 单页应用程序（SPA）提供了一个用户友好的网页界面，供管理员与API交互，从而轻松管理复杂的路由规则。

-----

## 安装

本项目利用一系列顺序安装和修改脚本，在 **基于 Debian/Ubuntu 的系统** 上设置整个环境。

**强烈建议按照安装步骤进行操作，以确保顺利设置。**

### 前提条件

开始之前，请确保您拥有：

  * 一台全新的 Debian/Ubuntu 服务器（建议使用 VPS）。
  * Root 访问权限或具有 `sudo` 权限的用户。
  * 服务器上的活跃互联网连接。
  * **（可选但建议用于 Geo-IP）：** [MaxMind GeoLite2 许可证密钥](https://www.maxmind.com/en/geolite2/downloads) 用于下载 GeoIP 数据库。
  * **（可选但建议用于 Xray）：** 您的 Xray 远程服务器详细信息（IP/域名、端口、UUID、协议、网络、TLS 设置）。

### 快速安装

要安装所有必要的先决条件并启动主交互式菜单，请执行以下命令：

```bash
rm -f setup.sh && wget https://raw.githubusercontent.com/peditx/CoreDNS-master/refs/heads/main/setup.sh && chmod +x setup.sh && sudo bash setup.sh
```

此命令将：

1.  删除任何现有的 `setup.sh` 文件。
2.  从 GitHub 仓库下载最新的 `setup.sh` 脚本。
3.  授予下载的脚本执行权限。
4.  以 `sudo` 权限执行 `setup.sh` 脚本。

然后 `setup.sh` 脚本将：

  * 更新您的系统并安装基本工具（curl, wget, git, vim, systemctl 等）。
  * 安装 **Node.js, npm, 和 `create-react-app`**。
  * 安装 **Python3, pip, 和 `python3-venv`**。
  * 安装 **PostgreSQL**。
  * 安装 **Nginx**。
  * 安装 **UFW** (Uncomplicated Firewall) 和 **ACL**。
  * 最后，它将下载并执行 `menu.sh` 脚本，该脚本提供一个交互式界面，用于安装和配置 CoreDNS Bypass Manager 的组件。

### 分步安装（通过 `menu.sh`）

`setup.sh` 完成后，`menu.sh` 脚本将自动启动。按照屏幕上的提示，并按以下顺序选择选项，以完全设置您的系统：

1.  **安装 CoreDNS (install\_coredns.sh)：** 设置 CoreDNS 服务器。
2.  **安装 API 后端 (install\_api\_backend.sh)：** 部署 FastAPI 应用程序并配置 PostgreSQL。
3.  **安装前端 UI (install\_frontend\_ui.sh)：** 设置 React.js 网页界面并配置 Nginx 以提供服务。
4.  **应用 Geo-IP Mod (mod\_geo\_ip.sh)：** 将 Geo-IP 功能集成到 API 和 CoreDNS 中。
5.  **集成 Xray (mod\_xray\_integration.sh)：** 安装 Xray 并设置其本地 DNS 代理，配置 API 以控制 Xray。
6.  **更新 Xray UI (update\_xray\_ui\_integration.sh)：** 更新前端 UI，以直接管理 Xray 配置、GeoIP 规则和 GeoSite 列表。

**重要提示：** 菜单中的每个脚本都基于前一个脚本。**除非您完全理解依赖关系，否则不要跳过步骤或乱序运行它们。**

-----

## 使用方法

成功安装后，您的 CoreDNS Bypass Manager UI 将通过服务器的IP地址或域名，在Nginx端口（默认：80）上可访问。

  * **访问 UI：** 打开您的网页浏览器，导航至 `http://YOUR_SERVER_IP` (或 `http://YOUR_SERVER_IP:NGINX_PORT` 如果您选择了非默认端口)。
  * **API 文档：** API 的 Swagger UI 文档将在 `http://YOUR_SERVER_IP:API_PORT/docs` (默认 API\_PORT：8000) 可用。

UI 提供以下界面：

  * 添加、编辑和删除用于绕过的域名。
  * 配置 Geo-IP 规则（按国家代码）以进行特定转发或阻止。
  * 管理带有自定义路由的 Geo-Site 列表。
  * **更新 Xray 配置：** 通过 URL 或直接粘贴提供 Xray `config.json`。
  * **更新 GeoIP 数据库：** 触发下载最新的 MaxMind GeoLite2 数据库（需要许可证密钥）。
  * **应用 CoreDNS 更改：** 将所有数据库驱动的配置推送到 CoreDNS 并重新加载其服务。

-----

## 安全注意事项

  * **防火墙：** 确保 UFW 配置为仅允许必要的端口（53 用于 DNS，80/443 用于 Nginx，8000 用于 API 访问，9153 用于 Prometheus）。
  * **专用用户：** 安装脚本尝试使用专用系统用户（`coredns`，`api_user`）以增强安全性。请勿在生产环境中以 root 身份运行服务。
  * **Sudoers 配置：** API 需要 `NOPASSWD` sudo 权限才能执行 `systemctl reload coredns` 和 `systemctl restart xray`。请根据您的具体环境，尽可能审查并收紧这些权限。
  * **MaxMind 许可证密钥：** 请妥善保管您的 MaxMind 许可证密钥。
  * **Xray 配置：** 您的 Xray `config.json` 文件包含敏感信息（UUID，服务器详细信息）。请确保其安全并仅供 API 访问。
  * **API 认证：** 对于生产环境，**强烈建议** 实施 API 认证（例如，使用 JWT 令牌）以防止未经授权访问您的 DNS 管理系统。此功能未包含在基本设置中，以简化操作，但对于安全性至关重要。

-----

## 故障排除

  * **检查服务状态：**
      * `sudo systemctl status coredns`
      * `sudo systemctl status dns_api`
      * `sudo systemctl status xray`
      * `sudo systemctl status nginx`
  * **查看日志：**
      * `sudo journalctl -u coredns --no-pager`
      * `sudo journalctl -u dns_api --no-pager`
      * `sudo journalctl -u xray --no-pager`
      * `sudo journalctl -u nginx --no-pager`
  * **权限问题：** 许多问题与文件权限有关。确保 `api_user` 具有对 `/etc/coredns` 和 `/usr/local/etc/xray` 的写入权限。
  * **API 通信：** 使用 `curl` 直接从服务器测试 API 端点，以隔离问题。
  * **UI 控制台：** 使用 UI 时，检查浏览器的开发者控制台是否存在 JavaScript 错误或网络问题。

-----

## 贡献

欢迎贡献！如果您发现错误、有功能请求或希望改进代码，请随时在 GitHub 仓库中提出 issue 或提交 pull request。

-----

## 许可证

本项目采用 MIT 许可证 - 详情请参阅 [LICENSE](https://www.google.com/search?q=LICENSE) 文件。
