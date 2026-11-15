#!/bin/bash
# ==============================================================================
# Xray Reality Automation Engine (Industrial Architecture Edition - v3.2-Industrial-Pure)
# Architecture: VLESS + XTLS-Vision + Reality + Nginx Reverse Proxy + Hysteria2
# ==============================================================================

# ------------------------------------------------------------------------------
# LAYER 1: 运行时基座、全局上下文与安全底座 (Runtime Toolkit & Core Safety)
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo -e "\e[31m[ERROR] 权限不足：执行本脚本需要 Root 权限。\e[0m"
    echo -e "\e[33m请执行 'sudo -i' 或 'su -' 获取 Root 权限后重新运行。\e[0m"
    [[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 1 2>/dev/null || exit 1
fi

umask 022

readonly SCRIPT_VERSION="v3.2-Industrial-Pure"
readonly LOG_FILE="/dev/null"
readonly LOCK_FILE="/var/run/xray_script.lock"
readonly SCRIPT_DIR="/usr/local/etc/xray-script"
readonly MANAGED_DOMAIN_FILE="$SCRIPT_DIR/managed_domain"
readonly BACKUP_DIR="$SCRIPT_DIR/backup"
readonly XRAY_CONF_DIR="/usr/local/etc/xray"
readonly XRAY_SHARE_DIR="/usr/local/share/xray"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONFIG="$XRAY_CONF_DIR/config.json"
readonly HY2_CONF_DIR="/etc/hysteria"
readonly HY2_CONFIG="$HY2_CONF_DIR/config.yaml"
readonly HY2_BIN="/usr/local/bin/hysteria"
readonly ACME_BIN="/root/.acme.sh/acme.sh"
readonly ACME_HOOK_SCRIPT="$SCRIPT_DIR/acme-webroot-hook.sh"
readonly NGINX_ACME_HOOK_DIR="/etc/nginx/acme-hook"
readonly WEBROOT_SITE_DIR="/var/www/xray-site"
readonly WEBROOT_ACME_DIR="/var/www/acme-webroot"

readonly C_RED="\e[31m"
readonly C_GREEN="\e[32m"
readonly C_YELLOW="\e[33m"
readonly C_BLUE="\e[36m"
readonly C_RESET="\e[0m"
readonly C_BOLD="\e[1m"

export AUTO_UPGRADE='0'
export LE_NO_LOG=1
export LE_LOG_FILE='/dev/null'
export DEBUG=0
export DEBIAN_FRONTEND="noninteractive"
export APT_LISTCHANGES_FRONTEND="none"

declare -gA CTX=()
reset_context() {
    CTX=(
        [mode]="1"
        [domain]=""
        [public_sni]="www.apple.com"
        [dns_api]=""
        [cf_token]=""
        [cf_zone_id]=""
        [namesilo_key]=""
        [cert_mode]="--server letsencrypt"
        [port]="443"
        [reuse_config]="1"
        [hy2_pass]=""
        [ipv4]=""
        [ipv6]=""
        [uuid]=""
        [pub_key]=""
        [priv_key]=""
        [short_id]=""
        [arch]=""
    )
}
reset_context

CLEANUP_LIST=()
LOCK_ACQUIRED=0

log_info() { echo -e "${C_BLUE}[INFO]${C_RESET} $1" | tee -a "$LOG_FILE"; }
log_ok()   { echo -e "${C_GREEN}[OK]${C_RESET} $1" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $1" | tee -a "$LOG_FILE"; }
log_err()  { echo -e "${C_RED}[ERROR]${C_RESET} $1" | tee -a "$LOG_FILE"; safe_terminate 1; }

cleanup_resources() {
    if [[ $LOCK_ACQUIRED -eq 1 ]]; then
        # 绝不删除 $LOCK_FILE，仅解锁并关闭 FD 9，防止新旧 inode 竞态漏洞
        flock -u 9 2>/dev/null || true
    fi
    exec 9>&- 2>/dev/null || true
    [[ ${#CLEANUP_LIST[@]} -gt 0 ]] && rm -rf "${CLEANUP_LIST[@]}" 2>/dev/null || true
}

safe_terminate() {
    local code=${1:-0}
    cleanup_resources
    trap - EXIT SIGHUP SIGINT SIGTERM 2>/dev/null
    [[ "${BASH_SOURCE[0]}" != "${0}" ]] && return "$code" 2>/dev/null || exit "$code"
}

# 进程并发互斥锁（基于固定 inode 的 fcntl/flock 锁）
exec 9>>"$LOCK_FILE"
if ! flock -n 9; then
    ACTIVE_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    echo -e "${C_RED}[ERROR] 检测到已有安装程序正在运行 (PID: ${ACTIVE_PID:-未知})，请勿重复执行。${C_RESET}"
    safe_terminate 1
fi
LOCK_ACQUIRED=1
echo $$ > "$LOCK_FILE"

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap 'cleanup_resources' EXIT
    trap 'cleanup_resources; echo -e "\n${C_YELLOW}用户已手动中断。${C_RESET}"; exit 130' INT
    trap 'cleanup_resources; exit 143' TERM
fi

fetch_asset() {
    local url="$1"
    local dest="$2"
    local timeout="${3:-120}"
    curl -fL -# --connect-timeout 10 --retry 5 --retry-delay 3 --retry-connrefused -m "$timeout" -o "$dest" "$url"
}

is_valid_domain() {
    local d="$1"
    [[ -n "$d" && ${#d} -le 253 ]] || return 1
    [[ "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

# ------------------------------------------------------------------------------
# LAYER 2: 基础设施策略 (Infrastructure Strategy)
# ------------------------------------------------------------------------------
unit_purge() {
    local units=("$@")
    [[ ${#units[@]} -eq 0 ]] && return 0
    systemctl stop "${units[@]}" >/dev/null 2>&1 || true
    systemctl disable "${units[@]}" >/dev/null 2>&1 || true
    for u in "${units[@]}"; do
        rm -f "/etc/systemd/system/$u" "/lib/systemd/system/$u"
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
    for u in "${units[@]}"; do
        systemctl reset-failed "$u" >/dev/null 2>&1 || true
    done
}

sys_setup_journald() {
    log_info "正在配置系统环境和日志策略..."
    mkdir -p /etc/systemd/journald.conf.d/
    cat > /etc/systemd/journald.conf.d/99-prophet.conf <<'EOF'
[Journal]
SystemMaxUse=100M
MaxRetentionSec=7day
ForwardToSyslog=no
EOF
    systemctl restart systemd-journald >/dev/null 2>&1 || true
}

sys_setup_bbr() {
    log_info "正在检查网络加速 (BBR) 与双栈套接字策略..."
    local bbr_conf_file="/etc/sysctl.conf"
    local need_migrate=0

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        local major_version="${VERSION_ID%%.*}"
        if [[ "$ID" == "debian" && "$major_version" =~ ^[0-9]+$ && "$major_version" -ge 11 ]] || \
           [[ "$ID" == "ubuntu" && "$major_version" =~ ^[0-9]+$ && "$major_version" -ge 22 ]]; then
            bbr_conf_file="/etc/sysctl.d/99-custom.conf"
            need_migrate=1
        fi
        log_info "当前系统信息: ${PRETTY_NAME:-Linux} | 目标配置路径: $bbr_conf_file"
    fi

    # 若系统启用了 IPv6，确保 bindv6only=0 以保障双栈通配监听正常兼容 IPv4
    if [[ -f /proc/sys/net/ipv6/bindv6only ]]; then
        local v6_disabled
        v6_disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)
        if [[ "$v6_disabled" == "0" ]]; then
            sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1 || true
        fi
    fi

    local file_has_bbr=0
    if [[ -s "$bbr_conf_file" ]] && grep -q "tcp_congestion_control=bbr" "$bbr_conf_file"; then
        file_has_bbr=1
    fi

    local kernel_has_bbr=0
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        kernel_has_bbr=1
    fi

    if [[ $file_has_bbr -eq 1 && $kernel_has_bbr -eq 1 ]]; then
        log_ok "网络加速 (BBR) 已处于开启状态且配置文件完整，跳过配置。"
        return 0
    fi

    if [[ $need_migrate -eq 1 ]]; then
        mkdir -p /etc/sysctl.d
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null || true
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
    fi

    touch "$bbr_conf_file"
    sed -i '/net.core.default_qdisc/d' "$bbr_conf_file" 2>/dev/null || true
    sed -i '/net.ipv4.tcp_congestion_control/d' "$bbr_conf_file" 2>/dev/null || true
    echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" >> "$bbr_conf_file"

    if [[ "$bbr_conf_file" == "/etc/sysctl.conf" ]]; then
        sysctl -p >/dev/null 2>&1 || true
    else
        sysctl --system >/dev/null 2>&1 || true
    fi

    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        log_ok "BBR 网络加速已成功开启并写入配置。"
    else
        log_warn "BBR 参数已写入配置，但当前内核未能即时激活 BBR（可能受限于容器虚拟化内核）。"
    fi
}

sys_clean_apt_cache() {
    log_info "正在清理安装过程中产生的系统垃圾..."
    apt-get -o DPkg::Lock::Timeout=60 autoremove -yqq >/dev/null 2>&1 || true
    apt-get -o DPkg::Lock::Timeout=60 clean -yqq >/dev/null 2>&1 || true
    log_ok "系统垃圾清理完毕。"
}

# ------------------------------------------------------------------------------
# LAYER 3: 业务组件驱动 (Component Lifecycle Drivers)
# ------------------------------------------------------------------------------

# --- [Driver: 加密学证书健康与匹配度校验] ---
verify_cert_health() {
    local cert_file="$1"
    local key_file="$2"
    local expected_domain="$3"
    local min_valid_sec="${4:-2592000}"

    [[ -s "$cert_file" && -s "$key_file" ]] || return 1

    # 1. 校验证书有效性及剩余有效期（默认至少大于 30 天 / 2592000 秒）
    openssl x509 -in "$cert_file" -noout -checkend "$min_valid_sec" >/dev/null 2>&1 || return 1

    # 2. 校验证书公钥与私钥公钥严格匹配
    local cert_pub key_pub
    cert_pub=$(openssl x509 -in "$cert_file" -noout -pubkey 2>/dev/null)
    key_pub=$(openssl pkey -in "$key_file" -pubout 2>/dev/null)
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || return 1

    # 3. 校验 SAN 或 Subject 包含当前目标域名
    if [[ -n "$expected_domain" ]]; then
        local san_text subj_text
        san_text=$(openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null || true)
        subj_text=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null || true)
        if ! echo "$san_text $subj_text" | grep -Fqi "$expected_domain"; then
            return 1
        fi
    fi

    return 0
}

# --- [Driver: Nginx 基础配置初始化，备份原厂配置以实现资产隔离] ---
driver_nginx_write_main_conf() {
    mkdir -p /etc/nginx/conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled "$NGINX_ACME_HOOK_DIR" /var/log/nginx "$WEBROOT_SITE_DIR" "$WEBROOT_ACME_DIR"
    chmod 755 "$WEBROOT_SITE_DIR" "$WEBROOT_ACME_DIR" "$NGINX_ACME_HOOK_DIR"

    # 首次接管前备份系统原始 nginx.conf，避免多业务环境下永久丢失自定义配置
    if [[ -f /etc/nginx/nginx.conf && ! -f /etc/nginx/nginx.conf.xray-orig ]]; then
        cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.xray-orig 2>/dev/null || true
    fi

    cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log error;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    server_tokens off;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;
    access_log off;
    gzip on;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    # 若存在系统默认占位站点，仅备份并移除激活链接（保留 sites-available/default 原文件）
    if [[ -L /etc/nginx/sites-enabled/default ]]; then
        rm -f /etc/nginx/sites-enabled/default
    fi
}

# --- [Driver: Webroot 动态按需验证钩子脚本生成（使用独立隔离目录）] ---
driver_cert_prepare_webroot_hook() {
    mkdir -p "$SCRIPT_DIR" "$NGINX_ACME_HOOK_DIR" "$WEBROOT_ACME_DIR"
    rm -f "$NGINX_ACME_HOOK_DIR"/*.conf 2>/dev/null || true
    cat > "$ACME_HOOK_SCRIPT" <<EOF
#!/bin/bash
umask 022
ACTION="\${1:-}"
HOOK_DIR="$NGINX_ACME_HOOK_DIR"
HOOK_CONF="\$HOOK_DIR/acme.conf"
WEBROOT_DIR="$WEBROOT_ACME_DIR"

case "\$ACTION" in
    open)
        mkdir -p "\$HOOK_DIR" "\$WEBROOT_DIR/.well-known/acme-challenge"
        chmod 755 "\$WEBROOT_DIR" "\$WEBROOT_DIR/.well-known" "\$WEBROOT_DIR/.well-known/acme-challenge" 2>/dev/null || true
        chown -R www-data:www-data "\$WEBROOT_DIR/.well-known" 2>/dev/null || true
        cat > "\$HOOK_CONF" <<CONF
location ^~ /.well-known/acme-challenge/ {
    default_type "text/plain";
    root $WEBROOT_ACME_DIR;
}
CONF
        if nginx -t >/dev/null 2>&1; then
            if systemctl is-active --quiet nginx; then
                systemctl reload nginx >/dev/null 2>&1 || true
            else
                systemctl start nginx >/dev/null 2>&1 || true
            fi
            sleep 1
        fi
        ;;
    close)
        if [[ -f "\$HOOK_CONF" || -d "\$WEBROOT_DIR/.well-known" ]]; then
            rm -f "\$HOOK_CONF" 2>/dev/null || true
            rm -rf "\$WEBROOT_DIR/.well-known" 2>/dev/null || true
            if nginx -t >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
                systemctl reload nginx >/dev/null 2>&1 || true
                sleep 1
            fi
        fi
        ;;
esac
exit 0
EOF
    chmod 755 "$ACME_HOOK_SCRIPT"
}

# --- [Driver: ACME 证书管理 (单域名托管隔离架构)] ---
driver_cert_install() {
    local domain="${CTX[domain]}"
    local api="${CTX[dns_api]}"
    local cert_file="/etc/nginx/ssl/${domain}_ecc.cer"
    local key_file="/etc/nginx/ssl/${domain}_ecc.key"
    local acme_domain_conf="/root/.acme.sh/${domain}_ecc/${domain}.conf"
    local reload_cmd="if [ -L /etc/nginx/sites-enabled/xray ] && [ -s /etc/nginx/sites-enabled/xray ]; then nginx -t && if systemctl is-active --quiet nginx; then systemctl reload nginx; else systemctl start nginx; fi; fi"

    mkdir -p "$SCRIPT_DIR" /etc/nginx/ssl
    # 仅在手动执行部署脚本阶段先卸载本脚本站点软链接，交由后续 driver_nginx_install 重新生成并严格校验拉起
    rm -f /etc/nginx/sites-enabled/xray

    if [[ "$api" == "webroot" ]]; then
        driver_cert_prepare_webroot_hook
    else
        rm -f "$ACME_HOOK_SCRIPT" 2>/dev/null || true
        rm -rf "$NGINX_ACME_HOOK_DIR" "$WEBROOT_ACME_DIR" 2>/dev/null || true
    fi

    local pre_hook_cmd="$ACME_HOOK_SCRIPT open"
    local post_hook_cmd="$ACME_HOOK_SCRIPT close"
    local pre_b64="__ACME_BASE64__START_$(printf '%s' "$pre_hook_cmd" | base64 | tr -d '\r\n')__ACME_BASE64__END_"
    local post_b64="__ACME_BASE64__START_$(printf '%s' "$post_hook_cmd" | base64 | tr -d '\r\n')__ACME_BASE64__END_"

    # 资产隔离：仅清理本脚本历史登记托管过的旧域名资产，绝不误删服务器上其他业务的证书
    if [[ -s "$MANAGED_DOMAIN_FILE" ]]; then
        local prev_domain
        prev_domain=$(tr -d '[:space:]' < "$MANAGED_DOMAIN_FILE")
        if [[ -n "$prev_domain" && "$prev_domain" != "$domain" ]]; then
            log_info "检测到托管域名变更 ($prev_domain -> $domain)，正在精准清理本脚本旧域名证书资产..."
            [[ -x "$ACME_BIN" ]] && "$ACME_BIN" --remove -d "$prev_domain" --ecc >/dev/null 2>&1 || true
            rm -rf "/root/.acme.sh/${prev_domain}_ecc" 2>/dev/null || true
            rm -f "/etc/nginx/ssl/${prev_domain}_ecc.cer" "/etc/nginx/ssl/${prev_domain}_ecc.key" 2>/dev/null || true
        fi
    fi

    if [[ -s "$cert_file" && -s "$key_file" ]]; then
        local cert_issuer
        cert_issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null || true)

        # 检查历史续签方式是否与本次用户选择的验证方式一致
        local method_mismatch=0
        if [[ -s "$acme_domain_conf" ]]; then
            local recorded_webroot
            recorded_webroot=$(grep -E "^Le_Webroot=" "$acme_domain_conf" 2>/dev/null | cut -d= -f2- | tr -d "\"'" || true)
            recorded_webroot="${recorded_webroot%%,*}"
            if [[ "$api" == "webroot" && "$recorded_webroot" != "$WEBROOT_ACME_DIR" ]]; then
                method_mismatch=1
            elif [[ "$api" != "webroot" && "$recorded_webroot" != "$api" ]]; then
                method_mismatch=1
            fi
        fi

        if ! verify_cert_health "$cert_file" "$key_file" "$domain" 2592000; then
            log_warn "检测到本地证书剩余有效期不足 30 天、域名不匹配或公私钥不一致，即将清空并重新签发..."
        elif [[ "${CTX[cert_mode]}" != "--staging" ]] && echo "$cert_issuer" | grep -qiE "staging|fake"; then
            log_warn "检测到现有证书为 Staging 测试证书，即将彻底清空旧证书与 CA 授权缓存并重新申请 Production 正式证书..."
        elif [[ ! -x "$ACME_BIN" || ! -s "$acme_domain_conf" ]]; then
            log_warn "检测到本地虽有证书文件，但缺失 ACME 自动续签上下文，即将彻底清空并重新签发绑定..."
        elif [[ $method_mismatch -eq 1 ]]; then
            log_warn "检测到证书验证方式发生变更 (切换为 $api)，即将彻底清空旧证书与 CA 授权缓存并重新验证..."
        else
            # 复用证书时，CF_Token 与 CF_Zone_ID 直接刷新至域名专属 conf，不写入 account.conf
            local acme_conf="/root/.acme.sh/account.conf"
            [[ -f "$acme_conf" ]] && sed -i '/^SAVED_CF_Token=/d; /^SAVED_CF_Zone_ID=/d' "$acme_conf" 2>/dev/null || true

            if [[ "$api" == "dns_cf" ]]; then
                sed -i '/^CF_Token=/d; /^CF_Zone_ID=/d' "$acme_domain_conf" 2>/dev/null || true
                echo "CF_Token='${CTX[cf_token]}'" >> "$acme_domain_conf"
                echo "CF_Zone_ID='${CTX[cf_zone_id]}'" >> "$acme_domain_conf"
            elif [[ "$api" == "dns_namesilo" && -f "$acme_conf" ]]; then
                sed -i '/^SAVED_Namesilo_Key=/d' "$acme_conf" 2>/dev/null || true
                echo "SAVED_Namesilo_Key='${CTX[namesilo_key]}'" >> "$acme_conf"
            fi

            if [[ "$api" == "webroot" ]]; then
                sed -i '/^Le_PreHook=/d; /^Le_PostHook=/d' "$acme_domain_conf" 2>/dev/null || true
                echo "Le_PreHook='$pre_b64'" >> "$acme_domain_conf"
                echo "Le_PostHook='$post_b64'" >> "$acme_domain_conf"
            else
                sed -i '/^Le_PreHook=/d; /^Le_PostHook=/d' "$acme_domain_conf" 2>/dev/null || true
            fi

            "$ACME_BIN" --install-cert -d "$domain" --ecc \
                --key-file "$key_file" \
                --fullchain-file "$cert_file" \
                --reloadcmd "$reload_cmd" >/dev/null 2>&1 || log_err "刷新证书安装路径与重载钩子失败。"

            verify_cert_health "$cert_file" "$key_file" "$domain" 2592000 || log_err "复用证书安装后健康校验未通过。"
            printf '%s\n' "$domain" > "$MANAGED_DOMAIN_FILE"
            log_info "检测到服务器已存在有效且剩余有效期大于 30 天的证书，跳过申请步骤直接复用。"
            return 0
        fi
    fi

    # 未命中复用分支时，仅清理当前目标域名的旧残余与 CA 授权缓存
    [[ -x "$ACME_BIN" ]] && "$ACME_BIN" --remove -d "$domain" --ecc >/dev/null 2>&1 || true
    rm -f "$cert_file" "$key_file" 2>/dev/null || true
    rm -rf "/root/.acme.sh/${domain}_ecc" /root/.acme.sh/ca 2>/dev/null || true
    local force_issue="--force"

    log_info "正在向 Let's Encrypt 申请 TLS 证书 ($domain)..."
    local tmp_acme="/tmp/acme_$(date +%s)"
    CLEANUP_LIST+=("$tmp_acme")
    mkdir -p "$tmp_acme" && cd "$tmp_acme" || log_err "创建临时工作目录失败。"

    if curl -fL -# --connect-timeout 10 --retry 5 --retry-delay 3 --retry-connrefused -m 60 https://get.acme.sh | sh -s email="admin@${domain}" --nocron && [[ -s "$ACME_BIN" ]]; then
        log_ok "证书申请工具 (ACME) 安装成功。"
        "$ACME_BIN" --upgrade --auto-upgrade "$AUTO_UPGRADE" >/dev/null 2>&1 || true
    else
        log_err "证书申请工具安装失败，请检查网络连接。"
    fi

    local issue_rc=0
    if [[ "$api" == "webroot" ]]; then
        driver_nginx_write_main_conf
        local acme_temp_conf="/etc/nginx/sites-enabled/acme_temp"
        CLEANUP_LIST+=("$acme_temp_conf")
        cat > "$acme_temp_conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    include $NGINX_ACME_HOOK_DIR/*.conf;
    location / { return 404; }
}
EOF
        if ! systemctl restart nginx >/dev/null 2>&1; then
            nginx -t 2>&1 || true
            log_err "Nginx 临时验证服务启动失败，请检查 80 端口占用或 Nginx 环境。"
        fi
        "$ACME_BIN" --issue -d "$domain" --webroot "$WEBROOT_ACME_DIR" --keylength ec-256 \
            --pre-hook "$pre_hook_cmd" \
            --post-hook "$post_hook_cmd" \
            ${CTX[cert_mode]} $force_issue || issue_rc=$?
        "$ACME_HOOK_SCRIPT" close >/dev/null 2>&1 || true
        rm -f "$acme_temp_conf"
    else
        "$ACME_BIN" --issue --dns "$api" -d "$domain" --keylength ec-256 ${CTX[cert_mode]} $force_issue || issue_rc=$?
    fi

    cd "$HOME" || true
    rm -rf "$tmp_acme" 2>/dev/null || true

    if [[ $issue_rc -ne 0 ]] || [[ ! -s "/root/.acme.sh/${domain}_ecc/fullchain.cer" ]]; then
        log_err "证书签发失败 (ACME 退出码: $issue_rc)，请检查域名解析、80 端口防火墙或服务商 API 密钥。"
    fi

    mkdir -p /etc/nginx/ssl
    "$ACME_BIN" --install-cert -d "$domain" --ecc \
        --key-file "$key_file" \
        --fullchain-file "$cert_file" \
        --reloadcmd "$reload_cmd" || log_err "证书安装或重载钩子执行失败。"

    if verify_cert_health "$cert_file" "$key_file" "$domain" 2592000; then
        printf '%s\n' "$domain" > "$MANAGED_DOMAIN_FILE"
        log_ok "TLS 证书申请成功、加密学校验通过并已部署到 Nginx。"
        local acme_conf="/root/.acme.sh/account.conf"
        if [[ -f "$acme_conf" ]]; then
            sed -i '/^SAVED_CF_Token=/d; /^SAVED_CF_Zone_ID=/d' "$acme_conf" 2>/dev/null || true
            grep -q "LE_NO_LOG" "$acme_conf" || echo "LE_NO_LOG='1'" >> "$acme_conf"
            grep -q "LE_LOG_FILE" "$acme_conf" || echo "LE_LOG_FILE='/dev/null'" >> "$acme_conf"
            grep -q "DEBUG" "$acme_conf" || echo "DEBUG='0'" >> "$acme_conf"
            if [[ "$api" == "dns_namesilo" ]]; then
                sed -i '/^SAVED_Namesilo_Key=/d' "$acme_conf" 2>/dev/null || true
                echo "SAVED_Namesilo_Key='${CTX[namesilo_key]}'" >> "$acme_conf"
            fi
        fi
    else
        log_err "证书安装后加密学健康校验失败（证书过期、域名不匹配或公私钥不配对）。"
    fi
}

driver_cert_setup_timer() {
    cat > /etc/systemd/system/xray-acme.service <<EOF
[Unit]
Description=Acme.sh Certificate Renewal Daemon

[Service]
Type=oneshot
User=root
UMask=0022
ExecStart=$ACME_BIN --cron --home /root/.acme.sh
ExecStopPost=/bin/sh -c 'if [ -x "$ACME_HOOK_SCRIPT" ]; then "$ACME_HOOK_SCRIPT" close >/dev/null 2>&1 || true; fi'
LimitNOFILE=1048576
EOF

    cat > /etc/systemd/system/xray-acme.timer <<EOF
[Unit]
Description=Timer for Acme.sh Renewal (02:00 SGT / 18:00 UTC)

[Timer]
OnCalendar=*-*-* 18:00:00 UTC
Persistent=true
RandomizedDelaySec=5m

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now xray-acme.timer >/dev/null 2>&1 || log_err "证书自动续签定时器 (xray-acme.timer) 启用失败。"
    systemctl is-active --quiet xray-acme.timer || log_err "证书自动续签定时器未处于 active 状态。"
}

driver_cert_purge() {
    log_info "正在精准清理本脚本托管的证书资产与自动续签任务..."
    unit_purge "xray-acme.timer" "xray-acme.service"
    rm -f "$ACME_HOOK_SCRIPT" 2>/dev/null || true
    rm -rf "$NGINX_ACME_HOOK_DIR" "$WEBROOT_ACME_DIR" 2>/dev/null || true

    # 资产隔离：仅删除本脚本登记托管的域名证书，不破坏其他业务证书
    if [[ -s "$MANAGED_DOMAIN_FILE" ]]; then
        local managed_d
        managed_d=$(tr -d '[:space:]' < "$MANAGED_DOMAIN_FILE")
        if [[ -n "$managed_d" ]]; then
            [[ -x "$ACME_BIN" ]] && "$ACME_BIN" --remove -d "$managed_d" --ecc >/dev/null 2>&1 || true
            rm -rf "/root/.acme.sh/${managed_d}_ecc" 2>/dev/null || true
            rm -f "/etc/nginx/ssl/${managed_d}_ecc.cer" "/etc/nginx/ssl/${managed_d}_ecc.key" 2>/dev/null || true
        fi
        rm -f "$MANAGED_DOMAIN_FILE"
    fi

    # 仅当 /root/.acme.sh 下不存在其他第三方域名证书目录时，才清理 ACME 主目录
    if [[ -d /root/.acme.sh ]]; then
        local other_certs
        other_certs=$(find /root/.acme.sh -mindepth 1 -maxdepth 1 -type d \( -name "*_ecc" -o -name "*.*" \) ! -name "ca" ! -name "deploy" ! -name "dnsapi" ! -name "notify" 2>/dev/null | head -n1)
        if [[ -z "$other_certs" ]]; then
            rm -rf /root/.acme.sh 2>/dev/null || true
            crontab -l 2>/dev/null | grep -vE "acme\.sh.*--cron" | crontab - 2>/dev/null || true
            sed -i '/\.acme\.sh/d' /root/.bashrc 2>/dev/null || true
            sed -i '/acme\.sh/d' /root/.bashrc 2>/dev/null || true
        else
            log_info "检测到服务器上存在其他业务域名的 ACME 证书，已保留 /root/.acme.sh 核心目录。"
        fi
    fi

    # 若 /etc/nginx/ssl 已空则顺手清理空目录
    rmdir /etc/nginx/ssl 2>/dev/null || true
    log_ok "本脚本托管证书与续签任务清理完成。"
}

# --- [Driver: Nginx 伪装网关（独立专属站点目录隔离）] ---
driver_nginx_install() {
    local domain="${CTX[domain]}"
    local cert_file="/etc/nginx/ssl/${domain}_ecc.cer"
    local key_file="/etc/nginx/ssl/${domain}_ecc.key"

    if ! verify_cert_health "$cert_file" "$key_file" "$domain" 3600; then
        log_err "Nginx 关联的证书无效或与私钥不匹配 ($cert_file)，请检查证书申请步骤。"
    fi

    log_info "正在配置 Nginx 主程序..."
    driver_nginx_write_main_conf

    log_info "正在配置 Nginx 伪装网站和安全策略..."
    local has_reject=0
    local probe_conf="/tmp/ngx_probe.conf"
    CLEANUP_LIST+=("$probe_conf")
    cat > "$probe_conf" <<'EOF'
events {}
http { server { listen 127.0.0.1:8443 ssl; ssl_reject_handshake on; } }
EOF
    if nginx -t -c "$probe_conf" >/dev/null 2>&1; then
        has_reject=1
        log_ok "安全特性支持: [ssl_reject_handshake] 校验通过，已启用阻断。"
    else
        log_warn "当前 Nginx 版本较低，不支持 [ssl_reject_handshake] 特性。"
    fi

    local has_http2=0
    cat > "$probe_conf" <<'EOF'
events {}
http { server { http2 on; } }
EOF
    if nginx -t -c "$probe_conf" >/dev/null 2>&1; then
        has_http2=1
        log_ok "HTTP/2 特性模式: 采用现代独立 [http2 on] 语法。"
    else
        log_info "HTTP/2 特性模式: 降级采用兼容模式 [listen ... http2]。"
    fi
    rm -f "$probe_conf"

    local tmp_conf="/tmp/xray_nginx.conf"
    CLEANUP_LIST+=("$tmp_conf")
    rm -f "$tmp_conf"

    if [[ $has_reject -eq 1 ]]; then
        cat >> "$tmp_conf" <<EOF
server {
    listen 127.0.0.1:8443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOF
    fi

    local listen_directive
    if [[ $has_http2 -eq 1 ]]; then
        listen_directive="listen 127.0.0.1:8443 ssl;\n    http2 on;"
    else
        listen_directive="listen 127.0.0.1:8443 ssl http2;"
    fi

    cat >> "$tmp_conf" <<EOF
server {
    $(echo -e "$listen_directive")
    ssl_certificate $cert_file;
    ssl_certificate_key $key_file;
    server_name $domain;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    add_header X-Frame-Options SAMEORIGIN always;

    location / {
        root $WEBROOT_SITE_DIR;
        index index.html;
        try_files \$uri \$uri/ =404;
    }
}
EOF

    local redirect_url="https://\$host\$request_uri"
    if [[ "${CTX[port]}" != "443" ]]; then
        redirect_url="https://\$host:${CTX[port]}\$request_uri"
    fi

    if [[ "${CTX[dns_api]}" == "webroot" ]]; then
        mkdir -p "$NGINX_ACME_HOOK_DIR"
        rm -f "$NGINX_ACME_HOOK_DIR"/*.conf 2>/dev/null || true
        cat >> "$tmp_conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    include $NGINX_ACME_HOOK_DIR/*.conf;

    location / {
        return 301 $redirect_url;
    }
}
EOF
    else
        cat >> "$tmp_conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    return 301 $redirect_url;
}
EOF
    fi

    if [[ "${CTX[mode]}" == "3" ]]; then
        cat >> "$tmp_conf" <<EOF
server {
    listen 127.0.0.1:8444 default_server;
    server_name $domain;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    add_header X-Frame-Options SAMEORIGIN always;

    location / {
        root $WEBROOT_SITE_DIR;
        index index.html;
        try_files \$uri \$uri/ =404;
    }
}
EOF
    fi

    mv -f "$tmp_conf" /etc/nginx/sites-available/xray
    ln -sf /etc/nginx/sites-available/xray /etc/nginx/sites-enabled/xray

    local test_err
    if ! test_err=$(nginx -t 2>&1); then
        echo -e "${C_RED}=================== NGINX 语法校验错误详情 ===================${C_RESET}"
        echo -e "${test_err}"
        echo -e "${C_RED}==============================================================${C_RESET}"
        cat -n /etc/nginx/sites-available/xray
        rm -f /etc/nginx/sites-enabled/xray
        log_err "Nginx 配置文件校验失败，错误原因已详细打印在上方。"
    fi

    local temp_extract="/tmp/web_temp_$(date +%s)"
    local zip_file="/tmp/web_template.zip"
    CLEANUP_LIST+=("$temp_extract" "$zip_file")
    mkdir -p "$WEBROOT_SITE_DIR"
    find "$WEBROOT_SITE_DIR" -mindepth 1 -delete 2>/dev/null || true

    log_info "正在下载伪装网页文件..."
    echo -e "${C_BLUE}--- 解压伪装网页 ---${C_RESET}"
    if fetch_asset "https://codeload.github.com/rumicho8/Nginx-3DCEList/zip/refs/heads/main" "$zip_file" 120 && [[ -s "$zip_file" ]]; then
        mkdir -p "$temp_extract"
        if unzip -qo "$zip_file" -d "$temp_extract"; then
            local inner_dir
            inner_dir=$(find "$temp_extract" -mindepth 1 -maxdepth 1 -type d | head -n1)
            [[ -n "$inner_dir" ]] && cp -a "$inner_dir"/. "$WEBROOT_SITE_DIR/" 2>/dev/null
            log_ok "伪装网页部署成功。"
            echo "--------------------"
        fi
        rm -rf "$temp_extract" "$zip_file" 2>/dev/null || true
    fi

    if [[ ! -s "$WEBROOT_SITE_DIR/index.html" ]]; then
        cat > "$WEBROOT_SITE_DIR/index.html" <<'EOF'
<!DOCTYPE html><html><head><title>403 Forbidden</title></head><body style="background-color:black;color:white;text-align:center;padding-top:20%"><p>403 Forbidden</p><hr><p>nginx</p></body></html>
EOF
    fi

    chmod -R 755 "$WEBROOT_SITE_DIR"
    chown -R www-data:www-data "$WEBROOT_SITE_DIR" 2>/dev/null || true

    systemctl enable nginx >/dev/null 2>&1
    systemctl restart nginx || log_err "Nginx 服务启动/重载失败。"
    systemctl is-active --quiet nginx || log_err "Nginx 服务启动后未处于 active 运行状态，请检查系统日志。"
    log_ok "Nginx 服务启动成功。"
}

driver_nginx_clean_site() {
    log_info "正在清理本脚本托管的 Nginx 站点与专属伪装网页目录..."
    rm -f /etc/nginx/sites-available/xray /etc/nginx/sites-enabled/xray /etc/nginx/sites-enabled/acme_temp
    rm -rf "$NGINX_ACME_HOOK_DIR" "$WEBROOT_SITE_DIR" "$WEBROOT_ACME_DIR" 2>/dev/null || true

    # 还原首次接管时备份的原厂 nginx.conf
    if [[ -f /etc/nginx/nginx.conf.xray-orig ]]; then
        mv -f /etc/nginx/nginx.conf.xray-orig /etc/nginx/nginx.conf
    fi

    # 资产隔离：仅当服务器上不存在其他活跃站点时才停止 Nginx，否则仅执行安全重载
    if command -v nginx >/dev/null 2>&1; then
        local other_sites
        other_sites=$(find /etc/nginx/sites-enabled /etc/nginx/conf.d -mindepth 1 -maxdepth 1 2>/dev/null | head -n1)
        if [[ -n "$other_sites" ]]; then
            log_info "检测到 Nginx 仍承载其他站点配置，执行配置重载而不停止主服务。"
            nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
        else
            systemctl stop nginx >/dev/null 2>&1 || true
            systemctl disable nginx >/dev/null 2>&1 || true
        fi
    fi
    log_ok "本脚本 Nginx 业务配置与专属站点文件已清理。"
}

driver_nginx_purge_package() {
    log_info "正在物理清退 Nginx、系统包依赖与历史日志..."
    systemctl stop nginx >/dev/null 2>&1 || true
    systemctl disable nginx >/dev/null 2>&1 || true
    rm -f /etc/nginx/sites-available/xray /etc/nginx/sites-enabled/xray /etc/nginx/sites-enabled/acme_temp /etc/nginx/nginx.conf.xray-orig
    rm -rf "$NGINX_ACME_HOOK_DIR" "$WEBROOT_SITE_DIR" "$WEBROOT_ACME_DIR" 2>/dev/null || true
    local nginx_pkgs
    nginx_pkgs=$(dpkg-query -W -f='${Package}\n' 'nginx*' '*nginx*' 2>/dev/null | xargs)
    if [[ -n "$nginx_pkgs" ]]; then
        apt-get -o DPkg::Lock::Timeout=60 purge -yqq $nginx_pkgs >/dev/null 2>&1 || dpkg --purge --force-all $nginx_pkgs >/dev/null 2>&1 || true
        apt-get -o DPkg::Lock::Timeout=60 autoremove -yqq >/dev/null 2>&1 || true
    fi
    rm -rf /etc/nginx /var/www /var/log/nginx 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    log_ok "Nginx 软件包与系统配置已连根拔除。"
}

# --- [Driver: Xray Core 代理引擎（先下载自检并备份，再原子替换）] ---
driver_xray_install() {
    log_info "正在识别系统架构并下载 Xray 核心文件..."
    local arch_xray="64"
    [[ "${CTX[arch]}" == "arm64" ]] && arch_xray="arm64-v8a"

    local tmp_xray="/tmp/xray_build_$(date +%s)"
    CLEANUP_LIST+=("$tmp_xray")
    mkdir -p "$tmp_xray" && cd "$tmp_xray" || log_err "创建临时目录失败。"

    local zip_name="Xray-linux-${arch_xray}.zip"
    echo -e "${C_BLUE}--- 下载 Xray 核心 ---${C_RESET}"
    fetch_asset "https://github.com/XTLS/Xray-core/releases/latest/download/${zip_name}" "$zip_name" 120 || log_err "Xray 核心下载失败。"
    unzip -qo "$zip_name" || log_err "Xray 核心解压失败。"
    chmod +x xray || log_err "Xray 核心赋予执行权限失败。"
    ./xray version >/dev/null 2>&1 || log_err "下载的 Xray 二进制文件无法正常执行，已中止覆盖。"
    local xray_ver
    xray_ver=$(./xray version 2>/dev/null | head -n1)
    log_ok "Xray 核心校验通过 (${xray_ver:-Xray})。"
    echo "----------------------"

    mkdir -p "$BACKUP_DIR" "$XRAY_SHARE_DIR" "$XRAY_CONF_DIR"
    [[ -x "$XRAY_BIN" ]] && cp -af "$XRAY_BIN" "$BACKUP_DIR/xray.bak" 2>/dev/null || true
    [[ -f "$XRAY_CONFIG" ]] && cp -af "$XRAY_CONFIG" "$BACKUP_DIR/xray_config.json.bak" 2>/dev/null || true

    mv -f xray "$XRAY_BIN" || log_err "安装 Xray 二进制至 $XRAY_BIN 失败。"
    # 放置官方基础规则文件垫底兜底
    mv -f geoip.dat geosite.dat "$XRAY_SHARE_DIR/" 2>/dev/null || true

    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
Environment="XRAY_LOCATION_ASSET=$XRAY_SHARE_DIR"
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 /etc/systemd/system/xray.service
    systemctl daemon-reload
    cd "$HOME" && rm -rf "$tmp_xray"
    log_ok "Xray 核心与系统服务单元准备就绪。"
}

# --- [Driver: 路由分流规则自动化更新] ---
driver_rules_dat_setup() {
    log_info "正在配置增强版分流规则库与自动更新任务..."
    mkdir -p "$SCRIPT_DIR" "$XRAY_SHARE_DIR"
    cat > "$SCRIPT_DIR/update-dat.sh" <<'EOF'
#!/bin/bash
exec 9> /var/lock/xray-dat.lock
flock -n 9 || exit 0
SHARE_DIR="/usr/local/share/xray"
mkdir -p "$SHARE_DIR"
changed=0

update_file() {
    local f=$1; local u=$2
    local target_tmp="$SHARE_DIR/${f}.new"
    if curl -fL --max-time 300 --connect-timeout 60 --retry 5 --retry-delay 3 --retry-connrefused -o "$target_tmp" "$u" && [[ -s "$target_tmp" ]]; then
        local f_size
        f_size=$(stat -c%s "$target_tmp" 2>/dev/null || wc -c < "$target_tmp" 2>/dev/null | tr -d ' ' || echo 0)
        if [[ "$f_size" -ge 512000 ]] && ! cmp -s "$target_tmp" "$SHARE_DIR/$f"; then
            mv -f "$target_tmp" "$SHARE_DIR/$f"
            changed=1
            return 0
        fi
    fi
    rm -f "$target_tmp"
    return 1
}

update_file "geoip.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
update_file "geosite.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

[[ $changed -eq 1 ]] && systemctl is-active --quiet xray && systemctl restart xray >/dev/null 2>&1 || true
EOF
    chmod 755 "$SCRIPT_DIR/update-dat.sh"

    echo -e "${C_BLUE}--- 路由分流资源热同步 ---${C_RESET}"
    bash "$SCRIPT_DIR/update-dat.sh" || true
    echo "--------------------------"

    cat > /etc/systemd/system/xray-dat.service <<EOF
[Unit]
Description=Xray Dat Database Updater

[Service]
Type=oneshot
User=root
ExecStart=$SCRIPT_DIR/update-dat.sh
LimitNOFILE=1048576
EOF

    cat > /etc/systemd/system/xray-dat.timer <<EOF
[Unit]
Description=Timer for Xray Dat Update (Mon 03:00 SGT / Sun 19:00 UTC)

[Timer]
OnCalendar=Sun *-*-* 19:00:00 UTC
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now xray-dat.timer >/dev/null 2>&1 || log_err "分流规则自动更新定时器 (xray-dat.timer) 启用失败。"
    systemctl is-active --quiet xray-dat.timer || log_err "分流规则自动更新定时器未处于 active 状态。"
    log_ok "增强版分流规则库部署与定时更新任务配置完成。"
}

driver_rules_dat_purge() {
    unit_purge "xray-dat.timer" "xray-dat.service"
    rm -f "$SCRIPT_DIR/update-dat.sh" /var/lock/xray-dat.lock
}

driver_xray_configure() {
    log_info "正在生成 Xray 配置文件和加密密钥..."

    if [[ -f "$XRAY_CONFIG" ]]; then
        local old_uuid old_priv old_sid
        old_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null)
        old_priv=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG" 2>/dev/null)
        old_sid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG" 2>/dev/null)
        if [[ -n "$old_uuid" && "$old_uuid" != "null" && -n "$old_priv" && "$old_priv" != "null" ]]; then
            echo -e "${C_YELLOW}检测到服务器已存在历史 Xray 节点配置 (UUID: $old_uuid)。${C_RESET}"
            read -rp "是否保留复用历史密钥与 UUID？[Y/n, 默认 Y]: " REUSE_XRAY_KEY
            if [[ ! "$REUSE_XRAY_KEY" =~ ^[nN]$ ]]; then
                CTX[reuse_config]="1"
                CTX[uuid]="$old_uuid"
                CTX[priv_key]="$old_priv"
                CTX[short_id]="$old_sid"
                log_info "已继承历史 UUID 与 Reality 密钥配置。"
            else
                CTX[reuse_config]="0"
                log_info "已选择重置，将生成全新 UUID 与 Reality 密钥对。"
            fi
        fi
    fi

    [[ -z "${CTX[uuid]}" || "${CTX[uuid]}" == "null" ]] && CTX[uuid]=$($XRAY_BIN uuid)
    [[ -z "${CTX[short_id]}" || "${CTX[short_id]}" == "null" ]] && CTX[short_id]=$(openssl rand -hex 8)

    if [[ -n "${CTX[priv_key]}" && "${CTX[priv_key]}" != "null" ]]; then
        CTX[pub_key]=$($XRAY_BIN x25519 -i "${CTX[priv_key]}" 2>/dev/null | grep -iE "Public|Password" | grep -oE '[A-Za-z0-9_-]{43}' | head -n1)
    fi

    if [[ -z "${CTX[priv_key]}" || "${CTX[priv_key]}" == "null" || -z "${CTX[pub_key]}" || "${CTX[pub_key]}" == "null" ]]; then
        local key_re
        key_re="$($XRAY_BIN x25519 | tr -d '\r')"
        mapfile -t KEYS < <(echo "$key_re" | grep -iE "Private|Public|Password" | grep -oE '[A-Za-z0-9_-]{43}')
        CTX[priv_key]=""
        CTX[pub_key]=""
        for p_priv in "${KEYS[@]}"; do
            local calc_pub
            calc_pub=$($XRAY_BIN x25519 -i "$p_priv" 2>/dev/null | grep -iE "Public|Password" | grep -oE '[A-Za-z0-9_-]{43}' | head -n1)
            for p_pub in "${KEYS[@]}"; do
                if [[ "$calc_pub" == "$p_pub" && "$p_priv" != "$p_pub" ]]; then
                    CTX[priv_key]="$p_priv"
                    CTX[pub_key]="$p_pub"
                    break 2
                fi
            done
        done
    fi

    [[ -z "${CTX[priv_key]}" || -z "${CTX[pub_key]}" ]] && log_err "Xray x25519 密钥对生成失败，请检查 Xray 核心运行环境。"
    log_ok "安全加密密钥确认成功。"

    # 自适应检测内核 IPv6 协议栈是否启用，兼容纯 IPv4 禁用 IPv6 的宿主机
    local listen_ip="::"
    if [[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == "1" ]]; then
        listen_ip="0.0.0.0"
        log_info "检测到系统内核已禁用 IPv6，Xray 监听地址自动适配为 0.0.0.0。"
    fi

    local dest_addr="127.0.0.1:8443"
    local server_name_target="${CTX[domain]}"
    if [[ "${CTX[mode]}" == "2" ]]; then
        dest_addr="${CTX[public_sni]}:443"
        server_name_target="${CTX[public_sni]}"
    fi

    local port="${CTX[port]}"
    local uuid="${CTX[uuid]}"
    local priv="${CTX[priv_key]}"
    local sid="${CTX[short_id]}"

    local tmp_xray_conf="/tmp/xray_config_$$.json"
    CLEANUP_LIST+=("$tmp_xray_conf")

    cat > "$tmp_xray_conf" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "queryStrategy": "UseIP",
    "disableFallback": false,
    "hosts": {
      "dns.cloudflare.com": [
        "1.1.1.1",
        "1.0.0.1",
        "2606:4700:4700::1111",
        "2606:4700:4700::1001"
      ],
      "dns.google": [
        "8.8.8.8",
        "8.8.4.4",
        "2001:4860:4860::8888",
        "2001:4860:4860::8844"
      ]
    },
    "servers": [
      "https://dns.cloudflare.com/dns-query",
      "https://dns.google/dns-query"
    ]
  },
  "inbounds": [
    {
      "listen": "$listen_ip",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$dest_addr",
          "xver": 0,
          "serverNames": [
            "$server_name_target"
          ],
          "privateKey": "$priv",
          "shortIds": [
            "$sid"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIP"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" },
      { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block" },
      { "type": "field", "domain": ["geosite:geolocation-cn"], "outboundTag": "block" },
      { "type": "field", "ip": ["geoip:cn"], "outboundTag": "block" }
    ]
  }
}
EOF

    local test_res
    if ! test_res=$("$XRAY_BIN" run -test -config "$tmp_xray_conf" 2>&1); then
        echo -e "${C_RED}=================== XRAY 配置语法测试报错 ===================${C_RESET}"
        echo -e "${test_res}"
        echo -e "${C_RED}============================================================${C_RESET}"
        log_err "Xray 配置文件验证失败，错误详情已打印在上方。"
    fi

    mv -f "$tmp_xray_conf" "$XRAY_CONFIG"
    chmod 700 "$XRAY_CONF_DIR"
    chmod 600 "$XRAY_CONFIG"

    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray || log_err "Xray 服务启动失败，请使用 journalctl -u xray -e 查看底层日志。"
    systemctl is-active --quiet xray || log_err "Xray 服务启动后未处于 active 运行状态，请检查底层日志。"
    log_ok "Xray 路由规则配置与核心引擎启动成功。"
}

driver_xray_purge() {
    unit_purge "xray.service"
    rm -f "$XRAY_BIN"
    rm -rf "$XRAY_CONF_DIR" "$XRAY_SHARE_DIR"
}

# --- [Driver: Hysteria 2 协议栈（下载自检 + 指纹幂等防重复重启）] ---
driver_hysteria_install() {
    local domain="${CTX[domain]}"
    log_info "正在配置 Hysteria2 服务组件..."
    local tmp_hy2="/tmp/hy2_$(date +%s)"
    CLEANUP_LIST+=("$tmp_hy2")
    mkdir -p "$tmp_hy2"

    fetch_asset "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${CTX[arch]}" "$tmp_hy2/hysteria" 120 || log_err "Hysteria2 核心下载失败。"
    chmod +x "$tmp_hy2/hysteria" || log_err "Hysteria2 核心赋予执行权限失败。"
    "$tmp_hy2/hysteria" version >/dev/null 2>&1 || log_err "下载的 Hysteria2 二进制文件无法正常执行，已中止覆盖。"

    mkdir -p "$BACKUP_DIR" "$HY2_CONF_DIR"
    [[ -x "$HY2_BIN" ]] && cp -af "$HY2_BIN" "$BACKUP_DIR/hysteria.bak" 2>/dev/null || true
    [[ -f "$HY2_CONFIG" ]] && cp -af "$HY2_CONFIG" "$BACKUP_DIR/hysteria_config.yaml.bak" 2>/dev/null || true

    mv -f "$tmp_hy2/hysteria" "$HY2_BIN" || log_err "安装 Hysteria2 二进制至 $HY2_BIN 失败。"
    rm -rf "$tmp_hy2"

    if [[ "${CTX[reuse_config]}" == "1" && -f "$HY2_CONFIG" ]]; then
        local old_pass
        old_pass=$(grep -E '^[[:space:]]*password:' "$HY2_CONFIG" 2>/dev/null | head -n1 | awk '{print $2}' | tr -d '"'\''')
        if [[ -n "$old_pass" ]]; then
            CTX[hy2_pass]="$old_pass"
            log_info "已继承历史 Hysteria2 认证密码。"
        fi
    elif [[ "${CTX[reuse_config]}" == "0" && -f "$HY2_CONFIG" ]]; then
        log_info "已跟随重置策略，将生成全新 Hysteria2 认证密码。"
    fi
    [[ -z "${CTX[hy2_pass]}" ]] && CTX[hy2_pass]=$(openssl rand -hex 16)

    cat > "$HY2_CONFIG" <<EOF
listen: ":${CTX[port]}"
tls:
  cert: /etc/nginx/ssl/${domain}_ecc.cer
  key:  /etc/nginx/ssl/${domain}_ecc.key
auth:
  type: password
  password: ${CTX[hy2_pass]}
masquerade:
  type: proxy
  proxy:
    url: http://127.0.0.1:8444
    rewriteHost: true
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  ignorePacketLoss: false
EOF
    chmod 700 "$HY2_CONF_DIR"
    chmod 600 "$HY2_CONFIG"

    cat > /etc/systemd/system/hysteria-cert-watcher.path <<EOF
[Unit]
Description=Watch TLS certificate changes for Hysteria2

[Path]
PathChanged=/etc/nginx/ssl/${domain}_ecc.cer
PathChanged=/etc/nginx/ssl/${domain}_ecc.key

[Install]
WantedBy=multi-user.target
EOF

    mkdir -p "$SCRIPT_DIR"
    cat > "$SCRIPT_DIR/hysteria-cert-restart.sh" <<EOF
#!/bin/bash
cert_file="/etc/nginx/ssl/${domain}_ecc.cer"
key_file="/etc/nginx/ssl/${domain}_ecc.key"
state_file="/run/hysteria-cert.sha256"
exec 9>/run/hysteria-cert.lock
flock -n 9 || exit 0
# 防抖延迟 2 秒，等待 acme.sh 完成双文件落盘
sleep 2
valid=0
for i in \$(seq 1 10); do
    if [[ -s "\$cert_file" && -s "\$key_file" ]]; then
        cert_pub=\$(openssl x509 -in "\$cert_file" -noout -pubkey 2>/dev/null)
        key_pub=\$(openssl pkey -in "\$key_file" -pubout 2>/dev/null)
        if [[ -n "\$cert_pub" && "\$cert_pub" == "\$key_pub" ]]; then
            valid=1
            break
        fi
    fi
    sleep 1
done
if [[ \$valid -eq 1 ]]; then
    cur_hash=\$(sha256sum "\$cert_file" "\$key_file" 2>/dev/null | sha256sum | awk '{print \$1}')
    prev_hash=\$(cat "\$state_file" 2>/dev/null || true)
    # 证书指纹未发生变化且服务已在运行，跳过重复事件引发的二次重启
    if [[ -n "\$cur_hash" && "\$cur_hash" == "\$prev_hash" ]] && systemctl is-active --quiet hysteria-server; then
        exit 0
    fi
    if [ -L /etc/nginx/sites-enabled/xray ] && [ -s /etc/nginx/sites-enabled/xray ]; then
        nginx -t || exit 1
        if systemctl is-active --quiet nginx; then
            systemctl reload nginx || exit 1
        else
            systemctl start nginx || exit 1
        fi
        systemctl is-active --quiet nginx || exit 1
    fi
    systemctl restart hysteria-server || exit 1
    systemctl is-active --quiet hysteria-server || exit 1
    printf '%s\n' "\$cur_hash" > "\$state_file"
else
    exit 1
fi
EOF
    chmod 755 "$SCRIPT_DIR/hysteria-cert-restart.sh"

    cat > /etc/systemd/system/hysteria-cert-watcher.service <<EOF
[Unit]
Description=Reload Nginx and Restart Hysteria2 on certificate change
ConditionPathExists=$HY2_CONFIG
ConditionPathExists=/etc/nginx/ssl/${domain}_ecc.cer
ConditionPathExists=/etc/nginx/ssl/${domain}_ecc.key

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/hysteria-cert-restart.sh
EOF

    cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria2 Server Service
After=network.target
ConditionPathExists=$HY2_CONFIG
ConditionPathExists=/etc/nginx/ssl/${domain}_ecc.cer
ConditionPathExists=/etc/nginx/ssl/${domain}_ecc.key

[Service]
Type=simple
ExecStart=$HY2_BIN server -c $HY2_CONFIG
Environment=HYSTERIA_LOG_LEVEL=warn
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now hysteria-cert-watcher.path >/dev/null 2>&1 || log_err "Hysteria2 证书监听单元启用失败。"
    systemctl enable hysteria-server >/dev/null 2>&1
    systemctl restart hysteria-server || log_err "Hysteria2 启动失败，请检查端口占用。"
    systemctl is-active --quiet hysteria-server || log_err "Hysteria2 启动后未处于 active 运行状态，请检查系统日志。"
    sha256sum "/etc/nginx/ssl/${domain}_ecc.cer" "/etc/nginx/ssl/${domain}_ecc.key" 2>/dev/null | sha256sum | awk '{print $1}' > /run/hysteria-cert.sha256
    log_ok "Hysteria2 服务部署成功。"
}

driver_hysteria_purge() {
    unit_purge "hysteria-server.service" "hysteria-cert-watcher.path" "hysteria-cert-watcher.service"
    rm -f "$HY2_BIN" "$SCRIPT_DIR/hysteria-cert-restart.sh" /run/hysteria-cert.lock /run/hysteria-cert.sha256
    rm -rf "$HY2_CONF_DIR" /tmp/hy2_* 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# LAYER 4: 业务交互与流程编排 (Workflow Orchestration & Prompts)
# ------------------------------------------------------------------------------
workflow_fetch_host_ips() {
    CTX[ipv4]=$(curl -s4m 5 icanhazip.com || curl -s4m 5 ifconfig.me || true)
    CTX[ipv6]=$(curl -s6m 5 icanhazip.com || curl -s6m 5 ifconfig.me || true)
}

workflow_select_port() {
    echo -e "${C_BLUE}[TIP] 强烈建议使用默认 443 端口以获得最佳伪装深度与网络穿透率。${C_RESET}"
    while true; do
        read -rp "请设置 Xray 监听端口 (范围 1-65535) [默认 443]: " PORT_INPUT
        CTX[port]=${PORT_INPUT:-443}
        if ! [[ "${CTX[port]}" =~ ^[0-9]+$ ]] || [[ "${CTX[port]}" -lt 1 ]] || [[ "${CTX[port]}" -gt 65535 ]]; then
            log_warn "输入的端口无效，请输入 1-65535 之间的数字。"
            continue
        fi

        if [[ "${CTX[mode]}" =~ ^[13]$ ]] && [[ "${CTX[port]}" =~ ^(80|8443|8444)$ ]]; then
            log_warn "端口冲突：当前模式下，端口 80/8443/8444 已被本地 Web/伪装回落服务占用，请换一个端口。"
            continue
        fi

        if ss -tlnp | grep -E ":${CTX[port]}\b" | grep -vE 'users:\(\("(xray|nginx)"' >/dev/null 2>&1; then
            log_warn "端口占用：端口 ${CTX[port]} (TCP) 已被其他外部程序占用，请重新分配。"
            continue
        fi

        if [[ "${CTX[mode]}" == "3" ]] && ss -ulnp | grep -E ":${CTX[port]}\b" | grep -vE 'users:\(\("hysteria"' >/dev/null 2>&1; then
            log_warn "端口占用：端口 ${CTX[port]} (UDP) 已被其他外部程序占用。Hysteria2 需要 UDP 支持，请重新分配。"
            continue
        fi

        log_ok "端口 ${CTX[port]} 可以使用。\n"
        break
    done
}

workflow_get_inputs() {
    echo -e "\n${C_BOLD}${C_BLUE}--- [步骤 1/3] 选择部署模式 ---${C_RESET}"
    echo -e "  1. Web 回落模式 (推荐) - 自动申请证书 + 搭建本地伪装网站，极其稳定安全。"
    echo -e "  2. 纯净直连模式        - 借用大厂域名 (如 Apple) 伪装，不需要自己的域名，简单轻量。"
    echo -e "  3. 全能共存模式        - 融合 Web 回落架构，并同步拉起 Hysteria2 协议栈 (端口复用)。"
    while true; do
        read -rp "请选择 [1/2/3, 默认 1]: " MODE_INPUT
        CTX[mode]=${MODE_INPUT:-1}
        [[ "${CTX[mode]}" =~ ^[123]$ ]] && break
        log_warn "输入无效，请输入 1、2 或 3。"
    done

    workflow_fetch_host_ips

    if [[ "${CTX[mode]}" =~ ^[13]$ ]]; then
        if ss -tlnp | grep -E ":80\b" | grep -vE 'users:\(\("nginx"' >/dev/null 2>&1; then
            log_warn "检测到当前服务器 80 端口已被外部非 Nginx 进程占用！Web 回落与证书签发可能会失败。"
        fi

        while true; do
            read -rp "请输入已解析到本服务器的域名 (例如 my.domain.com): " DOMAIN_INPUT
            CTX[domain]=$(echo "$DOMAIN_INPUT" | sed 's|^https\?://||; s|/.*$||' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
            if is_valid_domain "${CTX[domain]}"; then
                break
            fi
            log_warn "域名格式无效或为空，请输入合法的域名 (不含 http:// 或路径)。"
        done

        echo -e "\n${C_BLUE}正在测试域名解析状态 (双栈独立检测)...${C_RESET}"
        local domain_ipv4="" domain_ipv6=""
        if command -v jq >/dev/null 2>&1; then
            domain_ipv4=$(curl -sm 5 -H "accept: application/dns-json" "https://cloudflare-dns.com/dns-query?name=${CTX[domain]}&type=A" 2>/dev/null | jq -r '.Answer[]? | select(.type == 1) | .data' 2>/dev/null | head -n1)
            domain_ipv6=$(curl -sm 5 -H "accept: application/dns-json" "https://cloudflare-dns.com/dns-query?name=${CTX[domain]}&type=AAAA" 2>/dev/null | jq -r '.Answer[]? | select(.type == 28) | .data' 2>/dev/null | head -n1)
        fi
        [[ -z "$domain_ipv4" ]] && domain_ipv4=$(getent ahostsv4 "${CTX[domain]}" 2>/dev/null | awk '{print $1}' | head -n1)
        [[ -z "$domain_ipv6" ]] && domain_ipv6=$(getent ahostsv6 "${CTX[domain]}" 2>/dev/null | awk '{print $1}' | grep -v '^::ffff:' | head -n1)

        echo -e "  本机 IPv4 : ${C_YELLOW}${CTX[ipv4]:-"无或超时"}${C_RESET} | 解析 IPv4 : ${C_YELLOW}${domain_ipv4:-"无 A 记录"}${C_RESET}"
        echo -e "  本机 IPv6 : ${C_YELLOW}${CTX[ipv6]:-"无或超时"}${C_RESET} | 解析 IPv6 : ${C_YELLOW}${domain_ipv6:-"无 AAAA 记录"}${C_RESET}"

        local v4_ok=0 v6_ok=0 dns_conflict=0
        [[ -n "${CTX[ipv4]}" && "${CTX[ipv4]}" == "$domain_ipv4" ]] && v4_ok=1
        [[ -n "${CTX[ipv6]}" && "${CTX[ipv6]}" == "$domain_ipv6" ]] && v6_ok=1
        [[ -n "$domain_ipv4" && "$domain_ipv4" != "${CTX[ipv4]}" ]] && dns_conflict=1
        [[ -n "$domain_ipv6" && "$domain_ipv6" != "${CTX[ipv6]}" ]] && dns_conflict=1

        if [[ $dns_conflict -eq 1 ]]; then
            echo -e "${C_RED}  [WARN] 警告：检测到存在与本机 IP 不一致的 DNS 解析记录（可能开启了 CDN 或残留旧 IP 解析），可能导致证书验证或连接失败！${C_RESET}\n"
        elif [[ $v4_ok -eq 1 || $v6_ok -eq 1 ]]; then
            echo -e "${C_GREEN}  [OK] 域名解析记录与本机公网 IP 匹配一致。${C_RESET}\n"
        else
            echo -e "${C_RED}  [WARN] 警告：未检测到指向本机公网 IP 的有效 DNS 解析记录。${C_RESET}\n"
        fi

        workflow_select_port

        echo -e "${C_BOLD}${C_BLUE}--- [步骤 2/3] 选择证书验证方式 ---${C_RESET}"
        echo -e "  1. DNS API 验证机制 (推荐) - 静默验证，支持泛域名，无惧端口被封。"
        echo -e "  2. HTTP Webroot 机制       - 依赖 Nginx 80 端口按需动态验证 (平时全关闭)。"
        local VERIFY_TYPE
        while true; do
            read -rp "请选择 [1/2, 默认 1]: " VERIFY_TYPE
            VERIFY_TYPE=${VERIFY_TYPE:-1}
            [[ "$VERIFY_TYPE" =~ ^[12]$ ]] && break
            log_warn "输入无效，请输入 1 或 2。"
        done

        if [[ "$VERIFY_TYPE" == "2" ]]; then
            CTX[dns_api]="webroot"
        else
            echo -e "\n  1. Cloudflare\n  2. Namesilo"
            local DNS_TYPE
            while true; do
                read -rp "请选择你的域名服务商 [1/2, 默认 1]: " DNS_TYPE
                DNS_TYPE=${DNS_TYPE:-1}
                [[ "$DNS_TYPE" =~ ^[12]$ ]] && break
                log_warn "输入无效，请输入 1 或 2。"
            done
            if [[ "$DNS_TYPE" == "1" ]]; then
                CTX[dns_api]="dns_cf"
                read -rp "输入 Cloudflare API Token: " CTX[cf_token]
                read -rp "输入 Cloudflare Zone ID: " CTX[cf_zone_id]
                export CF_Token=${CTX[cf_token]}
                export CF_Zone_ID=${CTX[cf_zone_id]}
            else
                CTX[dns_api]="dns_namesilo"
                read -rp "输入 Namesilo API Key: " CTX[namesilo_key]
                export Namesilo_Key=${CTX[namesilo_key]}
            fi
        fi

        echo -e "\n${C_BOLD}${C_BLUE}--- [步骤 3/3] 选择证书申请环境 ---${C_RESET}"
        echo -e "  1. Production (生产环境) - 颁发正规信任证书 (有频次限制)。"
        echo -e "  2. Staging    (测试环境) - 无次数限制，专用于调试排错。"
        local CERT_MODE_INPUT
        while true; do
            read -rp "请选择 [1/2, 默认 1]: " CERT_MODE_INPUT
            CERT_MODE_INPUT=${CERT_MODE_INPUT:-1}
            [[ "$CERT_MODE_INPUT" =~ ^[12]$ ]] && break
            log_warn "输入无效，请输入 1 或 2。"
        done
        if [[ "$CERT_MODE_INPUT" == "2" ]]; then
            CTX[cert_mode]="--staging"
            log_warn "当前选择：Staging 测试环境。"
        else
            CTX[cert_mode]="--server letsencrypt"
            log_info "当前选择：Production 生产环境。"
        fi
    else
        echo -e "\n${C_BOLD}${C_BLUE}--- [步骤 1/2] 设置伪装域名 (SNI) ---${C_RESET}"
        while true; do
            read -rp "请输入用于伪装的公共域名 [默认 www.apple.com]: " PUBLIC_SNI_INPUT
            local sni_val=${PUBLIC_SNI_INPUT:-"www.apple.com"}
            CTX[public_sni]=$(echo "$sni_val" | sed 's|^https\?://||; s|/.*$||' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
            if is_valid_domain "${CTX[public_sni]}"; then
                break
            fi
            log_warn "伪装 SNI 格式无效，请输入合法的域名（禁止包含引号、空格或路径）。"
        done
        workflow_select_port
        echo -e "  本机 IPv4 : ${C_YELLOW}${CTX[ipv4]:-"无或超时"}${C_RESET}"
        echo -e "  本机 IPv6 : ${C_YELLOW}${CTX[ipv6]:-"无或超时"}${C_RESET}\n"
    fi
}

workflow_align_modes() {
    log_info "正在根据目标模式执行环境对齐与无关资产清理..."
    [[ "${CTX[mode]}" != "3" ]] && driver_hysteria_purge >/dev/null 2>&1
    if [[ "${CTX[mode]}" == "2" ]]; then
        driver_cert_purge >/dev/null 2>&1
        driver_nginx_clean_site >/dev/null 2>&1
    fi
    log_ok "无关异构资产清理完毕，环境已恢复初装基线。"
}

workflow_deploy() {
    cd "$HOME" || safe_terminate 1
    reset_context

    # 安全自愈未完成的 dpkg 配置（使用系统内置 flock 非阻塞探测锁，无需额外安装 psmisc/fuser）
    if flock -n /var/lib/dpkg/lock-frontend true >/dev/null 2>&1 && flock -n /var/lib/dpkg/lock true >/dev/null 2>&1; then
        dpkg --configure -a >/dev/null 2>&1 || true
    fi

    # 仅在命令缺失时按需补齐基础预检工具
    local pre_pkgs=""
    command -v curl >/dev/null 2>&1 || pre_pkgs="$pre_pkgs curl"
    command -v jq >/dev/null 2>&1   || pre_pkgs="$pre_pkgs jq"
    command -v ss >/dev/null 2>&1   || pre_pkgs="$pre_pkgs iproute2"

    if [[ -n "$pre_pkgs" ]]; then
        apt-get -o DPkg::Lock::Timeout=60 update -yqq >/dev/null 2>&1
        apt-get -o DPkg::Lock::Timeout=60 install -yqq --no-install-recommends $pre_pkgs >/dev/null 2>&1
    fi

    local arch_raw
    arch_raw=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case "$arch_raw" in
        amd64|x86_64)  CTX[arch]="amd64" ;;
        arm64|aarch64) CTX[arch]="arm64" ;;
        *)             CTX[arch]="amd64" ;;
    esac

    # 先完成全部交互问答，保持旧服务正常运行以缩短停机窗口
    workflow_get_inputs

    sys_setup_journald

    local install_pkgs="curl unzip openssl jq qrencode"
    local reinstall_flag=""
    if [[ "${CTX[mode]}" =~ ^[13]$ ]]; then
        install_pkgs="$install_pkgs nginx socat"
        if [[ ! -f /etc/nginx/nginx.conf || ! -f /etc/nginx/mime.types || ! -d /etc/nginx/modules-enabled ]]; then
            local installed_ngx_sub
            installed_ngx_sub=$(dpkg-query -W -f='${Package} ' 'nginx-*' 'libnginx-mod-*' 2>/dev/null || true)
            install_pkgs="$install_pkgs nginx-common $installed_ngx_sub"
            reinstall_flag="--reinstall"
        fi
    fi

    log_info "正在同步软件源索引并安装模式所需的基础软件..."
    apt-get -o DPkg::Lock::Timeout=60 update -yqq >/dev/null 2>&1

    local apt_log="/tmp/apt_install_$$.log"
    CLEANUP_LIST+=("$apt_log")

    if ! apt-get -o DPkg::Lock::Timeout=60 install -yqq $reinstall_flag --no-install-recommends \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        -o Dpkg::Options::="--force-confmiss" \
        $install_pkgs > "$apt_log" 2>&1; then

        echo -e "${C_RED}=================== APT 安装底层报错详情 ===================${C_RESET}"
        grep -iE "E:|Err:|Error|dpkg:|failed" "$apt_log" 2>/dev/null || tail -n 15 "$apt_log"
        echo -e "${C_RED}============================================================${C_RESET}"

        local missing_pkgs=()
        for pkg in $install_pkgs; do
            if ! dpkg -s "$pkg" >/dev/null 2>&1 || ! dpkg -s "$pkg" | grep -qw "Status: install ok installed"; then
                missing_pkgs+=("$pkg")
            fi
        done

        rm -f "$apt_log"
        log_err "基础软件安装未通过！未就绪的依赖组件: [ ${missing_pkgs[*]} ]，请根据上方红框内的错误原因修复系统环境。"
    fi
    rm -f "$apt_log"

    log_ok "基础软件及目录准备完毕 (已就绪: $(echo $install_pkgs | tr ' ' ', '))。"
    mkdir -p "$SCRIPT_DIR" "$BACKUP_DIR"

    sys_setup_bbr

    # 仅在进入正式配置与证书签发前停止本脚本托管的旧服务，避免下载期间断流
    systemctl stop xray hysteria-server hysteria-cert-watcher.path >/dev/null 2>&1 || true
    workflow_align_modes

    if [[ "${CTX[mode]}" =~ ^[13]$ ]]; then
        mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/ssl "$NGINX_ACME_HOOK_DIR" "$WEBROOT_SITE_DIR" "$WEBROOT_ACME_DIR" /var/log/nginx
        driver_cert_install
        driver_nginx_install
        driver_cert_setup_timer
    fi

    driver_xray_install
    driver_rules_dat_setup
    driver_xray_configure

    [[ "${CTX[mode]}" == "3" ]] && driver_hysteria_install

    sys_clean_apt_cache
    workflow_show_result
}

workflow_show_result() {
    echo -e "\n${C_GREEN}------------------------------------------------------------------${C_RESET}"
    echo -e "${C_BOLD}${C_GREEN}[OK] Xray 部署全部完成！(DEPLOYMENT SUCCESS)${C_RESET}"
    echo -e "${C_GREEN}------------------------------------------------------------------${C_RESET}"

    local client_sni="${CTX[domain]}"
    [[ "${CTX[mode]}" == "2" ]] && client_sni="${CTX[public_sni]}"

    local query="?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${client_sni}&fp=chrome&pbk=${CTX[pub_key]}&sid=${CTX[short_id]}&type=tcp#Reality_${client_sni}"

    echo -e "${C_BOLD}[Xray Reality 节点参数]${C_RESET}"
    echo -e " 监听端口   : ${C_YELLOW}${CTX[port]} (TCP)${C_RESET}"
    echo -e " UUID 标识  : ${C_YELLOW}${CTX[uuid]}${C_RESET}"
    echo -e " Public Key : ${C_YELLOW}${CTX[pub_key]}${C_RESET}"
    echo -e " Short ID   : ${C_YELLOW}${CTX[short_id]}${C_RESET}"
    echo -e " 伪装 SNI   : ${C_BLUE}$client_sni${C_RESET}"
    echo -e "------------------------------------------------------------------"

    if [[ "${CTX[mode]}" =~ ^[13]$ ]]; then
        local vless_link="vless://${CTX[uuid]}@${CTX[domain]}:${CTX[port]}${query}"
        echo -e "${C_BOLD}客户端分享链接 (域名自适应版):${C_RESET}\n${C_GREEN}${vless_link}${C_RESET}\n"
        echo "$vless_link" | qrencode -t ansiutf8
    else
        echo -e "${C_BOLD}客户端分享链接 (双栈独立节点):${C_RESET}\n"
        local qr_target=""
        if [[ -n "${CTX[ipv4]}" ]]; then
            local v4_link="vless://${CTX[uuid]}@${CTX[ipv4]}:${CTX[port]}${query}"
            echo -e " [1] IPv4 节点:\n${C_GREEN}${v4_link}${C_RESET}\n"
            qr_target="$v4_link"
        fi
        if [[ -n "${CTX[ipv6]}" ]]; then
            local v6_link="vless://${CTX[uuid]}@[${CTX[ipv6]}]:${CTX[port]}${query}"
            echo -e " [2] IPv6 节点:\n${C_GREEN}${v6_link}${C_RESET}\n"
            [[ -z "$qr_target" ]] && qr_target="$v6_link"
        fi

        if [[ -z "${CTX[ipv4]}" && -z "${CTX[ipv6]}" ]]; then
            local fallback_link="vless://${CTX[uuid]}@你的VPS_IP:${CTX[port]}${query}"
            echo -e " [!] 默认节点 (获取公网IP超时，请手动替换为实际IP):\n${C_YELLOW}${fallback_link}${C_RESET}\n"
            qr_target="$fallback_link"
        fi

        [[ -n "$qr_target" ]] && echo "$qr_target" | qrencode -t ansiutf8
    fi

    if [[ "${CTX[mode]}" == "3" ]]; then
        local hy2_insecure=0
        [[ "${CTX[cert_mode]}" == "--staging" ]] && hy2_insecure=1
        local hy2_link="hy2://${CTX[hy2_pass]}@${CTX[domain]}:${CTX[port]}/?sni=${CTX[domain]}&alpn=h3&insecure=${hy2_insecure}#Hysteria2_${CTX[domain]}"
        echo -e "\n------------------------------------------------------------------"
        echo -e "${C_BOLD}[Hysteria2 节点参数]${C_RESET}"
        echo -e " 网络端口   : ${C_YELLOW}${CTX[port]} (UDP)${C_RESET}"
        echo -e " 认证密码   : ${C_YELLOW}${CTX[hy2_pass]}${C_RESET}"
        echo -e " 本地回落   : ${C_BLUE}Nginx (127.0.0.1:8444)${C_RESET}"
        echo -e "------------------------------------------------------------------"
        echo -e "${C_BOLD}客户端分享链接:${C_RESET}\n${C_GREEN}$hy2_link${C_RESET}\n"
    fi
}

workflow_uninstall() {
    echo -e "\n${C_BLUE}[INFO]${C_RESET} 正在回收核心业务与系统服务..."

    driver_xray_purge
    driver_hysteria_purge
    driver_rules_dat_purge
    driver_cert_purge
    driver_nginx_clean_site
    rm -rf "$SCRIPT_DIR"
    if [[ -f /etc/systemd/journald.conf.d/99-prophet.conf ]]; then
        rm -f /etc/systemd/journald.conf.d/99-prophet.conf
        systemctl restart systemd-journald >/dev/null 2>&1 || true
    fi

    echo -e "\n${C_YELLOW}所有本脚本托管的核心业务文件与节点配置已安全回收。${C_RESET}"
    echo -e "${C_RED}[WARN] 是否连带卸载底层工具包 (Nginx, Socat, qrencode, jq, unzip)？${C_RESET}"
    read -rp "如果服务器还承载其他业务，请选 N！[y/N, 默认 N]: " PURGE_SYS
    case "${PURGE_SYS}" in
        [yY][eE][sS]|[yY])
            driver_nginx_purge_package
            local purge_list="socat qrencode jq unzip"
            apt-get -o DPkg::Lock::Timeout=60 purge -yqq $purge_list >/dev/null 2>&1 || true
            sys_clean_apt_cache
            echo -e "${C_GREEN}[OK] 底层运行依赖包已彻底清除 (已保留 curl 与 BBR 网络加速配置)。${C_RESET}"
            ;;
        *)
            echo -e "${C_GREEN}[OK] 已保留底层公共基础软件与原厂 Nginx 配置。${C_RESET}"
            ;;
    esac
    read -rp "按回车键返回主菜单..."
}

# ------------------------------------------------------------------------------
# LAYER 5: CLI 入口与调度菜单 (Main Menu & Entrypoint)
# ------------------------------------------------------------------------------
while true; do
    clear
    echo -e "${C_BLUE}"
    echo -e " ----------------------------------------------"
    echo -e "   REALITY AUTOMATION CLI ENGINE"
    echo -e "   Build: $SCRIPT_VERSION"
    echo -e " ----------------------------------------------${C_RESET}\n"

    echo -e "  1. ${C_GREEN}执行部署脚本${C_RESET}"
    echo -e "  2. ${C_YELLOW}卸载服务${C_RESET}"
    echo -e "  3. ${C_BLUE}查看定时任务+证书状态${C_RESET}"
    echo -e "  0. ${C_RED}退出脚本${C_RESET}\n"

    read -rp "请输入数字选择功能 [0-3]: " OPT
    case $OPT in
        1)
            workflow_deploy
            safe_terminate 0
            break
            ;;
        2)
            workflow_uninstall
            ;;
        3)
            echo -e "\n${C_BOLD}${C_BLUE}--- 自动任务运行状态 ---${C_RESET}"
            systemctl list-timers --all | grep -E "xray-acme|xray-dat" || echo "当前没有运行中的定时任务"
            echo -e "\n${C_BOLD}${C_BLUE}--- 已安装证书详情列表 ---${C_RESET}"
            [[ -f "$ACME_BIN" ]] && "$ACME_BIN" --list --home "/root/.acme.sh" || echo "未检测到 acme.sh 证书环境。"
            read -rp "按回车键返回菜单..."
            ;;
        0)
            echo -e "\n已退出。"
            safe_terminate 0
            break
            ;;
        *)
            echo -e "\n${C_RED}[ERROR] 输入无效，请重新选择。${C_RESET}"
            sleep 1
            ;;
    esac
done