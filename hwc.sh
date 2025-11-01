#!/usr/bin/env bash
#
# Description: Ultimate All-in-One Manager for Caddy, WARP & Hysteria with self-installing shortcut.
# Author: Your Name (Inspired by P-TERX)
# Version: 5.5.2 (Pre-Install Cleanup Fix)

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

# 固定的應用程式基礎目錄
APP_BASE_DIR="/root/hwc"
CADDY_CONTAINER_NAME="caddy-manager"; CADDY_IMAGE_NAME="caddy:latest"; CADDY_CONFIG_DIR="${APP_BASE_DIR}/caddy"; CADDY_CONFIG_FILE="${CADDY_CONFIG_DIR}/Caddyfile"; CADDY_DATA_VOLUME="hwc_caddy_data"
WARP_CONTAINER_NAME="warp-docker"; WARP_IMAGE_NAME="ghcr.io/105pm/docker-warproxy:latest"; WARP_VOLUME_PATH="${APP_BASE_DIR}/warp-data"
HYSTERIA_CONTAINER_NAME="hysteria-server"; HYSTERIA_IMAGE_NAME="tobyxdd/hysteria"; HYSTERIA_CONFIG_DIR="${APP_BASE_DIR}/hysteria"; HYSTERIA_CONFIG_FILE="${HYSTERIA_CONFIG_DIR}/config.yaml"
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
    if ! command -v curl &>/dev/null; then
        log WARN "'curl' 未安裝，正在嘗試安裝..."
        if command -v apt-get &>/dev/null; then apt-get update && apt-get install -y --no-install-recommends curl; fi
        if command -v yum &>/dev/null || command -v dnf &>/dev/null; then 
            command -v yum &>/dev/null && yum install -y curl || dnf install -y curl
        fi
    fi
    if curl -sSL "${SCRIPT_URL}" -o "${SHORTCUT_PATH}"; then
        chmod +x "${SHORTCUT_PATH}"
        log INFO "快捷命令 'hwc' 安裝成功。正在從新位置重新啟動..."
        exec "${SHORTCUT_PATH}" "$@"
    else
        log ERROR "無法安裝 'hwc' 快捷命令至 ${SHORTCUT_PATH}。"; log WARN "本次將臨時運行腳本，請檢查權限後重試。"; sleep 3
    fi
}

# 清理先前失敗的 Docker 安裝殘留
cleanup_previous_failed_install() {
    log INFO "正在檢查並清理先前可能失敗的安裝殘留..."
    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /etc/apt/keyrings/docker.gpg
    # 執行一次 apt update 以確保系統軟體源狀態正常
    apt-get update >/dev/null
}

# 使用官方通用腳本自動安裝 Docker
install_docker() {
    log INFO "偵測到 Docker 未安裝，正在嘗試自動安裝..."
    
    # *** 關鍵修復步驟 ***
    cleanup_previous_failed_install
    
    log INFO "正在使用官方通用腳本進行安裝，以確保最佳兼容性..."
    if ! curl -fsSL https://get.docker.com | sh; then
        log ERROR "Docker 安裝失敗。請檢查上面的日誌輸出，或嘗試手動運行 'curl -fsSL https://get.docker.com | sh'。"
        exit 1
    fi
    
    log INFO "正在啟動並設定 Docker 開機自啟..."
    if ! systemctl start docker; then
        log ERROR "無法啟動 Docker 服務。請使用 'systemctl status docker' 檢查狀態。"; exit 1
    fi
    systemctl enable docker
    log INFO "Docker 安裝成功並已啟動。"
}

# 檢查 root 權限
check_root() { if [ "$EUID" -ne 0 ]; then log ERROR "此腳本必須以 root 身份運行。請使用 'sudo'。"; exit 1; fi; }

# 檢查並整備 Docker 環境
check_docker() {
    if ! command -v docker &>/dev/null; then
        install_docker
    fi
    if ! docker info >/dev/null 2>&1; then
        log WARN "Docker 服務未運行，正在嘗試啟動..."; systemctl start docker; sleep 3
        if ! docker info >/dev/null 2>&1; then
            log ERROR "無法啟動 Docker 服務，請手動檢查 ('systemctl status docker' 或 'journalctl -xeu docker.service')。"; exit 1
        fi
        log INFO "Docker 服務已成功啟動。"
    fi
}

# 檢查可用的文字編輯器
check_editor() { for editor in nano vi vim; do if command -v $editor &>/dev/null; then EDITOR=$editor; return 0; fi; done; log ERROR "未找到合適的文字編輯器 (nano, vi, vim)。"; return 1; }
# 檢查容器是否存在
container_exists() { docker ps -a --format '{{.Names}}' | grep -q "^${1}$"; }
# 等待用戶按鍵繼續
press_any_key() { echo ""; read -p "按 Enter 鍵返回..." < /dev/tty; }

