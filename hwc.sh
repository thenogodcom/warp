#!/usr/bin/env bash
#
# Description: Ultimate All-in-One Manager for Caddy, WARP, Hysteria & AdGuard Home with self-installing shortcut.
# Author: Your Name (Inspired by P-TERX)
# Version: 5.6.0 (AdGuard Home Integration Edition)

# --- 第1節：全域設定與定義 ---

# 顏色定義，用於日誌輸出
FontColor_Red="\033[31m"; FontColor_Green="\033[32m"; FontColor_Yellow="\033[33m"
FontColor_Purple="\033[35m"; FontColor_Suffix="\033[0m"

# 標準化日誌函數
log() {
    local LEVEL="$1"; local MSG="$2"
    case "${LEVEL}" in
        INFO)  local LEVEL="[${FontColor_Green}資訊${FontColor_Suffix}]";;
        WARN)  local LEVEL="[${FontColor_Yellow}警告${FontColor_Suffix}]";;
        ERROR) local LEVEL="[${FontColor_Red}錯誤${FontColor_Suffix}]";;
    esac
    echo -e "${LEVEL} ${MSG}"
}

# 固定的應用程式基礎目錄，解決 `pwd` 帶來的路徑不確定問題
APP_BASE_DIR="/root/hwc"
CADDY_CONTAINER_NAME="caddy-manager"; CADDY_IMAGE_NAME="caddy:latest"; CADDY_CONFIG_DIR="${APP_BASE_DIR}/caddy"; CADDY_CONFIG_FILE="${CADDY_CONFIG_DIR}/Caddyfile"; CADDY_DATA_VOLUME="hwc_caddy_data"
WARP_CONTAINER_NAME="warp-docker"; WARP_IMAGE_NAME="ghcr.io/105pm/docker-warproxy:latest"; WARP_VOLUME_PATH="${APP_BASE_DIR}/warp-data"
HYSTERIA_CONTAINER_NAME="hysteria-server"; HYSTERIA_IMAGE_NAME="tobyxdd/hysteria"; HYSTERIA_CONFIG_DIR="${APP_BASE_DIR}/hysteria"; HYSTERIA_CONFIG_FILE="${HYSTERIA_CONFIG_DIR}/config.yaml"
ADGUARD_CONTAINER_NAME="adguard-home"; ADGUARD_IMAGE_NAME="adguard/adguardhome:edge"; ADGUARD_CONFIG_DIR="${APP_BASE_DIR}/adguard/conf"; ADGUARD_WORK_DIR="${APP_BASE_DIR}/adguard/work"
SHARED_NETWORK_NAME="hwc-proxy-net"
SCRIPT_URL="https://raw.githubusercontent.com/thenogodcom/warp/main/hwc.sh"; SHORTCUT_PATH="/usr/local/bin/hwc"
declare -A CONTAINER_STATUSES

# --- 第2節：所有函數定義 ---

# 自我安裝快捷命令
self_install() {
    local running_script_path
    if [[ -f "$0" ]]; then running_script_path=$(readlink -f "$0"); fi
    if [ "$running_script_path" = "$SHORTCUT_PATH" ]; then return 0; fi

    log INFO "首次運行設定：正在安裝 'hwc' 快捷命令以便日後存取..."
    # 確保 curl 已安裝
    if ! command -v curl &>/dev/null; then
        log WARN "'curl' 未安裝，正在嘗試安裝..."
        if command -v apt-get &>/dev/null; then apt-get update && apt-get install -y --no-install-recommends curl; fi
        if command -v yum &>/dev/null || command -v dnf &>/dev/null; then 
            command -v yum &>/dev/null && yum install -y curl
            command -v dnf &>/dev/null && dnf install -y curl
        fi
    fi
    if curl -sSL "${SCRIPT_URL}" -o "${SHORTCUT_PATH}"; then
        chmod +x "${SHORTCUT_PATH}"
        log INFO "快捷命令 'hwc' 安裝成功。正在從新位置重新啟動..."
        exec "${SHORTCUT_PATH}" "$@"
    else
        log ERROR "無法安裝 'hwc' 快捷命令至 ${SHORTCUT_PATH}。"
        log WARN "本次將臨時運行腳本，請檢查權限後重試。"
        sleep 3
    fi
}

# 驗證域名格式
validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        log ERROR "域名格式無效: $domain"
        return 1
    fi
    return 0
}

# 驗證郵箱格式
validate_email() {
    local email="$1"
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log ERROR "郵箱格式無效: $email"
        return 1
    fi
    return 0
}

# 驗證後端服務地址格式 (hostname:port 或 ip:port)
validate_backend_service() {
    local service="$1"
    if [[ ! "$service" =~ ^[a-zA-Z0-9\._-]+:[0-9]+$ ]]; then
        log ERROR "後端服務地址格式無效（應為 hostname:port）: $service"
        return 1
    fi
    return 0
}

