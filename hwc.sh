#!/usr/bin/env bash
#
# Description: Ultimate All-in-One Manager for Caddy, WARP & Hysteria with self-installing shortcut.
# Author: Your Name (Inspired by P-TERX)
# Version: 5.2.0

# --- 第1节：全局配置与定义 ---
FontColor_Red="\033[31m"; FontColor_Green="\033[32m"; FontColor_Yellow="\033[33m"
FontColor_Purple="\033[35m"; FontColor_Suffix="\033[0m"
log() { local LEVEL="$1"; local MSG="$2"; case "${LEVEL}" in INFO) local LEVEL="[${FontColor_Green}信息${FontColor_Suffix}]";; WARN) local LEVEL="[${FontColor_Yellow}警告${FontColor_Suffix}]";; ERROR) local LEVEL="[${FontColor_Red}错误${FontColor_Suffix}]";; esac; echo -e "${LEVEL} ${MSG}"; }

CADDY_CONTAINER_NAME="caddy-manager"; CADDY_IMAGE_NAME="caddy:latest"; CADDY_CONFIG_DIR="$(pwd)/caddy"; CADDY_CONFIG_FILE="${CADDY_CONFIG_DIR}/Caddyfile"; CADDY_DATA_VOLUME="caddy_data"
WARP_CONTAINER_NAME="warp-docker"; WARP_IMAGE_NAME="caomingjun/warp:2025.8.779.0-2.12.0-ce78b84d63390ebf361d7fdfa8e875ef7e2a43d1"; WARP_VOLUME_PATH="$(pwd)/warp-data"
HYSTERIA_CONTAINER_NAME="hysteria-server"; HYSTERIA_IMAGE_NAME="tobyxdd/hysteria"; HYSTERIA_CONFIG_DIR="$(pwd)/hysteria"; HYSTERIA_CONFIG_FILE="${HYSTERIA_CONFIG_DIR}/config.yaml"
SHARED_NETWORK_NAME="proxy-net"
SCRIPT_URL="https://raw.githubusercontent.com/thenogodcom/warp/main/hwc.sh"
SHORTCUT_PATH="/usr/local/bin/hwc"

# --- 第2节：所有函数定义 ---

self_install() {
    local running_script_path
    if [[ -f "$0" ]]; then running_script_path=$(readlink -f "$0"); fi
    if [ "$running_script_path" = "$SHORTCUT_PATH" ]; then return 0; fi
    log INFO "首次运行设置：正在安装 'hwc' 快捷命令以便日后访问..."
    if curl -sSL "${SCRIPT_URL}" -o "${SHORTCUT_PATH}"; then
        chmod +x "${SHORTCUT_PATH}"
        log INFO "快捷命令 'hwc' 安装成功。正在从新位置重新启动..."
        exec "${SHORTCUT_PATH}" "$@"
    else
        log ERROR "无法安装 'hwc' 快捷命令至 ${SHORTCUT_PATH}。"
        log WARN "本次将临时运行脚本，请检查权限后重试。"
        sleep 3
    fi
}

check_root() { if [ "$EUID" -ne 0 ]; then log ERROR "此脚本必须以 root 身份运行。请使用 'sudo'。"; exit 1; fi; }
check_docker() { if ! [ -x "$(command -v docker)" ]; then log ERROR "Docker 未安装。"; exit 1; fi; if ! docker info >/dev/null 2>&1; then log ERROR "Docker 服务未运行。"; exit 1; fi; }
check_editor() { for editor in nano vi vim; do if command -v $editor &>/dev/null; then EDITOR=$editor; return 0; fi; done; log ERROR "未找到合适的文本编辑器 (nano, vi, vim)。"; return 1; }
container_exists() { docker ps -a --format '{{.Names}}' | grep -q "^${1}$"; }
press_any_key() { echo ""; read -p "按 Enter 键返回..." < /dev/tty; }

generate_caddy_config() {
    local domain="$1" email="$2" log_mode="$3"
    mkdir -p "${CADDY_CONFIG_DIR}"
    > "${CADDY_CONFIG_FILE}"
    echo -e "{\n    email ${email}\n}" >> "${CADDY_CONFIG_FILE}"
    echo "" >> "${CADDY_CONFIG_FILE}"
    echo -e "${domain} {" >> "${CADDY_CONFIG_FILE}"
    if [[ ! "$log_mode" =~ ^[yY]$ ]]; then
        echo -e "    log {\n        output stderr\n        level  ERROR\n    }" >> "${CADDY_CONFIG_FILE}"
    fi
    echo -e "    respond \"Service is running.\" 200\n}" >> "${CADDY_CONFIG_FILE}"
    log INFO "已为域名 ${domain} 创建 Caddyfile 配置文件。";
}

