# Xray Reality & Hysteria 2 自动化网关引擎 (Pure Edition)

<p align="center">
  <a href="https://github.com/XTLS/Xray-core"><img src="https://img.shields.io/badge/Protocols-VLESS--Vision--Reality%20%7C%20Hysteria2-orange?style=flat-square" alt="Protocol" /></a>
  <a href="https://nginx.org/"><img src="https://img.shields.io/badge/Gateway-Nginx%20Fallback-009639?style=flat-square&logo=nginx&logoColor=white" alt="Web Server" /></a>
  <a href="https://letsencrypt.org/"><img src="https://img.shields.io/badge/TLS%20Cert-ECC--256%20Auto--Renew-yellowgreen?style=flat-square&logo=letsencrypt&logoColor=white" alt="TLS Cert" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-lightgrey?style=flat-square" alt="License" /></a>
</p>

<p align="center">
  <a href="https://www.debian.org/"><img src="https://img.shields.io/badge/OS-Debian%2011%2B%20%7C%20Ubuntu%2020.04%2B-blue?style=flat-square&logo=linux&logoColor=white" alt="Linux Support" /></a>
  <img src="https://img.shields.io/badge/Arch-amd64%20%7C%20arm64-informational?style=flat-square" alt="Architecture" />
  <img src="https://img.shields.io/badge/Network-IPv4%20%2F%20IPv6%20Dual--Stack-blueviolet?style=flat-square" alt="Dual Stack" />
  <a href="https://git.kernel.org/"><img src="https://img.shields.io/badge/Kernel-TCP%20BBR%20%2B%20FQ-brightgreen?style=flat-square" alt="Kernel" /></a>
</p>

---

> [!TIP]
> ### 💡 纯净网络解耦设计 (Pure Architecture)
> 本项目专为现代云服务器（AWS、GCP、Oracle Cloud、阿里云、腾讯云等）量身定制。脚本彻底剥离主机防火墙规则注入模块，与云平台控制台**外部安全组（Security Group）完全解耦**。脚本不改动宿主机 iptables/nftables 链，避免规则冲突。

---

## 🚀 部署模式概览

系统在单一入站端口（默认 `443`）上通过内核 Socket 分流实现 TCP/UDP 多路复用：

| 模式 | 协议架构 | 域名要求 | 伪装机制 | 适用场景 |
| :--- | :--- | :--- | :--- | :--- |
| **1. Web 回落模式 (推荐)** | VLESS + Vision + Reality (TCP) | 必须 | 本地 Nginx 3D 伪装站 (8443) | 长期主力使用，高防封锁需求 |
| **2. 纯净直连模式** | VLESS + Vision + Reality (TCP) | 无需 | 借用大厂 SNI（如 Apple）直连 | 临时极速部署，轻量无 Web 依赖 |
| **3. 全能共存模式** | Reality (TCP) + Hysteria 2 (UDP) | 必须 | Nginx 双端口回落 (8443 / 8444) | 弱网抗丢包，TCP/UDP 单端口双通道互备 |

---

## 📥 安装与运行

> **注意**：请将命令中的 `你的用户名/你的仓库名` 替换为你实际的 GitHub 路径。

### 方式 A：在线极速安装（推荐，不落盘、无文件残留）
适合一次性部署，执行完毕后当前目录不产生任何多余脚本文件：
```bash
bash <(curl -fsSL "[https://raw.githubusercontent.com/你的用户名/你的仓库名/main/install.sh](https://raw.githubusercontent.com/你的用户名/你的仓库名/main/install.sh)")
```

### 方式 B：下载到本地执行（推荐需要长期运维的用户）
将脚本落盘保存，赋予执行权限，便于后续随时进入管理菜单：

* **使用 curl（推荐）：**
  ```bash
  curl -fsSL -o install.sh "[https://raw.githubusercontent.com/你的用户名/你的仓库名/main/install.sh](https://raw.githubusercontent.com/你的用户名/你的仓库名/main/install.sh)" && chmod +x install.sh && ./install.sh
  ```
* **使用 wget：**
  ```bash
  wget -O install.sh "[https://raw.githubusercontent.com/你的用户名/你的仓库名/main/install.sh](https://raw.githubusercontent.com/你的用户名/你的仓库名/main/install.sh)" && chmod +x install.sh && ./install.sh
  ```