# 檢測證書路徑（支持多個 CA）
detect_cert_path() {
    local domain="$1"
    local base_path="/data/caddy/certificates"
    
    # 在容器中檢查證書是否存在（通過檢查 caddy 容器的卷）
    if container_exists "$CADDY_CONTAINER_NAME"; then
        # 嘗試常見的 CA 目錄
        for ca_dir in "acme-v02.api.letsencrypt.org-directory" "acme.zerossl.com-v2-DV90"; do
            local cert_check
            cert_check=$(docker exec "$CADDY_CONTAINER_NAME" sh -c "[ -f $base_path/$ca_dir/$domain/$domain.crt ] && echo 'exists'" 2>/dev/null)
            if [ "$cert_check" = "exists" ]; then
                echo "$base_path/$ca_dir/$domain/$domain.crt|$base_path/$ca_dir/$domain/$domain.key"
                return 0
            fi
        done
    fi
    
    # 回退到 Let's Encrypt 默認路徑
    echo "$base_path/acme-v02.api.letsencrypt.org-directory/$domain/$domain.crt|$base_path/acme-v02.api.letsencrypt.org-directory/$domain/$domain.key"
    return 1
}

# 生成隨機密碼（格式：xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxx）
generate_random_password() {
    # 僅使用小寫字母和數字，避免特殊字符
    local part1=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)
    local part2=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)
    local part3=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)
    local part4=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)
    local part5=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 11)
    echo "${part1}-${part2}-${part3}-${part4}-${part5}"
}


# 使用官方通用腳本自動安裝 Docker
install_docker() {
    log INFO "偵測到 Docker 未安裝，正在使用官方通用腳本進行安裝..."
    log INFO "這將確保對各種 Linux 發行版的最佳兼容性。"
    
    # 從 get.docker.com 下載並執行官方安裝腳本
    if ! curl -fsSL https://get.docker.com | sh; then
        log ERROR "Docker 安裝失敗。請檢查上面的日誌輸出，或嘗試手動運行 'curl -fsSL https://get.docker.com | sh' 來獲取更詳細的錯誤信息。"
        exit 1
    fi
    
    log INFO "正在啟動並設定 Docker 開機自啟..."
    if ! systemctl start docker; then
        log ERROR "無法啟動 Docker 服務。請使用 'systemctl status docker' 檢查狀態。"
        exit 1
    fi
    systemctl enable docker
    log INFO "Docker 安裝成功並已啟動。"
}

# 檢查 root 權限
check_root() { if [ "$EUID" -ne 0 ]; then log ERROR "此腳本必須以 root 身份運行。請使用 'sudo'。"; exit 1; fi; }

# 檢查並整備 Docker 環境
check_docker() {
    # 關鍵步驟：僅在 'docker' 命令不存在時，才觸發安裝流程。
    if ! command -v docker &>/dev/null; then
        install_docker
    fi
    
    # 檢查 Docker 服務是否正在運行
    if ! docker info >/dev/null 2>&1; then
        log WARN "Docker 服務未運行，正在嘗試啟動..."
        systemctl start docker
        sleep 3 # 等待服務完全啟動
        if ! docker info >/dev/null 2>&1; then
            log ERROR "無法啟動 Docker 服務，請手動檢查 ('systemctl status docker' 或 'journalctl -xeu docker.service')。"
            exit 1
        fi
        log INFO "Docker 服務已成功啟動。"
    fi
}

# 檢查可用的文字編輯器
check_editor() {
    for editor in nano vi vim; do
        if command -v $editor &>/dev/null; then EDITOR=$editor; return 0; fi
    done
    log ERROR "未找到合適的文字編輯器 (nano, vi, vim)。"; return 1
}

# 檢查容器是否存在
container_exists() { docker ps -a --format '{{.Names}}' | grep -q "^${1}$"; }

# 等待用戶按鍵繼續
press_any_key() { echo ""; read -p "按 Enter 鍵返回..." < /dev/tty; }

# 生成 Caddyfile 設定檔（多域名+反向代理模式）
generate_caddy_config() {
    local primary_domain="$1"
    local email="$2"
    local log_mode="$3"
    local proxy_domain="$4"
    local backend_service="$5"
    
    mkdir -p "${CADDY_CONFIG_DIR}"
    
    # 構建全局日誌配置
    local global_log_block=""
    if [[ ! "$log_mode" =~ ^[yY]$ ]]; then
        global_log_block=$(cat <<-'GLOBALLOG'

    # 全局日誌配置
    log {
        output stderr
        level  ERROR
    }
GLOBALLOG
)
    fi
    
    # 開始生成 Caddyfile
    cat > "${CADDY_CONFIG_FILE}" <<EOF
# 全局選項塊
{
    # 全局配置 ACME 證書申請郵箱
    email ${email}
${global_log_block}

    # 服務器協議設置 (一個務實的選擇，可根據環境移除)
    servers {
        protocols h1 h2
    }
}

# 主要網站服務
${primary_domain} {
    # 反向代理到後端 app，並傳遞必要的頭部信息以確保兼容性
    reverse_proxy ${backend_service} {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }
}
EOF

    # 如果提供了代理偽裝域名，添加配置
    if [ -n "$proxy_domain" ]; then
        cat >> "${CADDY_CONFIG_FILE}" <<EOF

# 代理偽裝服務 (作為主站的鏡像或別名)
${proxy_domain} {
    # 將流量代理到主站，並正確設置 Host 頭以避免循環
    reverse_proxy https://${primary_domain} {
        header_up Host {upstream_hostport}
    }
}
EOF
    fi
    
    log INFO "已為域名 ${primary_domain}$([ -n "$proxy_domain" ] && echo " 和 ${proxy_domain}") 建立 Caddyfile 設定檔。"
}