generate_hysteria_config() {
    local domain="$1" password="$2" log_mode="$3"
    mkdir -p "${HYSTERIA_CONFIG_DIR}"
    local log_level="error"; if [[ "$log_mode" =~ ^[yY]$ ]]; then log_level="info"; fi
    cat > "${HYSTERIA_CONFIG_FILE}" << EOF
listen: :443
logLevel: ${log_level}
auth:
  type: password
  password: ${password}
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
    log INFO "Hysteria 的 config.yaml 已创建，日志级别设置为 '${log_level}'。";
}

manage_caddy() {
    if ! container_exists "$CADDY_CONTAINER_NAME"; then
        while true; do
            clear; log INFO "--- 管理 Caddy (未安装) ---"
            echo " 1. 安装 Caddy (用于自动申请SSL证书)"
            echo " 0. 返回主菜单"
            read -p "请输入选项: " choice < /dev/tty
            case "$choice" in
                1)
                    log INFO "--- 正在安装 Caddy ---"
                    read -p "请输入 Caddy 将要管理的域名 (必须指向本机IP): " DOMAIN < /dev/tty
                    read -p "请输入您的邮箱 (用于SSL证书申请与续期通知): " EMAIL < /dev/tty
                    if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then log ERROR "域名和邮箱不能为空。"; press_any_key; continue; fi
                    read -p "是否为 Caddy 启用详细日志？(用于排错，默认为否) (y/N): " LOG_MODE < /dev/tty
                    generate_caddy_config "$DOMAIN" "$EMAIL" "$LOG_MODE"
                    docker network create "${SHARED_NETWORK_NAME}" &>/dev/null
                    CADDY_CMD=(docker run -d --name "${CADDY_CONTAINER_NAME}" --restart always --network "${SHARED_NETWORK_NAME}" -p 80:80/tcp -p 443:443/tcp -v "${CADDY_CONFIG_FILE}:/etc/caddy/Caddyfile:ro" -v "${CADDY_DATA_VOLUME}:/data" "${CADDY_IMAGE_NAME}")
                    if "${CADDY_CMD[@]}"; then log INFO "Caddy 部署成功。正在后台申请证书，请稍候..."; else log ERROR "Caddy 部署失败。"; fi
                    press_any_key; break;;
                0) break;;
                *) log ERROR "无效输入!"; sleep 1;;
            esac
        done
    else
        while true; do
            clear; log INFO "--- 管理 Caddy (已安装) ---"
            echo " 1. 查看日志"
            echo " 2. 编辑 Caddyfile"
            echo " 3. 重启 Caddy 容器"
            echo " 4. 卸载 Caddy"
            echo " 0. 返回主菜单"
            read -p "请输入选项: " choice < /dev/tty
            case "$choice" in
                1) docker logs -f "$CADDY_CONTAINER_NAME"; press_any_key;;
                2) if check_editor; then "$EDITOR" "${CADDY_CONFIG_FILE}"; log INFO "配置已保存。如果需要应用更改，请手动选择重启选项。"; press_any_key; else press_any_key; fi;;
                3) log INFO "正在重启 Caddy 容器..."; docker restart "$CADDY_CONTAINER_NAME"; sleep 2;;
                4) 
                    log WARN "Hysteria 依赖 Caddy 提供证书，卸载 Caddy 将导致 Hysteria 无法工作。"
                    read -p "确定要卸载 Caddy 吗? (y/N): " uninstall_choice < /dev/tty
                    if [[ "$uninstall_choice" =~ ^[yY]$ ]]; then
                        docker stop "${CADDY_CONTAINER_NAME}" &>/dev/null && docker rm "${CADDY_CONTAINER_NAME}" &>/dev/null
                        read -p "是否删除 Caddy 的配置文件和数据卷(包含证书)？(y/N): " del_choice < /dev/tty
                        if [[ "$del_choice" =~ ^[yY]$ ]]; then rm -rf "${CADDY_CONFIG_DIR}"; docker volume rm "${CADDY_DATA_VOLUME}" &>/dev/null; log INFO "Caddy 的配置和数据已删除。"; fi
                        log INFO "Caddy 已卸载。";
                    fi
                    press_any_key; break;;
                0) break;;
                *) log ERROR "无效输入!"; sleep 1;;
            esac
        done
    fi
}

