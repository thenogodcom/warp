#!/usr/bin/env bash
#
# Description: Docker Container Manager for caomingjun/warp, inspired by P3TERX/warp.sh
# Author: Your Name (Inspired by P3TERX)
# Version: 2.0.0

# --- Color Definitions & Log Function (from P3TERX) ---
FontColor_Red="\033[31m"
FontColor_Green="\033[32m"
FontColor_Yellow="\033[33m"
FontColor_Purple="\033[35m"
FontColor_Suffix="\033[0m"

log() {
    local LEVEL="$1"
    local MSG="$2"
    case "${LEVEL}" in
    INFO)
        local LEVEL="[${FontColor_Green}${LEVEL}${FontColor_Suffix}]"
        local MSG="${LEVEL} ${MSG}"
        ;;
    WARN)
        local LEVEL="[${FontColor_Yellow}${LEVEL}${FontColor_Suffix}]"
        local MSG="${LEVEL} ${MSG}"
        ;;
    ERROR)
        local LEVEL="[${FontColor_Red}${LEVEL}${FontColor_Suffix}]"
        local MSG="${LEVEL} ${MSG}"
        ;;
    *) ;;
    esac
    echo -e "${MSG}"
}

# --- Docker Container Configuration ---
CONTAINER_NAME="warp-docker"
IMAGE_NAME="caomingjun/warp"
VOLUME_PATH="$(pwd)/warp-data"

# --- Prerequisite Checks ---
check_docker() {
    if ! [ -x "$(command -v docker)" ]; then
        log ERROR "Docker is not installed. Please install Docker first."
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        log ERROR "Docker service is not running. Please start the Docker service."
        exit 1
    fi
}

# --- Helper Functions ---
check_container_exists() {
    if [ "$(docker ps -a -q -f name=^/${CONTAINER_NAME}$)" ]; then
        return 0 # Exists
    else
        return 1 # Does not exist
    fi
}

press_any_key_to_continue() {
    echo ""
    read -p "Press Enter to return to the main menu..." < /dev/tty
}

# --- Core Management Functions ---

# 1. Install Container
install_warp_container() {
    if check_container_exists; then
        log WARN "WARP container (${CONTAINER_NAME}) already exists. Please uninstall it first if you want to reinstall."
        return
    fi

    log INFO "Starting WARP container installation..."

    read -p "Enter the SOCKS5 proxy port to map to the host (default: 1080): " PROXY_PORT < /dev/tty
    PROXY_PORT=${PROXY_PORT:-1080}

    read -p "Do you have a WARP+ License Key? (Enter if you have, otherwise leave blank): " WARP_LICENSE_KEY < /dev/tty

    read -p "Enable NAT mode (for side router, etc.)? (y/N): " ENABLE_NAT_CHOICE < /dev/tty
    
    # Use array to build the command safely
    DOCKER_CMD_ARRAY=(
        "docker" "run" "-d" 
        "--name" "${CONTAINER_NAME}"
        "--restart" "always"
        "--device-cgroup-rule" "c 10:200 rwm"
        "--cap-add" "MKNOD" "--cap-add" "AUDIT_WRITE" "--cap-add" "NET_ADMIN"
        "--sysctl" "net.ipv6.conf.all.disable_ipv6=0"
        "--sysctl" "net.ipv4.conf.all.src_valid_mark=1"
        "-p" "${PROXY_PORT}:1080"
        "-e" "WARP_SLEEP=3"
    )

    [ -n "$WARP_LICENSE_KEY" ] && DOCKER_CMD_ARRAY+=("-e" "WARP_LICENSE_KEY=${WARP_LICENSE_KEY}")

    if [[ "$ENABLE_NAT_CHOICE" =~ ^[yY]$ ]]; then
        DOCKER_CMD_ARRAY+=(
            "-e" "WARP_ENABLE_NAT=1"
            "--sysctl" "net.ipv4.ip_forward=1"
            "--sysctl" "net.ipv6.conf.all.forwarding=1"
        )
        log INFO "NAT mode has been enabled."
    fi

    mkdir -p ${VOLUME_PATH}
    DOCKER_CMD_ARRAY+=("-v" "${VOLUME_PATH}:/var/lib/cloudflare-warp")
    DOCKER_CMD_ARRAY+=("${IMAGE_NAME}")

    log INFO "Executing the following command:"
    echo -e "${FontColor_Green}${DOCKER_CMD_ARRAY[*]}${FontColor_Suffix}"
    
    if "${DOCKER_CMD_ARRAY[@]}"; then
        log INFO "WARP container installed and started successfully!"
        log INFO "Please wait about 10 seconds for the container to initialize..."
    else
        log ERROR "WARP container installation failed. Please check the Docker logs."
    fi
}

# 2. Uninstall Container
uninstall_warp_container() {
    if ! check_container_exists; then
        log ERROR "WARP container (${CONTAINER_NAME}) not found."
        return
    fi

    log INFO "Stopping and removing WARP container..."
    docker stop ${CONTAINER_NAME} >/dev/null 2>&1
    docker rm ${CONTAINER_NAME} >/dev/null 2>&1
    log INFO "WARP container removed."

    read -p "Do you want to delete the local WARP configuration data (in ${VOLUME_PATH})? (y/N): " REMOVE_DATA_CHOICE < /dev/tty
    if [[ "$REMOVE_DATA_CHOICE" =~ ^[yY]$ ]]; then
        rm -rf ${VOLUME_PATH}
        log INFO "Configuration data has been deleted."
    else
        log INFO "Configuration data has been kept."
    fi
}