# 生成 Hysteria 設定檔
generate_hysteria_config() {
    local domain="$1" 
    local password="$2" 
    local log_mode="$3"
    
    mkdir -p "${HYSTERIA_CONFIG_DIR}"
    local log_level="error"
    if [[ "$log_mode" =~ ^[yY]$ ]]; then 
        log_level="info"
    fi
    
    # 動態檢測證書路徑
    local cert_path_info
    cert_path_info=$(detect_cert_path "$domain")
    local cert_path="${cert_path_info%%|*}"
    local key_path="${cert_path_info##*|}"
    
    cat > "${HYSTERIA_CONFIG_FILE}" <<EOF
listen: :443
logLevel: ${log_level}
# DNS 配置：優先使用 AdGuard Home 進行廣告過濾
# 注意：此配置作為應用層 DNS，配合 Docker --dns 參數實現雙重保障
resolvePreference: IPv4
dns:
  server: udp://${ADGUARD_CONTAINER_NAME}:53
  timeout: 4s
auth:
  type: password
  password: ${password}
# 注意：以下證書路徑基於 Caddy 使用 Let's Encrypt 作為 ACME 簽發機構。
# 如果 Caddy 自動切換到 ZeroSSL 等其他機構，此路徑可能需要手動更新。
tls:
  cert: ${cert_path}
  key: ${key_path}
outbounds:
  - name: direct
    type: direct
  - name: warp
    type: socks5
    socks5:
      addr: ${WARP_CONTAINER_NAME}:8008
acl:
  inline:
    - direct(suffix:youtube.com)
    - direct(suffix:youtu.be)
    - direct(suffix:ytimg.com)
    - direct(suffix:googlevideo.com)
    - direct(suffix:github.com)
    - direct(suffix:github.io)
    - direct(suffix:githubassets.com)
    - direct(suffix:githubusercontent.com)
    - warp(all)
EOF
    log INFO "Hysteria 的 config.yaml 已建立，日誌級別設定為 '${log_level}'，使用證書: ${cert_path}";
}

# 管理 Caddy
manage_caddy() {
    if ! container_exists "$CADDY_CONTAINER_NAME"; then
        while true; do
            clear; log INFO "--- 管理 Caddy (未安裝) ---"
            echo " 1. 安裝 Caddy (用於自動申請SSL證書)"
            echo " 0. 返回主選單"
            read -p "請輸入選項: " choice < /dev/tty
            case "$choice" in
                1)
                    log INFO "--- 正在安裝 Caddy ---"
                    
                    # 輸入主域名並驗證
                    while true; do
                        read -p "請輸入主域名（用於主要服務，必須指向本機IP）: " PRIMARY_DOMAIN < /dev/tty
                        if [ -z "$PRIMARY_DOMAIN" ]; then
                            log ERROR "主域名不能為空。"
                            continue
                        fi
                        if validate_domain "$PRIMARY_DOMAIN"; then
                            break
                        fi
                    done
                    
                    # 輸入郵箱並驗證
                    while true; do
                        read -p "請輸入您的郵箱（用於SSL證書申請與續期通知）: " EMAIL < /dev/tty
                        if [ -z "$EMAIL" ]; then
                            log ERROR "郵箱不能為空。"
                            continue
                        fi
                        if validate_email "$EMAIL"; then
                            break
                        fi
                    done
                    
                    # 輸入後端服務地址並驗證
                    read -p "請輸入後端服務地址（格式: hostname:port，例如 app:80）[預設: app:80]: " BACKEND_SERVICE < /dev/tty
                    BACKEND_SERVICE=${BACKEND_SERVICE:-app:80}
                    if ! validate_backend_service "$BACKEND_SERVICE"; then
                        log ERROR "後端服務地址格式錯誤，安裝中止。"
                        press_any_key
                        continue
                    fi
                    
                    # 輸入代理偽裝域名（強制必填）
                    while true; do
                        read -p "請輸入代理域名（必須指向本機IP）: " PROXY_DOMAIN < /dev/tty
                        if [ -z "$PROXY_DOMAIN" ]; then
                            log ERROR "代理域名不能為空。"
                            continue
                        fi
                        if validate_domain "$PROXY_DOMAIN"; then
                            break
                        fi
                    done
                    
                    
                    # 詢問日誌模式
                    read -p "是否為 Caddy 啟用詳細日誌？(用於排錯，預設為否) (y/N): " LOG_MODE < /dev/tty
                    
                    # 生成配置文件
                    generate_caddy_config "$PRIMARY_DOMAIN" "$EMAIL" "$LOG_MODE" "$PROXY_DOMAIN" "$BACKEND_SERVICE"
                    
                    # 拉取最新镜像
                    log INFO "正在拉取最新的 Caddy 镜像..."
                    if docker pull "${CADDY_IMAGE_NAME}"; then
                        log INFO "Caddy 镜像已更新到最新版本"
                    else
                        log WARN "镜像拉取失败，将使用本地缓存版本"
                    fi
                    
                    # 創建網路並部署容器
                    docker network create "${SHARED_NETWORK_NAME}" &>/dev/null
                    docker network create "web-services" &>/dev/null
                    
                    # Caddy 連接到兩個網路：hwc-proxy-net 和 web-services
                    # 注意：docker run 只能指定一個 --network，第二個網絡需使用 docker network connect
                    CADDY_CMD=(docker run -d --name "${CADDY_CONTAINER_NAME}" --restart always --network "${SHARED_NETWORK_NAME}" -p 80:80/tcp -p 443:443/tcp -v "${CADDY_CONFIG_FILE}:/etc/caddy/Caddyfile:ro" -v "${CADDY_DATA_VOLUME}:/data" "${CADDY_IMAGE_NAME}")
                    
                    if "${CADDY_CMD[@]}"; then
                        # 連接到第二個網絡（用於訪問後端服務）
                        if docker network connect "web-services" "${CADDY_CONTAINER_NAME}" 2>/dev/null; then
                            log INFO "Caddy 部署成功，已連接到 ${SHARED_NETWORK_NAME} 和 web-services 網絡。正在後台申請證書，請稍候..."
                        else
                            log WARN "Caddy 已啟動，但連接 web-services 網絡失敗，後端服務可能無法訪問。"
                        fi
                    else 
                        log ERROR "Caddy 部署失敗，正在清理..."
                        docker rm -f "${CADDY_CONTAINER_NAME}" 2>/dev/null
                        rm -rf "${CADDY_CONFIG_DIR}"
                    fi
                    press_any_key; break;;
                0) break;;
                *) log ERROR "無效輸入!"; sleep 1;;
            esac
        done
    else
        while true; do
            clear; log INFO "--- 管理 Caddy (已安裝) ---"
            echo " 1. 查看日誌"; echo " 2. 編輯 Caddyfile"; echo " 3. 重啟 Caddy 容器"; echo " 4. 卸載 Caddy"; echo " 0. 返回主選單"
            read -p "請輸入選項: " choice < /dev/tty
            case "$choice" in
                1) docker logs -f "$CADDY_CONTAINER_NAME"; press_any_key;;
                2) if check_editor; then "$EDITOR" "${CADDY_CONFIG_FILE}"; log INFO "設定已儲存。如需應用變更，請手動選擇重啟選項。"; fi; press_any_key;;
                3) log INFO "正在重啟 Caddy 容器..."; docker restart "$CADDY_CONTAINER_NAME"; sleep 2;;
                4)
                    log WARN "Hysteria 依賴 Caddy 提供證書，卸載 Caddy 將導致 Hysteria 無法工作。"
                    read -p "確定要卸載 Caddy 嗎? (y/N): " uninstall_choice < /dev/tty
                    if [[ "$uninstall_choice" =~ ^[yY]$ ]]; then
                        docker stop "${CADDY_CONTAINER_NAME}" &>/dev/null && docker rm "${CADDY_CONTAINER_NAME}" &>/dev/null
                        read -p "是否刪除 Caddy 的設定檔和數據卷(包含證書)？(y/N): " del_choice < /dev/tty
                        if [[ "$del_choice" =~ ^[yY]$ ]]; then rm -rf "${CADDY_CONFIG_DIR}"; docker volume rm "${CADDY_DATA_VOLUME}" &>/dev/null; log INFO "Caddy 的設定和數據已刪除。"; fi
                        log INFO "Caddy 已卸載。";
                    fi
                    press_any_key; break;;
                0) break;;
                *) log ERROR "無效輸入!"; sleep 1;;
            esac
        done
    fi
}