manage_warp() {
    if ! container_exists "$WARP_CONTAINER_NAME"; then
        while true; do
            clear; log INFO "--- 管理 WARP (未安装) ---"
            echo " 1. 安装 WARP (免费版，无特殊日志)"
            echo " 0. 返回主菜单"
            read -p "请输入选项: " choice < /dev/tty
            case "$choice" in
                1)
                    log INFO "--- 正在安装 WARP ---"
                    docker network create "${SHARED_NETWORK_NAME}" &>/dev/null
                    WARP_CMD=(docker run -d --name "${WARP_CONTAINER_NAME}" --restart always --network "${SHARED_NETWORK_NAME}" -v "${WARP_VOLUME_PATH}:/var/lib/cloudflare-warp" --cap-add=MKNOD --cap-add=AUDIT_WRITE --cap-add=NET_ADMIN --device-cgroup-rule='c 10:200 rwm' --sysctl net.ipv6.conf.all.disable_ipv6=0 --sysctl net.ipv4.conf.all.src_valid_mark=1 "${WARP_IMAGE_NAME}")
                    if "${WARP_CMD[@]}"; then log INFO "WARP 部署成功。"; else log ERROR "WARP 部署失败。"; fi
                    press_any_key; break;;
                0) break;;
                *) log ERROR "无效输入!"; sleep 1;;
            esac
        done
    else
         while true; do
            clear; log INFO "--- 管理 WARP (已安装) ---"
            echo " 1. 查看日志"
            echo " 2. 检查状态 (Trace)"
            echo " 3. 升级到 WARP+"
            echo " 4. 重启 WARP 容器"
            echo " 5. 卸载 WARP"
            echo " 0. 返回主菜单"
            read -p "请输入选项: " choice < /dev/tty
            case "$choice" in
                1) docker logs -f "$WARP_CONTAINER_NAME"; press_any_key;;
                2) log INFO "正在执行 Trace 测试..."; docker exec "$WARP_CONTAINER_NAME" curl -s --proxy socks5h://127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace; press_any_key;;
                3) log INFO "即将进入容器以更新授权码..."
                   log WARN "请在容器 Shell 中粘贴并执行以下命令: warp-cli --accept-tos registration license 您的授权码"
                   docker exec -it "$WARP_CONTAINER_NAME" /bin/bash
                   log INFO "正在重启 WARP 以应用更改..."; docker restart "$WARP_CONTAINER_NAME"; sleep 2; press_any_key;;
                4) log INFO "正在重启 WARP 容器..."; docker restart "$WARP_CONTAINER_NAME"; sleep 2;;
                5)
                    log WARN "Hysteria 依赖 WARP 作为网络出口，卸载 WARP 将导致 Hysteria 无法工作。"
                    read -p "确定要卸载 WARP 吗? (y/N): " uninstall_choice < /dev/tty
                    if [[ "$uninstall_choice" =~ ^[yY]$ ]]; then
                        docker stop "${WARP_CONTAINER_NAME}" &>/dev/null && docker rm "${WARP_CONTAINER_NAME}" &>/dev/null
                        rm -rf "${WARP_VOLUME_PATH}"
                        log INFO "WARP 已卸载，本地数据已清除。";
                    fi
                    press_any_key; break;;
                0) break;;
                *) log ERROR "无效输入!"; sleep 1;;
            esac
        done
    fi
}