# [業務邏輯函數... 保持不變]
generate_caddy_config() { local domain="$1" email="$2" log_mode="$3"; mkdir -p "${CADDY_CONFIG_DIR}"; local log_block=""; if [[ ! "$log_mode" =~ ^[yY]$ ]]; then log_block=$(cat <<-LOG
    log {
        output stderr
        level  ERROR
    }
LOG
); fi; cat > "${CADDY_CONFIG_FILE}" << EOF
{
    email ${email}
}
${domain} {
${log_block}
    respond "服務正在運行。" 200
}
EOF
; log INFO "已為域名 ${domain} 建立 Caddyfile 設定檔。"; }
generate_hysteria_config() { local domain="$1" password="$2" log_mode="$3"; mkdir -p "${HYSTERIA_CONFIG_DIR}"; local log_level="error"; if [[ "$log_mode" =~ ^[yY]$ ]]; then log_level="info"; fi; cat > "${HYSTERIA_CONFIG_FILE}" << EOF
listen: :443
logLevel: ${log_level}
auth:
  type: password
  password: ${password}
# 注意：以下證書路徑基於 Caddy 使用 Let's Encrypt 作為 ACME 簽發機構。
tls:
  cert: /data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${domain}/${domain}.crt
  key: /data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${domain}/${domain}.key
outbounds:
  - name: direct
    type: direct
  - name: warp
    type: socks5
    socks5:
      addr: ${WARP_CONTAINER_NAME}:1080
acl:
  inline:
    - direct(suffix:youtube.com), direct(suffix:youtu.be), direct(suffix:ytimg.com), direct(suffix:googlevideo.com)
    - direct(suffix:github.com), direct(suffix:github.io), direct(suffix:githubassets.com), direct(suffix:githubusercontent.com)
    - warp(all)
EOF
; log INFO "Hysteria 的 config.yaml 已建立，日誌級別設定為 '${log_level}'。"; }
manage_caddy() { if ! container_exists "$CADDY_CONTAINER_NAME"; then while true; do clear; log INFO "--- 管理 Caddy (未安裝) ---"; echo " 1. 安裝 Caddy (用於自動申請SSL證書)"; echo " 0. 返回主選單"; read -p "請輸入選項: " choice < /dev/tty; case "$choice" in 1) log INFO "--- 正在安裝 Caddy ---"; read -p "請輸入 Caddy 將要管理的域名 (必須指向本機IP): " DOMAIN < /dev/tty; read -p "請輸入您的郵箱 (用於SSL證書申請與續期通知): " EMAIL < /dev/tty; if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then log ERROR "域名和郵箱不能為空。"; press_any_key; continue; fi; read -p "是否為 Caddy 啟用詳細日誌？(用於排錯，預設為否) (y/N): " LOG_MODE < /dev/tty; generate_caddy_config "$DOMAIN" "$EMAIL" "$LOG_MODE"; docker network create "${SHARED_NETWORK_NAME}" &>/dev/null; CADDY_CMD=(docker run -d --name "${CADDY_CONTAINER_NAME}" --restart always --network "${SHARED_NETWORK_NAME}" -p 80:80/tcp -p 443:443/tcp -v "${CADDY_CONFIG_FILE}:/etc/caddy/Caddyfile:ro" -v "${CADDY_DATA_VOLUME}:/data" "${CADDY_IMAGE_NAME}"); if "${CADDY_CMD[@]}"; then log INFO "Caddy 部署成功。正在後台申請證書，請稍候..."; else log ERROR "Caddy 部署失敗。"; fi; press_any_key; break;; 0) break;; *) log ERROR "無效輸入!"; sleep 1;; esac; done; else while true; do clear; log INFO "--- 管理 Caddy (已安裝) ---"; echo " 1. 查看日誌"; echo " 2. 編輯 Caddyfile"; echo " 3. 重啟 Caddy 容器"; echo " 4. 卸載 Caddy"; echo " 0. 返回主選單"; read -p "請輸入選項: " choice < /dev/tty; case "$choice" in 1) docker logs -f "$CADDY_CONTAINER_NAME"; press_any_key;; 2) if check_editor; then "$EDITOR" "${CADDY_CONFIG_FILE}"; log INFO "設定已儲存。如需應用變更，請手動選擇重啟選項。"; fi; press_any_key;; 3) log INFO "正在重啟 Caddy 容器..."; docker restart "$CADDY_CONTAINER_NAME"; sleep 2;; 4) log WARN "Hysteria 依賴 Caddy 提供證書，卸載 Caddy 將導致 Hysteria 無法工作。"; read -p "確定要卸載 Caddy 嗎? (y/N): " uninstall_choice < /dev/tty; if [[ "$uninstall_choice" =~ ^[yY]$ ]]; then docker stop "${CADDY_CONTAINER_NAME}" &>/dev/null && docker rm "${CADDY_CONTAINER_NAME}" &>/dev/null; read -p "是否刪除 Caddy 的設定檔和數據卷(包含證書)？(y/N): " del_choice < /dev/tty; if [[ "$del_choice" =~ ^[yY]$ ]]; then rm -rf "${CADDY_CONFIG_DIR}"; docker volume rm "${CADDY_DATA_VOLUME}" &>/dev/null; log INFO "Caddy 的設定和數據已刪除。"; fi; log INFO "Caddy 已卸載。"; fi; press_any_key; break;; 0) break;; *) log ERROR "無效輸入!"; sleep 1;; esac; done; fi; }
manage_warp() { if ! container_exists "$WARP_CONTAINER_NAME"; then while true; do clear; log INFO "--- 管理 WARP (未安裝) ---"; echo " 1. 安裝 WARP (免費版)"; echo " 0. 返回主選單"; read -p "請輸入選項: " choice < /dev/tty; case "$choice" in 1) log INFO "--- 正在安裝 WARP ---"; docker network create "${SHARED_NETWORK_NAME}" &>/dev/null; WARP_CMD=(docker run -d --name "${WARP_CONTAINER_NAME}" --restart always --network "${SHARED_NETWORK_NAME}" -v "${WARP_VOLUME_PATH}:/var/lib/cloudflare-warp" --cap-add=MKNOD --cap-add=AUDIT_WRITE --cap-add=NET_ADMIN --device-cgroup-rule='c 10:200 rwm' --sysctl net.ipv6.conf.all.disable_ipv6=0 --sysctl net.ipv4.conf.all.src_valid_mark=1 "${WARP_IMAGE_NAME}"); if "${WARP_CMD[@]}"; then log INFO "WARP 部署成功。"; else log ERROR "WARP 部署失敗。"; fi; press_any_key; break;; 0) break;; *) log ERROR "無效輸入!"; sleep 1;; esac; done; else while true; do clear; log INFO "--- 管理 WARP (已安裝) ---"; echo " 1. 查看日誌"; echo " 2. 重啟 WARP 容器"; echo " 3. 卸載 WARP"; echo " 0. 返回主選單"; read -p "請輸入選項: " choice < /dev/tty; case "$choice" in 1) docker logs -f "$WARP_CONTAINER_NAME"; press_any_key;; 2) log INFO "正在重啟 WARP 容器..."; docker restart "$WARP_CONTAINER_NAME"; sleep 2;; 3) log WARN "Hysteria 依賴 WARP 作為網路出口，卸載 WARP 將導致 Hysteria 無法工作。"; read -p "確定要卸載 WARP 嗎? (y/N): " uninstall_choice < /dev/tty; if [[ "$uninstall_choice" =~ ^[yY]$ ]]; then docker stop "${WARP_CONTAINER_NAME}" &>/dev/null && docker rm "${WARP_CONTAINER_NAME}" &>/dev/null; rm -rf "${WARP_VOLUME_PATH}"; log INFO "WARP 已卸載，本地數據已清除。"; fi; press_any_key; break;; 0) break;; *) log ERROR "無效輸入!"; sleep 1;; esac; done; fi; }
manage_hysteria() { if ! container_exists "$HYSTERIA_CONTAINER_NAME"; then while true; do clear; log INFO "--- 管理 Hysteria (未安裝) ---"; echo " 1. 安裝 Hysteria"; echo " 0. 返回主選單"; read -p "請輸入選項: " choice < /dev/tty; case "$choice" in 1) if ! container_exists "$CADDY_CONTAINER_NAME" || ! container_exists "$WARP_CONTAINER_NAME"; then log ERROR "依賴項缺失！請務必先安裝 Caddy 和 WARP。"; press_any_key; continue; fi; local caddy_domain; caddy_domain=$(awk 'NR>1 && NF==2 && $2=="{" {print $1; exit}' "${CADDY_CONFIG_FILE}" 2>/dev/null); log INFO "--- 正在安裝 Hysteria ---"; read -p "是否為 Hysteria 啟用詳細日誌？(預設為否) (y/N): " LOG_MODE < /dev/tty; if [ -n "$caddy_domain" ]; then read -p "請輸入您的域名 [預設: ${caddy_domain}]: " DOMAIN < /dev/tty; DOMAIN=${DOMAIN:-$caddy_domain}; else read -p "請輸入您的域名 (必須與Caddy設定的域名一致): " DOMAIN < /dev/tty; fi; read -p "請為 Hysteria 設定一個連接密碼: " PASSWORD < /dev/tty; if [ -z "$DOMAIN" ] || [ -z "$PASSWORD" ]; then log ERROR "域名和密碼為必填項。"; press_any_key; continue; fi; generate_hysteria_config "$DOMAIN" "$PASSWORD" "$LOG_MODE"; HY_CMD=(docker run -d --name "${HYSTERIA_CONTAINER_NAME}" --restart always --network "${SHARED_NETWORK_NAME}" --memory=256m -v "${HYSTERIA_CONFIG_FILE}:/config.yaml:ro" -v "${CADDY_DATA_VOLUME}:/data:ro" -p 443:443/udp "${HYSTERIA_IMAGE_NAME}" server -c /config.yaml); if "${HY_CMD[@]}"; then log INFO "Hysteria 部署成功。"; else log ERROR "Hysteria 部署失敗。"; fi; press_any_key; break;; 0) break;; *) log ERROR "無效輸入!"; sleep 1;; esac; done; else while true; do clear; log INFO "--- 管理 Hysteria (已安裝) ---"; echo " 1. 查看日誌"; echo " 2. 編輯設定檔"; echo " 3. 重啟 Hysteria 容器"; echo " 4. 卸載 Hysteria"; echo " 0. 返回主選單"; read -p "請輸入選項: " choice < /dev/tty; case "$choice" in 1) docker logs -f "$HYSTERIA_CONTAINER_NAME"; press_any_key;; 2) if check_editor; then "$EDITOR" "${HYSTERIA_CONFIG_FILE}"; log INFO "設定已儲存。如需應用變更，請手動選擇重啟選項。"; fi; press_any_key;; 3) log INFO "正在重啟 Hysteria 容器..."; docker restart "$HYSTERIA_CONTAINER_NAME"; sleep 2;; 4) read -p "確定要卸載 Hysteria 嗎? (y/N): " uninstall_choice < /dev/tty; if [[ "$uninstall_choice" =~ ^[yY]$ ]]; then docker stop "${HYSTERIA_CONTAINER_NAME}" &>/dev/null && docker rm "${HYSTERIA_CONTAINER_NAME}" &>/dev/null; rm -rf "${HYSTERIA_CONFIG_DIR}"; log INFO "Hysteria 已卸載，設定檔已清除。"; fi; press_any_key; break;; 0) break;; *) log ERROR "無效輸入!"; sleep 1;; esac; done; fi; }
clear_all_logs() { log INFO "正在清除所有已安裝服務容器的內部日誌..."; for container in "$CADDY_CONTAINER_NAME" "$WARP_CONTAINER_NAME" "$HYSTERIA_CONTAINER_NAME"; do if container_exists "$container"; then log INFO "正在清除 ${container} 的日誌..."; local log_path; log_path=$(docker inspect --format='{{.LogPath}}' "$container"); if [ -f "$log_path" ] && ! truncate -s 0 "$log_path"; then log WARN "無法清空 ${container} 的日誌檔案: ${log_path}"; fi; fi; done; log INFO "所有服務日誌已清空。"; }
restart_all_services() { log INFO "正在重啟所有正在運行的容器..."; local restarted=0; for container in "$CADDY_CONTAINER_NAME" "$WARP_CONTAINER_NAME" "$HYSTERIA_CONTAINER_NAME"; do if container_exists "$container" && [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = "true" ]; then log INFO "正在重啟 ${container}..."; docker restart "$container" &>/dev/null; restarted=$((restarted + 1)); fi; done; if [ "$restarted" -eq 0 ]; then log WARN "沒有正在運行的容器可供重啟。"; else log INFO "所有正在運行的容器已成功發出重啟命令。"; fi; }
clear_logs_and_restart_all() { clear_all_logs; log INFO "3秒後將自動重啟所有正在運行的服務..."; sleep 3; restart_all_services; }
uninstall_all_services() { log WARN "此操作將不可逆地刪除 Caddy, WARP, Hysteria 的容器、設定檔、數據卷和網路！"; read -p "您確定要徹底清理所有服務嗎? (y/N): " choice < /dev/tty; if [[ ! "$choice" =~ ^[yY]$ ]]; then log INFO "操作已取消。"; return; fi; log INFO "正在停止並刪除所有服務容器..."; docker stop "${CADDY_CONTAINER_NAME}" "${WARP_CONTAINER_NAME}" "${HYSTERIA_CONTAINER_NAME}" &>/dev/null; docker rm "${CADDY_CONTAINER_NAME}" "${WARP_CONTAINER_NAME}" "${HYSTERIA_CONTAINER_NAME}" &>/dev/null; log INFO "所有容器已刪除。"; log INFO "正在刪除本地設定檔和數據..."; rm -rf "${APP_BASE_DIR}"; log INFO "本地設定檔和數據目錄 (${APP_BASE_DIR}) 已刪除。"; log INFO "正在刪除 Docker 數據卷..."; docker volume rm "${CADDY_DATA_VOLUME}" &>/dev/null; log INFO "Docker 數據卷已刪除。"; log INFO "正在刪除共享網路..."; docker network rm "${SHARED_NETWORK_NAME}" &>/dev/null; log INFO "共享網路已刪除。"; log INFO "所有服務已徹底清理完畢。"; }
check_all_status() { local containers=("$CADDY_CONTAINER_NAME" "$WARP_CONTAINER_NAME" "$HYSTERIA_CONTAINER_NAME"); for container in "${containers[@]}"; do if ! container_exists "$container"; then CONTAINER_STATUSES["$container"]="${FontColor_Red}未安裝${FontColor_Suffix}"; else local status; status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null); if [ "$status" = "running" ]; then CONTAINER_STATUSES["$container"]="${FontColor_Green}運行中${FontColor_Suffix}"; else CONTAINER_STATUSES["$container"]="${FontColor_Red}異常 (${status})${FontColor_Suffix}"; fi; fi; done; }
start_menu() { while true; do check_all_status; clear; echo -e "\n${FontColor_Purple}Caddy + WARP + Hysteria 終極管理腳本${FontColor_Suffix} (v5.5.2)"; echo -e "  快捷命令: ${FontColor_Yellow}hwc${FontColor_Suffix}\n  設定目錄: ${FontColor_Yellow}${APP_BASE_DIR}${FontColor_Suffix}"; echo -e " --------------------------------------------------"; echo -e "  Caddy 服務      : ${CONTAINER_STATUSES[$CADDY_CONTAINER_NAME]}"; echo -e "  WARP 服務       : ${CONTAINER_STATUSES[$WARP_CONTAINER_NAME]}"; echo -e "  Hysteria 服務   : ${CONTAINER_STATUSES[$HYSTERIA_CONTAINER_NAME]}"; echo -e " --------------------------------------------------\n"; echo -e " ${FontColor_Green}1.${FontColor_Suffix} 管理 Caddy...\n ${FontColor_Green}2.${FontColor_Suffix} 管理 WARP...\n ${FontColor_Green}3.${FontColor_Suffix} 管理 Hysteria...\n"; echo -e " ${FontColor_Yellow}4.${FontColor_Suffix} 清理日誌並重啟所有服務\n ${FontColor_Red}5.${FontColor_Suffix} 徹底清理所有服務\n"; echo -e " ${FontColor_Yellow}0.${FontColor_Suffix} 退出腳本\n"; read -p " 請輸入選項 [0-5]: " num < /dev/tty; case "$num" in 1) manage_caddy;; 2) manage_warp;; 3) manage_hysteria;; 4) clear_logs_and_restart_all; press_any_key;; 5) uninstall_all_services; press_any_key;; 0) exit 0;; *) log ERROR "無效輸入!"; sleep 2;; esac; done; }

# --- 第3節：腳本入口 (主邏輯) ---
clear; cat <<-'EOM'
  ____      _        __          __      _   _             _             _
 / ___|__ _| |_ __ _ \ \        / /     | | | |           | |           (_)
| |   / _` | __/ _` | \ \  /\  / /  __ _| |_| |_ ___ _ __ | |_ __ _ _ __ _  ___
| |__| (_| | || (_| |  \ \/  \/ /  / _` | __| __/ _ \ '_ \| __/ _` | '__| |/ __|
 \____\__,_|\__\__,_|   \  /\  /  | (_| | |_| ||  __/ | | | || (_| | |  | | (__
                        \/  \/    \__,_|\__|\__\___|_| |_|\__\__,_|_|  |_|\___|
EOM
echo -e "${FontColor_Purple}Caddy + WARP + Hysteria 終極一鍵管理腳本${FontColor_Suffix}"; echo "----------------------------------------------------------------"
check_root; self_install; check_docker; mkdir -p "${APP_BASE_DIR}"; start_menu