# 管理 WARP
manage_warp() {
    if ! container_exists "$WARP_CONTAINER_NAME"; then
        while true; do
            clear; log INFO "--- 管理 WARP (未安裝) ---"
            echo " 1. 安裝 WARP (免費版)"; echo " 0. 返回主選單"
            read -p "請輸入選項: " choice < /dev/tty
            case "$choice" in
                1)
                    log INFO "--- 正在安裝 WARP ---"
                    
                    # 拉取最新镜像
                    log INFO "正在拉取最新的 WARP 镜像..."
                    if docker pull "${WARP_IMAGE_NAME}"; then
                        log INFO "WARP 镜像已更新到最新版本"
                    else
                        log WARN "镜像拉取失败，将使用本地缓存版本"
                    fi
                    
                    docker network create "${SHARED_NETWORK_NAME}" &>/dev/null
                    WARP_CMD=(docker run -d --name "${WARP_CONTAINER_NAME}" --restart always --network "${SHARED_NETWORK_NAME}" -v "${WARP_VOLUME_PATH}:/var/lib/cloudflare-warp" --cap-add=MKNOD --cap-add=AUDIT_WRITE --cap-add=NET_ADMIN --device-cgroup-rule='c 10:200 rwm' --sysctl net.ipv6.conf.all.disable_ipv6=0 --sysctl net.ipv4.conf.all.src_valid_mark=1 "${WARP_IMAGE_NAME}")
                    if "${WARP_CMD[@]}"; then log INFO "WARP 部署成功。"; else log ERROR "WARP 部署失敗。"; fi
                    press_any_key; break;;
                0) break;;
                *) log ERROR "無效輸入!"; sleep 1;;
            esac
        done
    else
         while true; do
            clear; log INFO "--- 管理 WARP (已安裝) ---"
            echo " 1. 查看日誌"; echo " 2. 重啟 WARP 容器"; echo " 3. 卸載 WARP"; echo " 0. 返回主選單"
            read -p "請輸入選項: " choice < /dev/tty
            case "$choice" in
                1) docker logs -f "$WARP_CONTAINER_NAME"; press_any_key;;
                2) log INFO "正在重啟 WARP 容器..."; docker restart "$WARP_CONTAINER_NAME"; sleep 2;;
                3)
                    log WARN "Hysteria 依賴 WARP 作為網路出口，卸載 WARP 將導致 Hysteria 無法工作。"
                    read -p "確定要卸載 WARP 嗎? (y/N): " uninstall_choice < /dev/tty
                    if [[ "$uninstall_choice" =~ ^[yY]$ ]]; then
                        docker stop "${WARP_CONTAINER_NAME}" &>/dev/null && docker rm "${WARP_CONTAINER_NAME}" &>/dev/null
                        rm -rf "${WARP_VOLUME_PATH}"
                        log INFO "WARP 已卸載，本地數據已清除。";
                    fi
                    press_any_key; break;;
                0) break;;
                *) log ERROR "無效輸入!"; sleep 1;;
            esac
        done
    fi
}