manage_hysteria() {
    if ! container_exists "$HYSTERIA_CONTAINER_NAME"; then
        while true; do
            clear; log INFO "--- 管理 Hysteria (未安装) ---"
            echo " 1. 安装 Hysteria"
            echo " 0. 返回主菜单"
            read -p "请输入选项: " choice < /dev/tty
            case "$choice" in
                1)
                    if ! container_exists "$CADDY_CONTAINER_NAME" || ! container_exists "$WARP_CONTAINER_NAME"; then
                        log ERROR "依赖项缺失！请务必先安装 Caddy 和 WARP。"; press_any_key; continue
                    fi
                    local caddy_domain; caddy_domain=$(awk 'NR>1 && NF==2 && $2=="{" {print $1; exit}' "${CADDY_CONFIG_FILE}" 2>/dev/null)
                    log INFO "--- 正在安装 Hysteria ---"
                    read -p "是否为 Hysteria 启用详细日志？(默认为否) (y/N): " LOG_MODE < /dev/tty
                    if [ -n "$caddy_domain" ]; then
                        read -p "请输入您的域名 [默认: ${caddy_domain}]: " DOMAIN < /dev/tty
                        DOMAIN=${DOMAIN:-$caddy_domain}
                    else
                        read -p "请输入您的域名 (必须与Caddy配置的域名一致): " DOMAIN < /dev/tty
                    fi
                    read -p "请为 Hysteria 设置一个连接密码: " PASSWORD < /dev/tty
                    if [ -z "$DOMAIN" ] || [ -z "$PASSWORD" ]; then log ERROR "域名和密码为必填项。"; press_any_key; continue; fi
                    generate_hysteria_config "$DOMAIN" "$PASSWORD" "$LOG_MODE"
                    HY_CMD=(docker run -d --name "${HYSTERIA_CONTAINER_NAME}" --restart always --network "${SHARED_NETWORK_NAME}" --memory=256m -v "${HYSTERIA_CONFIG_FILE}:/config.yaml:ro" -v "${CADDY_DATA_VOLUME}:/data:ro" -p 443:443/udp "${HYSTERIA_IMAGE_NAME}" server -c /config.yaml)
                    if "${HY_CMD[@]}"; then log INFO "Hysteria 部署成功。"; else log ERROR "Hysteria 部署失败。"; fi
                    press_any_key; break;;
                0) break;;
                *) log ERROR "无效输入!"; sleep 1;;
            esac
        done
    else
        while true; do
            clear; log INFO "--- 管理 Hysteria (已安装) ---"
            echo " 1. 查看日志"
            echo " 2. 编辑配置文件"
            echo " 3. 重启 Hysteria 容器"
            echo " 4. 卸载 Hysteria"
            echo " 0. 返回主菜单"
            read -p "请输入选项: " choice < /dev/tty
            case "$choice" in
                1) docker logs -f "$HYSTERIA_CONTAINER_NAME"; press_any_key;;
                2) if check_editor; then "$EDITOR" "${HYSTERIA_CONFIG_FILE}"; log INFO "配置已保存。如果需要应用更改，请手动选择重启选项。"; press_any_key; else press_any_key; fi;;
                3) log INFO "正在重启 Hysteria 容器..."; docker restart "$HYSTERIA_CONTAINER_NAME"; sleep 2;;
                4)
                    read -p "确定要卸载 Hysteria 吗? (y/N): " uninstall_choice < /dev/tty
                    if [[ "$uninstall_choice" =~ ^[yY]$ ]]; then
                        docker stop "${HYSTERIA_CONTAINER_NAME}" &>/dev/null && docker rm "${HYSTERIA_CONTAINER_NAME}" &>/dev/null
                        rm -rf "${HYSTERIA_CONFIG_DIR}"
                        log INFO "Hysteria 已卸载，配置文件已清除。";
                    fi
                    press_any_key; break;;
                0) break;;
                *) log ERROR "无效输入!"; sleep 1;;
            esac
        done
    fi
}

clear_all_logs() {
    log INFO "此操作将清空所有已安装服务容器的内部日志。"
    read -p "确定要继续吗? (y/N): " choice < /dev/tty
    if [[ ! "$choice" =~ ^[yY]$ ]]; then log INFO "操作已取消。"; return; fi
    for container in "$CADDY_CONTAINER_NAME" "$WARP_CONTAINER_NAME" "$HYSTERIA_CONTAINER_NAME"; do
        if container_exists "$container"; then
            log INFO "正在清除 ${container} 的日志..."
            local log_path; log_path=$(docker inspect --format='{{.LogPath}}' "$container")
            if [ -f "$log_path" ]; then
                truncate -s 0 "$log_path" 2>/dev/null || { log WARN "权限不足，正在尝试使用 sudo..."; sudo truncate -s 0 "$log_path"; }
            fi
        fi
    done
    log INFO "所有服务日志已清空。"
}

restart_all_services() {
    log INFO "正在重启所有正在运行的容器..."
    local restarted=0
    for container in "$CADDY_CONTAINER_NAME" "$WARP_CONTAINER_NAME" "$HYSTERIA_CONTAINER_NAME"; do
        if container_exists "$container" && [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = "true" ]; then
            log INFO "正在重启 ${container}..."
            docker restart "$container" &>/dev/null
            restarted=$((restarted + 1))
        fi
    done
    if [ "$restarted" -eq 0 ]; then log WARN "没有正在运行的容器可供重启。"; else log INFO "所有正在运行的容器已重启。"; fi
}