# 3. Update Container
update_warp_container() {
    if ! check_container_exists; then
        log ERROR "WARP container (${CONTAINER_NAME}) not found. Please install it first."
        return
    fi

    log INFO "1. Pulling the latest Docker image..."
    docker pull ${IMAGE_NAME}

    log INFO "2. Stopping and removing the old container..."
    docker stop ${CONTAINER_NAME}
    docker rm ${CONTAINER_NAME}

    log INFO "3. Re-creating the container with the new image..."
    log WARN "The script will now run the installation process again. Your registration data is preserved."
    install_warp_container
}

# 4. View Logs
view_logs() {
    if ! check_container_exists; then
        log ERROR "WARP container (${CONTAINER_NAME}) not found."
        return
    fi
    log INFO "Displaying logs for WARP container (Press Ctrl+C to exit)..."
    docker logs -f ${CONTAINER_NAME}
}

# 5. Check Status
check_status() {
    if ! check_container_exists; then
        CONTAINER_STATUS_zh="${FontColor_Red}未安装${FontColor_Suffix}"
        WARP_CONNECTION_zh="${FontColor_Red}N/A${FontColor_Suffix}"
        SOCKS5_PORT_zh="${FontColor_Red}N/A${FontColor_Suffix}"
        return
    fi
    
    STATUS=$(docker inspect --format '{{.State.Status}}' ${CONTAINER_NAME})
    if [ "$STATUS" == "running" ]; then
        CONTAINER_STATUS_zh="${FontColor_Green}运行中${FontColor_Suffix}"
        
        # Check internal WARP status via SOCKS5 proxy
        PROXY_PORT=$(docker inspect --format='{{(index (index .HostConfig.PortBindings "1080/tcp") 0).HostPort}}' ${CONTAINER_NAME})
        SOCKS5_PORT_zh="${FontColor_Green}${PROXY_PORT}${FontColor_Suffix}"

        # Give it a few seconds to respond
        WARP_STATUS=$(docker exec ${CONTAINER_NAME} curl -s --proxy socks5h://127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace --connect-timeout 5 | grep "warp=" | cut -d'=' -f2)

        case ${WARP_STATUS} in
        on)
            WARP_CONNECTION_zh="${FontColor_Green}已连接 (WARP)${FontColor_Suffix}"
            ;;
        plus)
            WARP_CONNECTION_zh="${FontColor_Green}已连接 (WARP+)${FontColor_Suffix}"
            ;;
        *)
            WARP_CONNECTION_zh="${FontColor_Yellow}正在连接...${FontColor_Suffix}"
            ;;
        esac
    else
        CONTAINER_STATUS_zh="${FontColor_Red}已停止 (${STATUS})${FontColor_Suffix}"
        WARP_CONNECTION_zh="${FontColor_Red}未连接${FontColor_Suffix}"
        SOCKS5_PORT_zh="${FontColor_Red}N/A${FontColor_Suffix}"
    fi
}


# --- Menu ---
start_menu() {
    while true; do
        log INFO "Checking status..."
        check_status
        clear
        echo -e "
${FontColor_Purple}WARP Docker Container Manager${FontColor_Suffix} (Style by ${FontColor_Yellow}P3TERX${FontColor_Suffix})

 --------------------------------------------------
  容器状态   : ${CONTAINER_STATUS_zh}
  WARP 连接  : ${WARP_CONNECTION_zh}
  SOCKS5 端口: ${SOCKS5_PORT_zh}
 --------------------------------------------------

 ${FontColor_Green}1.${FontColor_Suffix} 安装 WARP 容器
 ${FontColor_Green}2.${FontColor_Suffix} 卸載 WARP 容器
 ${FontColor_Green}3.${FontColor_Suffix} 更新 WARP 容器
 ${FontColor_Green}4.${FontColor_Suffix} 查看容器日誌
 
 ${FontColor_Yellow}0.${FontColor_Suffix} 退出脚本
"
        read -p "请输入选项 [0-4]: " num < /dev/tty
        case "$num" in
            1)
                install_warp_container
                press_any_key_to_continue
                ;;
            2)
                uninstall_warp_container
                press_any_key_to_continue
                ;;
            3)
                update_warp_container
                press_any_key_to_continue
                ;;
            4)
                view_logs
                # No need for press_any_key here, as Ctrl+C will exit logs
                ;;
            0)
                exit 0
                ;;
            *)
                log ERROR "无效输入，请输入正确的数字 [0-4]"
                sleep 2
                ;;
        esac
    done
}

# --- Script Entrypoint ---
clear
cat <<-'EOM'

 __      __   _   _   _   ____   _____   ____   _   _   _   ____
 \ \    / /  / \ | | | | |  _ \ | ____| |  _ \ | | | | / \ |  _ \
  \ \  / /  / _ \| | | | | |_) ||  _|   | |_) || | | |/ _ \| | | |
   \ \/ /  / ___ \ |_| | |  _ < | |___  |  _ < | |_| / ___ \ | | |
    \__/  /_/   \_\___/  |_| \_\|_____| |_| \_\ \___//_/   \_\_| |_|

EOM
echo -e "${FontColor_Purple}WARP Docker Container Manager - Inspired by P3TERX/warp.sh${FontColor_Suffix}"
echo "----------------------------------------------------------------"

check_docker
start_menu