# 管理 Hysteria
manage_hysteria() {
    if ! container_exists "$HYSTERIA_CONTAINER_NAME"; then
        while true; do
            clear; log INFO "--- 管理 Hysteria (未安裝) ---"
            echo " 1. 安裝 Hysteria"; echo " 0. 返回主選單"
            read -p "請輸入選項: " choice < /dev/tty
            case "$choice" in
                1)
                    if ! container_exists "$CADDY_CONTAINER_NAME" || ! container_exists "$WARP_CONTAINER_NAME"; then 
                        log ERROR "依賴項缺失！請務必先安裝 Caddy 和 WARP。"
                        press_any_key
                        continue
                    fi
                    
                    log INFO "--- 正在安裝 Hysteria ---"
                    
                    # 從 Caddyfile 中提取所有域名
                    local available_domains
                    available_domains=$(awk 'NR>1 && NF>=2 && $2=="{" {print $1}' "${CADDY_CONFIG_FILE}" 2>/dev/null | tr '\n' ' ')
                    
                    local HY_DOMAIN=""
                    if [ -n "$available_domains" ]; then
                        log INFO "檢測到以下域名: $available_domains"
                        read -p "請選擇 Hysteria 使用的域名（用於證書）[預設: 代理域名]: " HY_DOMAIN < /dev/tty
                        if [ -z "$HY_DOMAIN" ]; then
                            HY_DOMAIN=$(echo "$available_domains" | awk '{print $2}')
                        fi
                    else
                        read -p "請輸入 Hysteria 使用的域名（必須與 Caddy 配置的域名一致）: " HY_DOMAIN < /dev/tty
                    fi
                    
                    # 驗證域名
                    if [ -z "$HY_DOMAIN" ]; then
                        log ERROR "域名不能為空。"
                        press_any_key
                        continue
                    fi
                    if ! validate_domain "$HY_DOMAIN"; then
                        press_any_key
                        continue
                    fi
                    
                    # 密碼生成/輸入邏輯
                    read -p "是否手動輸入密碼？(預設為否，自動生成密碼) (y/N): " MANUAL_PASSWORD < /dev/tty
                    
                    if [[ "$MANUAL_PASSWORD" =~ ^[yY]$ ]]; then
                        # 手動輸入密碼（顯示輸入）
                        while true; do
                            read -p "請為 Hysteria 設定一個連接密碼: " PASSWORD < /dev/tty
                            if [ -z "$PASSWORD" ]; then
                                log ERROR "密碼不能為空。"
                                continue
                            fi
                            if [[ ${#PASSWORD} -lt 12 ]]; then
                                log WARN "密碼長度建議至少 12 個字符以提高安全性。"
                            fi
                            log INFO "您設定的密碼為: ${FontColor_Yellow}${PASSWORD}${FontColor_Suffix}"
                            break
                        done
                    else
                        # 自動生成密碼
                        PASSWORD=$(generate_random_password)
                        log INFO "已自動生成連接密碼: ${FontColor_Yellow}${PASSWORD}${FontColor_Suffix}"
                        log WARN "請妥善保存此密碼，稍後需要配置客戶端時使用。"
                    fi
                    
                    # 詢問日誌模式
                    read -p "是否為 Hysteria 啟用詳細日誌？(預設為否) (y/N): " LOG_MODE < /dev/tty
                    
                    # 拉取最新镜像
                    log INFO "正在拉取最新的 Hysteria 镜像..."
                    if docker pull "${HYSTERIA_IMAGE_NAME}"; then
                        log INFO "Hysteria 镜像已更新到最新版本"
                    else
                        log WARN "镜像拉取失败，将使用本地缓存版本"
                    fi
                    
                    # 生成配置並部署
                    generate_hysteria_config "$HY_DOMAIN" "$PASSWORD" "$LOG_MODE"
                    
                    # --- AdGuard DNS 注入邏輯 ---
                    local DNS_ARG=""
                    if container_exists "$ADGUARD_CONTAINER_NAME"; then
                        # 檢測 AdGuard 是否運行
                        if [ "$(docker inspect -f '{{.State.Running}}' "$ADGUARD_CONTAINER_NAME" 2>/dev/null)" = "true" ]; then
                            # 獲取 AdGuard IP 地址
                            local AG_IP
                            AG_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$ADGUARD_CONTAINER_NAME" 2>/dev/null | awk '{print $1}')
                            
                            if [ -n "$AG_IP" ]; then
                                DNS_ARG="--dns=${AG_IP}"
                                log INFO "檢測到 AdGuard Home (IP: ${AG_IP})，將強制 Hysteria 使用此 DNS 進行廣告過濾。"
                            else
                                log WARN "無法獲取 AdGuard Home IP，Hysteria 將使用系統預設 DNS。"
                            fi
                        else
                            log WARN "AdGuard Home 容器未運行，Hysteria 將使用系統預設 DNS。"
                        fi
                    else
                        log WARN "未安裝 AdGuard Home，Hysteria 將使用系統預設 DNS（無廣告過濾）。"
                        log INFO "提示：您可以先安裝 AdGuard Home，然後重新部署 Hysteria 以啟用廣告過濾。"
                    fi
                    # --- DNS 注入結束 ---
                    
                    # 部署 Hysteria 容器（含 DNS 配置）
                    HY_CMD=(docker run -d --name "${HYSTERIA_CONTAINER_NAME}" --restart always --network "${SHARED_NETWORK_NAME}" ${DNS_ARG} --memory=512m -v "${HYSTERIA_CONFIG_FILE}:/config.yaml:ro" -v "${CADDY_DATA_VOLUME}:/data:ro" -p 443:443/udp "${HYSTERIA_IMAGE_NAME}" server -c /config.yaml)
                    
                    if "${HY_CMD[@]}"; then 
                        log INFO "Hysteria 部署成功。"
                        
                        # 驗證 DNS 配置是否生效
                        sleep 3
                        if [ -n "$DNS_ARG" ]; then
                            local resolv_conf
                            resolv_conf=$(docker exec "${HYSTERIA_CONTAINER_NAME}" cat /etc/resolv.conf 2>/dev/null | grep "nameserver")
                            if echo "$resolv_conf" | grep -q "${AG_IP}"; then
                                log INFO "✓ DNS 注入成功：Hysteria 已配置使用 AdGuard Home (${AG_IP})"
                            else
                                log WARN "DNS 注入可能未完全生效，請檢查：docker exec ${HYSTERIA_CONTAINER_NAME} cat /etc/resolv.conf"
                            fi
                        fi
                        
                        # 檢查容器日誌是否有錯誤
                        if docker logs "${HYSTERIA_CONTAINER_NAME}" 2>&1 | grep -qi "error\|failed"; then
                            log WARN "Hysteria 容器可能遇到問題，請檢查日誌: docker logs ${HYSTERIA_CONTAINER_NAME}"
                        fi
                    else 
                        log ERROR "Hysteria 部署失敗，正在清理..."
                        docker rm -f "${HYSTERIA_CONTAINER_NAME}" 2>/dev/null
                        rm -rf "${HYSTERIA_CONFIG_DIR}"
                    fi
                    press_any_key; break;;
                0) break;;
                *) log ERROR "無效輸入!"; sleep 1;;
            esac
        done
    else
        while true; do
            clear; log INFO "--- 管理 Hysteria (已安裝) ---"
            echo " 1. 查看日誌"; echo " 2. 編輯設定檔"; echo " 3. 重啟 Hysteria 容器"; echo " 4. 卸載 Hysteria"; echo " 0. 返回主選單"
            read -p "請輸入選項: " choice < /dev/tty
            case "$choice" in
                1) docker logs -f "$HYSTERIA_CONTAINER_NAME"; press_any_key;;
                2) if check_editor; then "$EDITOR" "${HYSTERIA_CONFIG_FILE}"; log INFO "設定已儲存。如需應用變更，請手動選擇重啟選項。"; fi; press_any_key;;
                3) log INFO "正在重啟 Hysteria 容器..."; docker restart "$HYSTERIA_CONTAINER_NAME"; sleep 2;;
                4)
                    read -p "確定要卸載 Hysteria 嗎? (y/N): " uninstall_choice < /dev/tty
                    if [[ "$uninstall_choice" =~ ^[yY]$ ]]; then
                        docker stop "${HYSTERIA_CONTAINER_NAME}" &>/dev/null && docker rm "${HYSTERIA_CONTAINER_NAME}" &>/dev/null
                        rm -rf "${HYSTERIA_CONFIG_DIR}"
                        log INFO "Hysteria 已卸載，設定檔已清除。";
                    fi
                    press_any_key; break;;
                0) break;;
                *) log ERROR "無效輸入!"; sleep 1;;
            esac
        done
    fi
}