uninstall_all_services() {
    log WARN "此操作将不可逆地删除 Caddy, WARP, Hysteria 的容器、配置文件、数据卷和网络！"
    read -p "您确定要彻底清理所有服务吗? (y/N): " choice < /dev/tty
    if [[ ! "$choice" =~ ^[yY]$ ]]; then log INFO "操作已取消。"; return; fi

    log INFO "正在停止并删除所有服务容器..."
    docker stop "${CADDY_CONTAINER_NAME}" "${WARP_CONTAINER_NAME}" "${HYSTERIA_CONTAINER_NAME}" &>/dev/null
    docker rm "${CADDY_CONTAINER_NAME}" "${WARP_CONTAINER_NAME}" "${HYSTERIA_CONTAINER_NAME}" &>/dev/null
    log INFO "所有容器已删除。"

    log INFO "正在删除本地配置文件和数据..."
    rm -rf "${CADDY_CONFIG_DIR}" "${HYSTERIA_CONFIG_DIR}" "${WARP_VOLUME_PATH}"
    log INFO "本地配置文件和数据已删除。"

    log INFO "正在删除 Docker 数据卷..."
    docker volume rm "${CADDY_DATA_VOLUME}" &>/dev/null
    log INFO "Docker 数据卷已删除。"

    log INFO "正在删除共享网络..."
    docker network rm "${SHARED_NETWORK_NAME}" &>/dev/null
    log INFO "共享网络已删除。"

    log INFO "所有服务已彻底清理完毕。"
}

check_all_status() {
    for container in "$CADDY_CONTAINER_NAME" "$WARP_CONTAINER_NAME" "$HYSTERIA_CONTAINER_NAME"; do
        local var_name="${container//-/_}_status"
        if ! container_exists "$container"; then
            eval "${var_name}='${FontColor_Red}未安装${FontColor_Suffix}'"
        else
            local status; status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null)
            if [ "$status" = "running" ]; then
                eval "${var_name}='${FontColor_Green}运行中${FontColor_Suffix}'"
            else
                eval "${var_name}='${FontColor_Red}异常 (${status})${FontColor_Suffix}'"
            fi
        fi
    done
}

start_menu() {
    while true; do
        check_all_status
        clear
        echo -e "\n${FontColor_Purple}Caddy + WARP + Hysteria 终极管理脚本${FontColor_Suffix} (v5.2.0)"
        echo -e "  快捷命令: ${FontColor_Yellow}hwc${FontColor_Suffix}"
        echo -e " --------------------------------------------------"
        echo -e "  Caddy 服务      : ${caddy_manager_status}"
        echo -e "  WARP 服务       : ${warp_docker_status}"
        echo -e "  Hysteria 服务   : ${hysteria_server_status}"
        echo -e " --------------------------------------------------\n"
        echo -e " ${FontColor_Green}1.${FontColor_Suffix} 管理 Caddy..."
        echo -e " ${FontColor_Green}2.${FontColor_Suffix} 管理 WARP..."
        echo -e " ${FontColor_Green}3.${FontColor_Suffix} 管理 Hysteria...\n"
        echo -e " ${FontColor_Yellow}4.${FontColor_Suffix} 清除所有服务日志"
        echo -e " ${FontColor_Yellow}5.${FontColor_Suffix} 重启所有运行中的容器"
        echo -e " ${FontColor_Red}6.${FontColor_Suffix} 彻底清理所有服务\n"
        echo -e " ${FontColor_Yellow}0.${FontColor_Suffix} 退出脚本\n"
        read -p " 请输入选项 [0-6]: " num < /dev/tty
        case "$num" in
            1) manage_caddy;;
            2) manage_warp;;
            3) manage_hysteria;;
            4) clear_all_logs; press_any_key;;
            5) restart_all_services; press_any_key;;
            6) uninstall_all_services; press_any_key;;
            0) exit 0;;
            *) log ERROR "无效输入!"; sleep 2;;
        esac
    done
}

# --- 第3节：脚本入口 (主逻辑) ---
clear
cat <<-'EOM'
  ____      _        __          __      _   _             _             _
 / ___|__ _| |_ __ _ \ \        / /     | | | |           | |           (_)
| |   / _` | __/ _` | \ \  /\  / /  __ _| |_| |_ ___ _ __ | |_ __ _ _ __ _  ___
| |__| (_| | || (_| |  \ \/  \/ /  / _` | __| __/ _ \ '_ \| __/ _` | '__| |/ __|
 \____\__,_|\__\__,_|   \  /\  /  | (_| | |_| ||  __/ | | | || (_| | |  | | (__
                        \/  \/    \__,_|\__|\__\___|_| |_|\__\__,_|_|  |_|\___|
EOM
echo -e "${FontColor_Purple}Caddy + WARP + Hysteria 终极一键管理脚本${FontColor_Suffix}"
echo "----------------------------------------------------------------"

check_root
self_install
check_docker
start_menu