> **日常管理**：采用方式 B 安装后，后续若需修改端口、查看状态或卸载服务，只需在当前目录执行 `./install.sh` 即可直接唤出交互菜单。

---

## 🌐 端口与云安全组配置规范

本脚本不操作主机防火墙，请直接在**云服务商控制台安全组（Security Group）**添加入站规则：

* **模式 1**：放行 **自定义业务端口 (TCP)** 与 **80 端口 (TCP)**。
* **模式 2**：仅放行 **自定义业务端口 (TCP)**。
* **模式 3**：需同时放行 **自定义业务端口 (TCP 与 UDP)** 以及 **80 端口 (TCP)**。
* **本地保留端口**：`80`、`8443` 与 `8444` 供本地回落服务独占，**业务端口严禁设为 80、8443 或 8444**。

---

## 🛠️ 常用运维指令

所有服务统一由系统原生 Systemd 接管：

```bash
# 查看核心组件状态
systemctl status xray              # Xray Reality 核心进程
systemctl status nginx             # Nginx 伪装网关 (模式 1/3)
systemctl status hysteria-server   # Hysteria 2 协议栈 (模式 3)

# 重启组件
systemctl restart xray
systemctl reload nginx             # 平滑重载 Nginx 配置
systemctl restart hysteria-server

# 实时查看运行日志
journalctl -u xray -f              # Xray 运行与分流日志
journalctl -u hysteria-server -f   # Hysteria 2 握手与连接日志

# 查看定时任务与证书状态
systemctl list-timers --all | grep -E "xray-acme|xray-dat"  # 证书续签与规则更新定时器
/root/.acme.sh/acme.sh --list --home /root/.acme.sh          # 已安装证书详情
```

---

## 📁 核心文件与配置路径

| 组件 | 绝对路径 | 说明 |
| :--- | :--- | :--- |
| **Xray 配置** | `/usr/local/etc/xray/config.json` | VLESS-Reality 主配置文件 |
| **Xray 规则库** | `/usr/local/share/xray/` | `geoip.dat` 与 `geosite.dat` 规则库目录 |
| **Hysteria 2 配置** | `/etc/hysteria/config.yaml` | Hysteria 2 端口、密码与回落配置 |
| **Nginx 站点配置** | `/etc/nginx/sites-available/xray` | 8443 伪装站点与 80 续签配置 |
| **TLS 证书资产** | `/etc/nginx/ssl/${domain}_ecc.cer` | Let's Encrypt EC-256 证书及私钥 |
| **伪装网站资源** | `/var/www/html/` | 3D 伪装站点静态源码 |
| **维护脚本目录** | `/usr/local/etc/xray-script/` | 规则自动更新与证书热重载脚本 |

---

## ⏱️ 自动化维护与调度

* **证书自动轮转 (`xray-acme.timer`)**：每天 02:00 (SGT) 静默巡检，临期 30 天内自动续签并重载 Nginx。
* **分流规则热同步 (`xray-dat.timer`)**：每周一 03:00 (SGT) 原子更新 Loyalsoldier 路由规则库（内置 500KB 截断熔断保护）。
* **证书热加载 (`hysteria-cert-watcher.path`)**：内核事件驱动，证书写盘时防抖校验完整性并毫秒级重启 Hysteria 2。

---

## ❓ 常见问题排查 (FAQ)

**Q: 重新部署或更换端口后，客户端配置需要重新导入吗？**  
* **Xray Reality**：**完全不需要**。脚本内置持久化保护，UUID、私钥、公钥与 Short ID 绝对保持不变，客户端仅修改端口数值即可恢复连接。
* **Hysteria 2**：重装时会轮换生成高强度随机密码，需在客户端更新密码字段。

**Q: Hysteria 2 提示连接超时 (Handshake Failed)？**  
* 检查云服务商安全组是否放行了该端口的 **UDP** 协议入站规则；
* 检查客户端系统时间与 VPS 时间误差是否在 60 秒以内。

**Q: Nginx 启动提示 80 端口占用？**  
* 执行 `ss -tulpn | grep :80` 查询占用进程，若存在 Apache 或 Caddy，执行 `systemctl stop apache2 && systemctl disable apache2` 释放端口后再试。

---

> *Pure Decoupled Architecture for Cloud Computing.*