# 管理 AdGuard Home
manage_adguard() {
    if ! container_exists "$ADGUARD_CONTAINER_NAME"; then
        while true; do
            clear; log INFO "--- 管理 AdGuard Home (未安裝) ---"
            echo " 1. 安裝 AdGuard Home (DNS 廣告過濾器)"
            echo " 0. 返回主選單"
            read -p "請輸入選項: " choice < /dev/tty
            case "$choice" in
                1)
                    log INFO "--- 正在安裝 AdGuard Home ---"
                    read -p "請為 AdGuard Home 的 Web 管理界面設定一個端口 [預設: 3000]: " WEB_PORT < /dev/tty
                    WEB_PORT=${WEB_PORT:-3000}
                    log WARN "DNS 服務將使用 53 端口。請確保主機的 53 端口未被 systemd-resolved 等服務占用。"
                    log WARN "如果 53 端口衝突導致安裝失敗，請先停用主機的 DNS 服務再重試。"
                    
                    # 拉取最新镜像
                    log INFO "正在拉取最新的 AdGuard Home 镜像..."
                    if docker pull "${ADGUARD_IMAGE_NAME}"; then
                        log INFO "AdGuard Home 镜像已更新到最新版本"
                    else
                        log WARN "镜像拉取失败，将使用本地缓存版本"
                    fi
                    
                    mkdir -p "${ADGUARD_CONFIG_DIR}" "${ADGUARD_WORK_DIR}"
                    docker network create "${SHARED_NETWORK_NAME}" &>/dev/null

                    # --- 已修改 ---
                    # 移除了 -p 53:53/tcp 和 -p 53:53/udp 
                    AG_CMD=(docker run -d --name "${ADGUARD_CONTAINER_NAME}" --restart always --network "${SHARED_NETWORK_NAME}" -v "${ADGUARD_WORK_DIR}:/opt/adguardhome/work" -v "${ADGUARD_CONFIG_DIR}:/opt/adguardhome/conf" -p "${WEB_PORT}:3000/tcp" "${ADGUARD_IMAGE_NAME}")

                    if "${AG_CMD[@]}"; then
                        log INFO "AdGuard Home 部署成功。"
                        log INFO "首次安裝後，請訪問 http://<您的伺服器IP>:${WEB_PORT} 進行初始化設定。"
                    else
                        log ERROR "AdGuard Home 部署失敗。請檢查端口是否衝突。"
                    fi
                    press_any_key; break;;
                0) break;;
                *) log ERROR "無效輸入!"; sleep 1;;
            esac
        done
    else
        while true; do
            clear; log INFO "--- 管理 AdGuard Home (已安裝) ---"
            echo " 1. 查看日誌"; echo " 2. 重啟 AdGuard Home 容器"; echo " 3. 卸載 AdGuard Home"; echo " 0. 返回主選單"
            read -p "請輸入選項: " choice < /dev/tty
            case "$choice" in
                1) docker logs -f "$ADGUARD_CONTAINER_NAME"; press_any_key;;
                2) log INFO "正在重啟 AdGuard Home 容器..."; docker restart "$ADGUARD_CONTAINER_NAME"; sleep 2;;
                3)
                    read -p "確定要卸載 AdGuard Home 嗎? (y/N): " uninstall_choice < /dev/tty
                    if [[ "$uninstall_choice" =~ ^[yY]$ ]]; then
                        docker stop "${ADGUARD_CONTAINER_NAME}" &>/dev/null && docker rm "${ADGUARD_CONTAINER_NAME}" &>/dev/null
                        read -p "是否刪除 AdGuard Home 的所有設定檔和數據？(y/N): " del_choice < /dev/tty
                        if [[ "$del_choice" =~ ^[yY]$ ]]; then rm -rf "${APP_BASE_DIR}/adguard"; log INFO "AdGuard Home 的設定和數據已刪除。"; fi
                        log INFO "AdGuard Home 已卸載。";
                    fi
                    press_any_key; break;;
                0) break;;
                *) log ERROR "無效輸入!"; sleep 1;;
            esac
        done
    fi
}

