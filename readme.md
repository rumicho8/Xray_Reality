# Xray Reality Automation Engine (Industrial Architecture Edition)

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
> ### 🚀 核心架构全景 (Architecture Overview)
> **面向生产级 Linux 节点打造的高性能全自动化代理网关部署引擎。**[cite: 1, 2]
> 方案深度融合了 **VLESS + XTLS-Vision + REALITY**、**Nginx 动态伪装回落网关** 与 **Hysteria 2 双栈端口复用** 协议架构[cite: 1, 2]。

> [!NOTE]
> ### ⚙️ 系统自适应底座 (Kernel & System Adaptation)
> * **动态语法探针**：自动感知 Nginx 版本，动态启用 `ssl_reject_handshake` 防主动探测，自适应匹配现代 `http2 on;` 独立语法[cite: 1, 2]。
> * **Debian 13+ 架构适配**：自动识别发行版主版本号，针对新一代系统将 BBR 配置原子写入 `/etc/sysctl.d/99-custom.conf` 并调用 `sysctl --system`[cite: 1, 2]。

> [!IMPORTANT]
> ### 🛡️ 状态持久化与系统治理 (Safety & Persistence)
> * **凭据零丢失**：重装与修改端口时自动回推 X25519 密钥链，客户端已有配置无需重新扫码导入[cite: 1, 2]。
> * **存储熔断机制**：`journald` 限制 100MB 磁盘配额，开启零日志黑洞策略，全生命周期保障 VPS 磁盘安全[cite: 1, 2]。

---