# (非互動式) 清除所有服務的日誌
clear_all_logs() {
    log INFO "正在清除所有已安裝服務容器的內部日誌..."
    for container in "$CADDY_CONTAINER_NAME" "$WARP_CONTAINER_NAME" "$HYSTERIA_CONTAINER_NAME" "$ADGUARD_CONTAINER_NAME"; do
        if container_exists "$container"; then
            log INFO "正在清除 ${container} 的日誌..."
            local log_path; log_path=$(docker inspect --format='{{.LogPath}}' "$container")
            if [ -f "$log_path" ] && ! truncate -s 0 "$log_path"; then log WARN "無法清空 ${container} 的日誌檔案: ${log_path}"; fi
        fi
    done
    log INFO "所有服務日誌已清空。"
}

# 重啟所有正在運行的服務
restart_all_services() {
    log INFO "正在重啟所有正在運行的容器..."
    local restarted=0
    for container in "$CADDY_CONTAINER_NAME" "$WARP_CONTAINER_NAME" "$HYSTERIA_CONTAINER_NAME" "$ADGUARD_CONTAINER_NAME"; do
        if container_exists "$container" && [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = "true" ]; then
            log INFO "正在重啟 ${container}..."
            docker restart "$container" &>/dev/null
            restarted=$((restarted + 1))
        fi
    done
    if [ "$restarted" -eq 0 ]; then log WARN "沒有正在運行的容器可供重啟。"; else log INFO "所有正在運行的容器已成功發出重啟命令。"; fi
}

# 組合函數：清理日誌並重啟服務
clear_logs_and_restart_all() {
    clear_all_logs
    log INFO "3秒後將自動重啟所有正在運行的服務..."
    sleep 3
    restart_all_services
}

# 卸載所有服務
uninstall_all_services() {
    log WARN "此操作將不可逆地刪除 Caddy, WARP, Hysteria, AdGuard Home 的容器、設定檔、數據卷和網路！"
    read -p "您確定要徹底清理所有服務嗎? (y/N): " choice < /dev/tty
    if [[ ! "$choice" =~ ^[yY]$ ]]; then log INFO "操作已取消。"; return; fi

    log INFO "正在停止並刪除所有服務容器..."
    docker stop "${CADDY_CONTAINER_NAME}" "${WARP_CONTAINER_NAME}" "${HYSTERIA_CONTAINER_NAME}" "${ADGUARD_CONTAINER_NAME}" &>/dev/null
    docker rm "${CADDY_CONTAINER_NAME}" "${WARP_CONTAINER_NAME}" "${HYSTERIA_CONTAINER_NAME}" "${ADGUARD_CONTAINER_NAME}" &>/dev/null
    log INFO "所有容器已刪除。"

    log INFO "正在刪除本地設定檔和數據..."; rm -rf "${APP_BASE_DIR}"; log INFO "本地設定檔和數據目錄 (${APP_BASE_DIR}) 已刪除。"
    log INFO "正在刪除 Docker 數據卷..."; docker volume rm "${CADDY_DATA_VOLUME}" &>/dev/null; log INFO "Docker 數據卷已刪除。"
    log INFO "正在刪除共享網路..."; docker network rm "${SHARED_NETWORK_NAME}" &>/dev/null; log INFO "共享網路已刪除。"
    log INFO "所有服務已徹底清理完畢。"
}

# 檢查所有服務的狀態
check_all_status() {
    local containers=("$CADDY_CONTAINER_NAME" "$WARP_CONTAINER_NAME" "$HYSTERIA_CONTAINER_NAME" "$ADGUARD_CONTAINER_NAME")
    for container in "${containers[@]}"; do
        if ! container_exists "$container"; then
            CONTAINER_STATUSES["$container"]="${FontColor_Red}未安裝${FontColor_Suffix}"
        else
            local status; status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null)
            if [ "$status" = "running" ]; then CONTAINER_STATUSES["$container"]="${FontColor_Green}運行中${FontColor_Suffix}"; else CONTAINER_STATUSES["$container"]="${FontColor_Red}異常 (${status})${FontColor_Suffix}"; fi
        fi
    done
}

# 主選單
start_menu() {
    while true; do
        check_all_status
        clear
        echo -e "\n${FontColor_Purple}Caddy + WARP + Hysteria + AdGuard 終極管理腳本${FontColor_Suffix} (v5.6.0)"
        echo -e "  快捷命令: ${FontColor_Yellow}hwc${FontColor_Suffix}"
        echo -e "  設定目錄: ${FontColor_Yellow}${APP_BASE_DIR}${FontColor_Suffix}"
        echo -e " --------------------------------------------------"
        echo -e "  Caddy 服務        : ${CONTAINER_STATUSES[$CADDY_CONTAINER_NAME]}"
        echo -e "  WARP 服務         : ${CONTAINER_STATUSES[$WARP_CONTAINER_NAME]}"
        echo -e "  Hysteria 服務     : ${CONTAINER_STATUSES[$HYSTERIA_CONTAINER_NAME]}"
        echo -e "  AdGuard Home 服務 : ${CONTAINER_STATUSES[$ADGUARD_CONTAINER_NAME]}"
        echo -e " --------------------------------------------------\n"
        echo -e " ${FontColor_Green}1.${FontColor_Suffix} 管理 Caddy..."
        echo -e " ${FontColor_Green}2.${FontColor_Suffix} 管理 WARP..."
        echo -e " ${FontColor_Green}3.${FontColor_Suffix} 管理 Hysteria..."
        echo -e " ${FontColor_Green}4.${FontColor_Suffix} 管理 AdGuard Home...\n"
        echo -e " ${FontColor_Yellow}5.${FontColor_Suffix} 清理日誌並重啟所有服務"
        echo -e " ${FontColor_Red}6.${FontColor_Suffix} 徹底清理所有服務\n"
        echo -e " ${FontColor_Yellow}0.${FontColor_Suffix} 退出腳本\n"
        read -p " 請輸入選項 [0-6]: " num < /dev/tty
        case "$num" in
            1) manage_caddy;; 2) manage_warp;; 3) manage_hysteria;; 4) manage_adguard;;
            5) clear_logs_and_restart_all; press_any_key;;
            6) uninstall_all_services; press_any_key;;
            0) exit 0;;
            *) log ERROR "無效輸入!"; sleep 2;;
        esac
    done
}

# --- 第3節：腳本入口 (主邏輯) ---
clear
cat <<-'EOM'
  ____      _        __          __      _   _             _             _
 / ___|__ _| |_ __ _ \ \        / /     | | | |           | |           (_)
| |   / _` | __/ _` | \ \  /\  / /  __ _| |_| |_ ___ _ __ | |_ __ _ _ __ _  ___
| |__| (_| | || (_| |  \ \/  \/ /  / _` | __| __/ _ \ '_ \| __/ _` | '__| |/ __|
 \____\__,_|\__\__,_|   \  /\  /  | (_| | |_| ||  __/ | | | || (_| | |  | | (__
                        \/  \/    \__,_|\__|\__\___|_| |_|\__\__,_|_|  |_|\___|
EOM
echo -e "${FontColor_Purple}Caddy + WARP + Hysteria + AdGuard 終極一鍵管理腳本${FontColor_Suffix}"
echo "----------------------------------------------------------------"

check_root
self_install
check_docker
mkdir -p "${APP_BASE_DIR}"
start_menu