## 📑 目录 (Table of Contents)
- [一、 核心配置文件路径清单](#一-核心配置文件路径清单)
- [二、 服务控制与常用运维命令大全](#二-服务控制与常用运维命令大全)
- [三、 自动化任务触发时间与调度规划](#三-自动化任务触发时间与调度规划)
- [四、 路由分流规则库原子化热更新机制剖析](#四-路由分流规则库原子化热更新机制剖析)
- [五、 脚本全维度对比矩阵 (v3.0.sh vs v3.1.sh)](#五-脚本全维度对比矩阵-v30sh-vs-v31sh)
- [六、 源码架构与核心模块逐层详解](#六-源码架构与核心模块逐层详解)
  - [1. LAYER 1: 运行时基座与进程互斥安全体系](#1-layer-1-运行时基座与进程互斥安全体系)
  - [2. LAYER 2: 基础设施策略与防火墙自适应引擎](#2-layer-2-基础设施策略与防火墙自适应引擎)
  - [3. LAYER 3: 业务组件生命周期驱动](#3-layer-3-业务组件生命周期驱动)
  - [4. LAYER 4: 业务交互编排与状态机对齐](#4-layer-4-业务交互编排与状态机对齐)
  - [5. LAYER 5: CLI 调度入口与菜单驱动](#5-layer-5-cli-调度入口与菜单驱动)
- [七、 常见故障排查手册 (Troubleshooting)](#七-常见故障排查手册-troubleshooting)

---

## 一、 核心配置文件路径清单

系统遵循 Linux FHS 工业规范，所有组件文件按功能职责离散收敛管理，权限严格遵循最小权限原则：

| 业务组件 | 绝对路径 / 目录 | 文件用途说明 | 推荐安全权限 |
| :--- | :--- | :--- | :--- |
| **Xray Core** | `/usr/local/bin/xray` | Xray 核心主执行程序[cite: 1, 2] | `0755 (root:root)`[cite: 1, 2] |
| **Xray 配置** | `/usr/local/etc/xray/config.json` | VLESS-Reality、出站路由、DNS 核心主配置文件[cite: 1, 2] | `0600 (root:root)`[cite: 1, 2] |
| **Xray 规则库**| `/usr/local/share/xray/` | 存储 `geoip.dat` 与 `geosite.dat` 规则数据库[cite: 1, 2] | `0644 (root:root)` |
| **Hysteria 2** | `/usr/local/bin/hysteria` | Hysteria 2 官方二进制执行程序[cite: 1, 2] | `0755 (root:root)`[cite: 1, 2] |
| **Hysteria 配置** | `/etc/hysteria/config.yaml` | QUIC 传输参数、端口、密码与回落路由配置[cite: 1, 2] | `0600 (root:root)`[cite: 1, 2] |
| **Nginx 主配置** | `/etc/nginx/nginx.conf` | Web 主进程优化、SSL 会话缓存与事件驱动模型[cite: 1, 2] | `0644 (root:root)` |
| **Nginx 站点配置** | `/etc/nginx/sites-available/xray`<br>`/etc/nginx/sites-enabled/xray` | 8443 伪装站点、80 证书校验与 8444 HTTP 回落虚拟主机[cite: 1, 2] | `0644 (root:root)` |
| **TLS 证书资产** | `/etc/nginx/ssl/${domain}_ecc.cer`<br>`/etc/nginx/ssl/${domain}_ecc.key` | Let's Encrypt EC-256 完整证书链及独立私钥[cite: 1, 2] | `0600 (root:root)` |
| **伪装网站根目录** | `/var/www/html/` | 本地真实解压的 3D 伪装静态网页资源目录[cite: 1, 2] | `0755 (www-data:www-data)`[cite: 1, 2] |
| **ACME 核心工具** | `/root/.acme.sh/acme.sh` | 证书生命周期管理、自动申请与无日志静默续签工具[cite: 1, 2] | `0700 (root:root)` |
| **自动化运维脚本** | `/usr/local/etc/xray-script/` | 存放 `update-dat.sh` 与 `hysteria-cert-restart.sh`[cite: 1, 2] | `0755 (root:root)`[cite: 1, 2] |
| **系统日志限额策略** | `/etc/systemd/journald.conf.d/99-prophet.conf` | Systemd 日志 100MB 熔断限额与 7 天保留策略[cite: 1, 2] | `0644 (root:root)` |
| **内核网络优化配置** | `/etc/sysctl.d/99-custom.conf` (Debian 13+)<br>`/etc/sysctl.conf` (其他发行版) | TCP BBR 拥塞控制与 FQ 队列调度优化参数[cite: 1, 2] | `0644 (root:root)` |
| **Nftables 防火墙** | `/etc/nftables.d/xray.nft` (仅 v3.0) | 独立维护的 `inet xray_gateway` 网络端口规则快照[cite: 1] | `0600 (root:root)` |

---

## 二、 服务控制与常用运维命令大全

系统所有底层组件均由原生 Systemd 纳管，日常管理可直接调用以下标准指令：

### 1. 服务启停、重载与状态查看
```bash
# -------------------- Xray Core --------------------
systemctl restart xray              # 重启 Xray 核心进程
systemctl reload xray 2>/dev/null || systemctl restart xray
systemctl stop xray                 # 停止 Xray 服务
systemctl status xray               # 查看 Xray 运行状态与最近日志

# -------------------- Nginx 伪装网关 (模式 1/3) --------------------
systemctl reload nginx              # 平滑重载 Nginx 配置 (零停机)
systemctl restart nginx             # 完整重启 Nginx 服务
systemctl status nginx              # 查看 Nginx 运行状态
nginx -t                            # 校验当前 Nginx 配置文件语法是否合法

# -------------------- Hysteria 2 (模式 3) --------------------
systemctl restart hysteria-server   # 重启 Hysteria 2 UDP 服务
systemctl stop hysteria-server      # 停止 Hysteria 2 服务
systemctl status hysteria-server    # 查看 Hysteria 2 连接与端口状态

# -------------------- 证书热重载事件监控 (模式 3) --------------------
systemctl status hysteria-cert-watcher.path      # 查看内核文件路径监听单元状态
systemctl restart hysteria-cert-watcher.path     # 重启文件监听事件单元
```

### 2. 实时日志排查 (基于 journalctl)
```bash
journalctl -u xray -f               # 实时追踪 Xray 运行日志与错误输出
journalctl -u nginx -f              # 实时追踪 Nginx 访问与握手日志
journalctl -u hysteria-server -f    # 实时追踪 Hysteria 2 QUIC 握手与连接日志
journalctl -u hysteria-cert-watcher.service -e   # 查看证书更新自动重载执行记录
```

### 3. 手动触发自动化维护任务
```bash
# 手动触发分流规则原子更新
bash /usr/local/etc/xray-script/update-dat.sh
# 或通过 Systemd 触发
systemctl start xray-dat.service

# 手动触发证书强制续签检查
/root/.acme.sh/acme.sh --cron --home /root/.acme.sh
# 或通过 Systemd 触发
systemctl start xray-acme.service
```

---

## 三、 自动化任务触发时间与调度规划

脚本淘汰了不可靠的传统 Crontab 计划任务，全面引入 **Systemd Timer 高精度定时器**，具备原生持久化追踪（`Persistent=true`，关机错过开机立即补跑）与防碰撞随机延迟（`RandomizedDelaySec`）[cite: 1, 2]：

| 定时器单元名称 | 关联执行服务 | 触发调度周期与具体时间 | 随机延迟 (Jitter) | 任务行为与逻辑 |
| :--- | :--- | :--- | :--- | :--- |
| **`xray-acme.timer`**[cite: 1, 2] | `xray-acme.service`[cite: 1, 2] | **每天 02:00:00 (Asia/Singapore)**[cite: 1, 2]<br>`OnCalendar=*-*-* 02:00:00`[cite: 1, 2] | **5 分钟**[cite: 1, 2]<br>(`RandomizedDelaySec=5m`)[cite: 1, 2] | 调用 acme.sh 扫描服务器内所有证书，临期 30 天内自动触发续签并平滑重载 Nginx[cite: 1, 2]。 |
| **`xray-dat.timer`**[cite: 1, 2] | `xray-dat.service`[cite: 1, 2] | **每周一 03:00:00 (Asia/Singapore)**[cite: 1, 2]<br>`OnCalendar=Mon *-*-* 03:00:00`[cite: 1, 2] | **10 分钟**[cite: 1, 2]<br>(`RandomizedDelaySec=10m`)[cite: 1, 2] | 调用 `update-dat.sh` 从 Loyalsoldier 上游拉取最新的中国大陆 IP/域名分流规则库[cite: 1, 2]。 |
| **`hysteria-cert-watcher.path`**[cite: 1, 2] | `hysteria-cert-watcher.service`[cite: 1, 2] | **实时内核事件触发**<br>(`PathChanged` 监听证书和密钥)[cite: 1, 2] | **防抖排他锁 (10s 轮询)**[cite: 1, 2] | 当监测到 `.cer` 或 `.key` 文件落盘变动时，校验完整性并毫秒级重载 Nginx 与 Hysteria2[cite: 1, 2]。 |

> **时区统一声明**：定时器显式绑定 `Asia/Singapore`（与北京时间 UTC+8 保持绝对同步），避免因 VPS 采用 UTC、EST 等各异的系统时区导致任务在业务高峰期意外触发[cite: 1, 2]。

---

## 四、 路由分流规则库原子化热更新机制剖析

位于 `/usr/local/etc/xray-script/update-dat.sh` 的分流规则维护脚本采用了工业级**原子写入与防雪崩三重防护体系**，彻底解决了网络中断导致空文件覆盖、服务频繁震荡及全球并发惊群效应[cite: 1, 2]：

```text
               [ 触发更新: update-dat.sh ]
                            │
              获取非阻塞排他文件锁 (flock -n 9) ──► [失败] ──► 退出 (防止并发冲突)
                            │ [成功]
             下载最新规则至临时文件 (${file}.new)
                            │
               [ 校验 1: 下载状态与文件大小 ]
               体积是否 >= 500KB (512,000 bytes) ?
                  ├── 否 ──► 判定源站异常/下载截断 ──► 清理临时文件并退出
                  └── 是 ──► 进入下一步
                            │
               [ 校验 2: 二进制哈希内容比对 ]
               cmp -s "${file}.new" "${file}" ?
                  ├── 一致 ──► 规则无更新 ──► 清理临时文件，结束 (不重启服务)
                  └── 变更 ──► 进入原子替换
                            │
               [ 原子替换: POSIX VFS mv -f ]
               利用 Linux 内核原子重命名覆盖生产文件
                            │
               [ 服务热载: 条件触发 ]
               标记 changed=1 ──► 执行 systemctl restart xray ──► 释放文件锁
```

### 核心实现原理：
1. **进程级防并发锁**：`exec 9> /var/lock/xray-dat.lock; flock -n 9 || exit 0`，保证同一时刻仅有一个更新进程在运行[cite: 1, 2]。
2. **截断熔断保护 (`f_size >= 512000`)**：GitHub Release 在遭遇限流或网络震荡时可能返回几百字节的 404 HTML。脚本强制判断新规则体积必须大于 500KB，避免损坏的空文件替换生产路由库导致 Xray 启动崩溃[cite: 1, 2]。
3. **内容差量静默比对 (`cmp -s`)**：采用字节级比对。如果远程规则与本地规则完全一致，脚本直接销毁临时文件，**完全不触发服务重启**，保障代理连接长久在线[cite: 1, 2]。
4. **POSIX 原生原子覆盖 (`mv -f`)**：基于 Linux 文件系统 Inode 重命名机制，替换瞬间对 Xray 读操作无任何阻塞，杜绝中间态[cite: 1, 2]。

---

## 五、 脚本全维度对比矩阵 (v3.0.sh vs v3.1.sh)

两个脚本均具备完整的协议功能与运行时安全底座，核心区别在于**主机网络层是否闭环接管防火墙**[cite: 1, 2]：

| 对比维度 / 机制特征 | `v3.0.sh` (Firewall 深度集成版)[cite: 1] | `v3.1.sh` (Pure 纯净解耦版)[cite: 2] |
| :--- | :--- | :--- |
| **设计定位** | **自带防火墙闭环管理**，适合直接暴露公网的物理裸机、独立服务器或无上层安全组的普通 VPS[cite: 1]。 | **网络控制层完全解耦**，面向由云控制台外部安全组（Security Group）统一接管的网络实例[cite: 2]。 |
| **版本标识符** | `v3.0-Industrial-Firewall`[cite: 1] | `v3.1-Industrial-Pure`[cite: 2] |
| **上下文状态追踪** | 包含 `[old_port]`（旧端口）与 `[fw_backend]`（防火墙后端）[cite: 1]。 | 移除所有防火墙相关状态，上下文变量精简至纯业务层[cite: 2]。 |
| **防火墙自动探测** | 自动感知 `ufw`、`firewalld`、`nftables` 与 `iptables/ip6tables` 四大后端[cite: 1]。 | ❌ 完全不执行任何防火墙环境感知与判断[cite: 2]。 |
| **端口规则精准注入** | • 依据部署模式动态放行业务 TCP 端口[cite: 1]；<br>• 模式 3 自动放行 UDP，模式 1/2 封堵对应 UDP[cite: 1]；<br>• 模式 1/3 放行 80 TCP，模式 2 自动回收 80 TCP[cite: 1]。 | ❌ 宿主机完全不注入任何网络规则，交由系统原生策略或上层安全组放行[cite: 2]。 |
| **端口迁移差量回收** | 记录历史端口，更换端口时精准从防火墙中注销旧端口，杜绝遗留无用暴露面[cite: 1]。 | ❌ 无旧端口状态追踪逻辑[cite: 2]。 |
| **Nftables 高级隔离** | 建立专属 `inet xray_gateway` 表，不污染系统原有过滤链，卸载时整表销毁[cite: 1]。 | ❌ 不调用 `nft` 工具，不写入任何持久化规则[cite: 2]。 |
| **Iptables 双栈安全** | 同时注入 `iptables` 与 `ip6tables`，卸载时使用 `while -D` 循环彻底清退规则[cite: 1]。 | ❌ 不触碰系统的 IPv4/IPv6 过滤链[cite: 2]。 |
| **推荐适用场景** | 搬瓦工、RackNerd、Vultr、OVH 等无网页安全组防护的传统 VPS 宿主机[cite: 1]。 | AWS EC2、Google Cloud (GCP)、阿里云、腾讯云、Oracle Cloud 等具备外部安全组的公有云平台[cite: 2]。 |

---

## 六、 源码架构与核心模块逐层详解

### 1. LAYER 1: 运行时基座与进程互斥安全体系
* **Root 权限与执行上下文判定**：检测 `$EUID -ne 0` 时拦截[cite: 1, 2]。利用 `[[ "${BASH_SOURCE[0]}" != "${0}" ]]` 严谨识别当前是直接执行还是 `source` 加载：若是 `source` 加载则使用 `return 1` 安全退出，防止使用 `exit` 误杀用户的 SSH 父会话终端[cite: 1, 2]。
* **追加模式排他锁 (`exec 9>>"$LOCK_FILE"`)**：舍弃易发生竞态穿透的覆写截断模式（`>`），使用追加模式（`>>`）挂载 `flock -n 9`[cite: 1, 2]。并发启动时未抢到锁的进程不会截断清空已有锁文件，保障先导进程 PID 绝不丢失[cite: 1, 2]。
* **POSIX 信号级联安全与反递归 Trap**：绑定 `EXIT`、`INT (130)`、`TERM (143)` 信号[cite: 1, 2]。在 `safe_terminate` 清理资源时，首选解绑所有 Trap（`trap - EXIT SIGHUP SIGINT SIGTERM`），彻底阻断反递归调用的死循环[cite: 1, 2]。
* **全局临时垃圾栈自清理 (`CLEANUP_LIST`)**：所有运行时生成的临时文件与解压路径全部压入栈数组，脚本无论是正常退出还是异常中断，均能保证 100% 自动清空临时垃圾[cite: 1, 2]。
* **双向域名拓扑智能探测 (`get_domain_info`)**：通过统计点号数量（`tr -cd '.' | wc -c`）识别主域或二级子域，结合 `getent ahostsv4/ahostsv6` 智能探测 `www` 记录解析情况，自适应合流申请双域名证书并配置 Nginx 匹配链[cite: 1, 2]。

### 2. LAYER 2: 基础设施策略与防火墙自适应引擎
* **Debian 13+ 内核路径模块化自适应 (`sys_setup_bbr`)**：
  * 读取 `/etc/os-release` 获取主版本号[cite: 1, 2]；
  * 若为 **Debian 13 (Trixie)** 及以上，清理旧残留并转入 `/etc/sysctl.d/99-custom.conf` 模块化路径，调用 `sysctl --system` 实现全量原子生效[cite: 1, 2]；
  * 低版本系统保持对 `/etc/sysctl.conf` 与 `sysctl -p` 的平滑兼容，配置 `fq` 队列与 `bbr` 控制算法[cite: 1, 2]。
* **Systemd 日志配额熔断 (`sys_setup_journald`)**：
  强制在 `/etc/systemd/journald.conf.d/99-prophet.conf` 注入 `SystemMaxUse=100M`、`MaxRetentionSec=7day` 并关闭向 `/var/log/syslog` 的冗余转发，杜绝日志膨胀耗尽磁盘空间[cite: 1, 2]。
* **多后端自适应防火墙引擎 (`v3.0.sh` 独占)**：
  * **UFW**：自动识别并调用 `ufw allow/delete`[cite: 1]。
  * **Firewalld**：调用 `firewall-cmd --permanent` 并在操作后自动执行 `--reload`[cite: 1]。
  * **Nftables**：建立独立的 `inet xray_gateway` 专属表和规则链，规则单独持久化保存至 `/etc/nftables.d/xray.nft`，并在 `/etc/nftables.conf` 中追加引用包含，不污染主防火墙体系[cite: 1]。
  * **Iptables**：同时操作 IPv4 与 IPv6 规则链，卸载时使用 `while iptables -D ...` 循环保证脏规则完全排空[cite: 1]。

### 3. LAYER 3: 业务组件生命周期驱动
* **ACME 证书驱动 (`driver_cert_install`)**：
  * 优先校验 `/etc/nginx/ssl/${domain}_ecc.cer` 是否存在，存在则跳过申请直接复用，杜绝触发 Let's Encrypt 频次限额[cite: 1, 2]；
  * 支持 **DNS API**（Cloudflare、Namesilo）与 **HTTP Webroot** 模式[cite: 1, 2]；
  * 固化 `LE_NO_LOG='1'`、`DEBUG='0'` 至 `account.conf`，阻断调试日志写入[cite: 1, 2]；
  * 自动注入 `xray-acme.timer`，实现每天 02:00（SGT）静默巡检自动续期[cite: 1, 2]。
* **Nginx 伪装网关驱动 (`driver_nginx_install`)**：
  * **动态语法探针**：生成 `/tmp/ngx_probe.conf` 探针检测 `ssl_reject_handshake on;`（开启握手阻断）与 `http2 on;`（现代语法兼容），防止版本过低或过高导致配置解析崩溃[cite: 1, 2]；
  * **三重虚拟主机划分**：
    1. 8443 端口：挂载真实证书与 3D 伪装站点，作为 Xray Reality 的合法回落目的地[cite: 1, 2]；未通过合规 SNI 访问时直接断开握手[cite: 1, 2]；
    2. 80 端口：保留 `^~ /.well-known/acme-challenge/` 供证书自动续签，其他请求强制 301 重定向至 HTTPS[cite: 1, 2]；
    3. 8444 端口（模式 3）：提供明文 HTTP 站点，作为 Hysteria 2 的伪装代理回落目标[cite: 1, 2]。
  * **下载部署 3D 伪装模板**：拉取真实 3D 网页模板覆盖 `/var/www/html`，若下载失败则自动生成规范的 403 Forbidden 兜底网页[cite: 1, 2]。
* **Xray 代理引擎驱动 (`driver_xray_install` / `driver_xray_configure`)**：
  * **凭据持久化防丢算法**：优先调用 `jq` 读取旧配置的 UUID、Private Key 与 Short ID；若存在私钥则通过 `x25519 -i` 反推公钥，重装完全不破坏客户端已有配置[cite: 1, 2]；
  * **X25519 数学推演闭环校验**：初次生成密钥时，在候选密钥池中通过反向推导严格校验公私钥匹配性，彻底杜绝正则提取错位隐患[cite: 1, 2]；
  * **DNS 引导自解析防死锁 (Bootstrap Hosts)**：显式静态绑定 `dns.cloudflare.com` 与 `dns.google` 的真实 IP 地址，彻底消除 DoH 启动时的递归依赖解析死锁[cite: 1, 2]；
  * **安全分流规则集成**：预设内网私有地址、BT 种子协议、常见广告域名以及中国大陆 IP/域名的拦截黑洞规则[cite: 1, 2]。
* **Hysteria 2 双栈协议驱动 (`driver_hysteria_install`)**：
  * 本地生成 16 字节高强度随机认证密码，监听与 Xray 相同的业务端口（UDP 协议）[cite: 1, 2]；
  * 伪装回落直连本地 Nginx 8444 端口，实现与常见 Web 服务的拟真度协同[cite: 1, 2]；
  * 注册 `hysteria-cert-watcher.path`，证书落盘时自动轮询校验完整性并完成热重启[cite: 1, 2]。

### 4. LAYER 4: 业务交互编排与状态机对齐
* **双栈 IP 与域名解析智能校验**：结合 Cloudflare DoH API 与系统底层的 `getent`，智能检测域名的 A/AAAA 记录是否已成功解析至本机公网 IP[cite: 1, 2]。
* **端口占用主动防御扫描**：利用 `ss` 工具深度扫描 TCP 与 UDP，禁止用户选择 80、8443、8444 等内部保留回落端口，规避冲突隐患[cite: 1, 2]。
* **状态机对齐与异构资产物理擦除 (`workflow_align_modes`)**：
  * 退出模式 3：物理删除 Hysteria 2 二进制、配置及证书监听服务，释放 UDP 端口[cite: 1, 2]；
  * 切换到模式 2：物理注销证书定时器，彻底 `purge` 卸载 Nginx 与 Socat 软件包，删除 Web 网站与证书资产，使系统回退至极简状态[cite: 1, 2]。
* **RFC 3986 标准 URI 规范化输出**：自动识别 IPv4 与 IPv6，对 IPv6 格式自适应包装 `[...]` 定界符并生成分享链接与终端控制台二维码[cite: 1, 2]。

### 5. LAYER 5: CLI 调度入口与菜单驱动
* 提供模块化的控制台文本交互菜单，清晰支持 **部署脚本**、**卸载服务**、**查看定时任务及证书状态** 与 **安全退出**[cite: 1, 2]。
* **焦土式与温和式卸载双选**：卸载时提供确认选项，既可仅回收代理业务服务，也可彻底 `purge` 底层安装的依赖包（Nginx、Socat、JQ 等），还原系统的纯净底座[cite: 1, 2]。

---

## 七、 常见故障排查手册 (Troubleshooting)

### 1. 域名解析校验提示 `[WARN] 解析 IP 与本机 IP 不匹配`
* **故障诱因**：域名在 Cloudflare 等解析商处开启了 CDN 代理加速（即“橙色小云朵”处于开启状态），对外暴露的均为 Cloudflare Anycast IP，而非 VPS 的真实公网源站 IP[cite: 1, 2]。
* **处置方案**：登录 DNS 控制台，将对应解析记录调整为 **仅限 DNS (DNS only / 灰色小云朵)**，等待 1-2 分钟缓存刷新后重新执行脚本。

### 2. Nginx 启动报错 `bind() to 0.0.0.0:80 failed (Address already in use)`
* **故障诱因**：宿主机原有的 Apache2、Caddy 或旧证书申请程序霸占了 80 端口。
* **处置方案**：
  ```bash
  ss -tulpn | grep :80                # 定位占用 80 端口的进程与 PID
  systemctl stop apache2 2>/dev/null  # 若为 Apache2，执行停止并禁用
  systemctl disable apache2 2>/dev/null
  systemctl restart nginx             # 重新启动 Nginx
  ```

### 3. Hysteria 2 (模式 3) 客户端无法建立握手连接
* **故障诱因**：云厂商控制台的安全组未放行对应端口的 **UDP** 协议；或本地防火墙拦截。
* **处置方案**：
  1. 登录公有云控制台（如 AWS、阿里云、腾讯云、甲骨文），检查安全组入站规则，显式添加入站协议为 `UDP` 的业务端口；
  2. 若运行 `v3.0.sh`，在终端执行 `nft list chain inet xray_gateway input` 或 `iptables -vnL INPUT` 确认对应端口的 UDP 规则已放行且有数据包通过计数[cite: 1]；
  3. 执行 `journalctl -u hysteria-server -e` 查阅服务端最新日志，确认是否已收到客户端的 QUIC 握手请求。

### 4. 客户端连接报告 `certificate verify failed / TLS handshake error`
* **故障诱因**：
  * **模式 1/3**：证书未签发成功或初次申请时错误选用了测试环境（Staging）[cite: 1, 2]。执行 `/root/.acme.sh/acme.sh --list` 确认证书颁发 CA 是否为生产权威 CA[cite: 1, 2]；
  * **模式 2**：伪装域名（SNI）在国内被运营商路由丢包阻断，或该伪装站点不支持 TLS 1.3 / HTTP/2 握手协商。可在服务器端执行 `curl -Iv https://<伪装SNI>` 检验目标站点的连通性与协议参数。
