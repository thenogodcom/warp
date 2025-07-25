#!/bin/bash

#=================================================
#	System Required: CentOS/Debian/Ubuntu
#	Description: WARP Docker Container One-Key Script
#	Author: Your Name
#	Blog: https://your.blog.com
#	Version: 1.1.0 (Fixed interactive issue with curl|bash)
#=================================================

# 顏色定義
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
NC="\033[0m" # No Color

# Docker 容器配置
CONTAINER_NAME="warp"
IMAGE_NAME="caomingjun/warp"
VOLUME_PATH="$(pwd)/warp-data"

# 檢查 Docker 是否安裝並運行
check_docker() {
    if ! [ -x "$(command -v docker)" ]; then
        echo -e "${RED}錯誤: Docker 未安裝。請先安裝 Docker。${NC}"
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}錯誤: Docker 服務未運行。請啟動 Docker 服務。${NC}"
        exit 1
    fi
}

# 檢查容器是否存在
check_container_exists() {
    if [ "$(docker ps -a -q -f name=^/${CONTAINER_NAME}$)" ]; then
        return 0 # 存在
    else
        return 1 # 不存在
    fi
}

# 安裝 WARP 容器
install_warp() {
    if check_container_exists; then
        echo -e "${YELLOW}WARP 容器 (${CONTAINER_NAME}) 已存在。如果您想重新安裝，請先選擇卸載。${NC}"
        return
    fi

    echo -e "${GREEN}開始安裝 WARP 容器...${NC}"

    # 交互式詢問配置 (!!!修正點: 添加 < /dev/tty)
    read -p "請輸入要映射到主機的 SOCKS5 代理端口 (留空默認 1080): " PROXY_PORT < /dev/tty
    PROXY_PORT=${PROXY_PORT:-1080}

    read -p "您是否有 WARP+ 授權碼 (License Key)? (有則輸入, 無則直接回車): " WARP_LICENSE_KEY < /dev/tty

    read -p "是否啟用 NAT 模式 (用於旁路由等)? (y/N): " ENABLE_NAT_CHOICE < /dev/tty
    
    # 準備 docker run 命令
    DOCKER_CMD="docker run -d --name ${CONTAINER_NAME} --restart always"
    
    # 添加設備規則和能力
    DOCKER_CMD+=" --device-cgroup-rule='c 10:200 rwm'"
    DOCKER_CMD+=" --cap-add=MKNOD --cap-add=AUDIT_WRITE --cap-add=NET_ADMIN"
    
    # 添加 sysctls
    DOCKER_CMD+=" --sysctl net.ipv6.conf.all.disable_ipv6=0 --sysctl net.ipv4.conf.all.src_valid_mark=1"
    
    # 添加端口映射
    DOCKER_CMD+=" -p ${PROXY_PORT}:1080"
    
    # 添加環境變量
    DOCKER_CMD+=" -e WARP_SLEEP=2"
    if [ -n "$WARP_LICENSE_KEY" ]; then
        DOCKER_CMD+=" -e WARP_LICENSE_KEY=${WARP_LICENSE_KEY}"
    fi

    # 處理 NAT 配置
    if [[ "$ENABLE_NAT_CHOICE" =~ ^[yY]$ ]]; then
        DOCKER_CMD+=" -e WARP_ENABLE_NAT=1"
        DOCKER_CMD+=" --sysctl net.ipv4.ip_forward=1"
        DOCKER_CMD+=" --sysctl net.ipv6.conf.all.forwarding=1"
        echo -e "${YELLOW}NAT 模式已啟用。${NC}"
    fi

    # 創建並添加數據卷
    mkdir -p ${VOLUME_PATH}
    DOCKER_CMD+=" -v ${VOLUME_PATH}:/var/lib/cloudflare-warp"

    # 添加鏡像名稱
    DOCKER_CMD+=" ${IMAGE_NAME}"

    # 執行命令
    echo -e "${YELLOW}正在執行以下命令:${NC}"
    echo -e "${GREEN}${DOCKER_CMD}${NC}"
    
    if ${DOCKER_CMD}; then
        echo -e "${GREEN}WARP 容器已成功安裝並啟動！${NC}"
        echo "--------------------------------------------------"
        echo -e "${GREEN}使用方法:${NC}"
        if [[ "$ENABLE_NAT_CHOICE" =~ ^[yY]$ ]]; then
            echo -e "您已啟用 NAT 模式，請將需要走 WARP 網絡的設備的網關指向運行此容器的主機 IP。"
        else
            echo -e "SOCKS5 代理地址: ${YELLOW}127.0.0.1:${PROXY_PORT}${NC}"
            echo -e "測試代理是否工作:"
            echo -e "${GREEN}curl --proxy socks5h://127.0.0.1:${PROXY_PORT} https://www.cloudflare.com/cdn-cgi/trace${NC}"
        fi
        echo "--------------------------------------------------"
    else
        echo -e "${RED}WARP 容器安裝失敗。請檢查日誌。${NC}"
    fi
}

# 卸載 WARP 容器
uninstall_warp() {
    if ! check_container_exists; then
        echo -e "${RED}錯誤: WARP 容器 (${CONTAINER_NAME}) 未找到。${NC}"
        return
    fi

    echo -e "${YELLOW}正在停止並移除 WARP 容器...${NC}"
    docker stop ${CONTAINER_NAME} >/dev/null 2>&1
    docker rm ${CONTAINER_NAME} >/dev/null 2>&1
    echo -e "${GREEN}WARP 容器已移除。${NC}"

    # (!!!修正點: 添加 < /dev/tty)
    read -p "是否需要刪除本地的 WARP 配置數據 (位於 ${VOLUME_PATH})? (y/N): " REMOVE_DATA_CHOICE < /dev/tty
    if [[ "$REMOVE_DATA_CHOICE" =~ ^[yY]$ ]]; then
        rm -rf ${VOLUME_PATH}
        echo -e "${GREEN}配置數據已刪除。${NC}"
    else
        echo -e "${YELLOW}配置數據已保留。${NC}"
    fi
}

# 更新 WARP 容器
update_warp() {
    if ! check_container_exists; then
        echo -e "${RED}錯誤: WARP 容器 (${CONTAINER_NAME}) 未找到。請先安裝。${NC}"
        return
    fi

    echo -e "${YELLOW}1. 正在拉取最新的 Docker 鏡像...${NC}"
    docker pull ${IMAGE_NAME}

    echo -e "${YELLOW}2. 正在停止並移除舊容器...${NC}"
    docker stop ${CONTAINER_NAME}
    docker rm ${CONTAINER_NAME}

    echo -e "${YELLOW}3. 正在使用原有配置重新創建容器...${NC}"
    echo -e "${GREEN}鏡像已更新。請再次運行安裝選項來使用新鏡像創建容器。您的註冊數據將會被保留。${NC}"
    install_warp
}

# 查看日誌
view_logs() {
    if ! check_container_exists; then
        echo -e "${RED}錯誤: WARP 容器 (${CONTAINER_NAME}) 未找到。${NC}"
        return
    fi
    echo -e "${YELLOW}正在顯示 WARP 容器的日誌 (按 Ctrl+C 退出)...${NC}"
    docker logs -f ${CONTAINER_NAME}
}

# 主菜單
start_menu() {
    clear
    echo "================================================="
    echo "    WARP Docker 容器一鍵管理腳本"
    echo "================================================="
    echo -e "${GREEN}1. 安裝 WARP 容器${NC}"
    echo -e "${GREEN}2. 卸載 WARP 容器${NC}"
    echo -e "${GREEN}3. 更新 WARP 容器${NC}"
    echo -e "${GREEN}4. 查看容器日誌${NC}"
    echo "-------------------------------------------------"
    echo -e "0. 退出腳本"
    echo ""

    # 顯示容器狀態
    if check_container_exists; then
        STATUS=$(docker inspect --format '{{.State.Status}}' ${CONTAINER_NAME})
        if [ "$STATUS" == "running" ]; then
            echo -e "容器狀態: ${GREEN}運行中${NC}"
        else
            echo -e "容器狀態: ${RED}${STATUS}${NC}"
        fi
    else
        echo -e "容器狀態: ${RED}未安裝${NC}"
    fi
    echo ""

    # (!!!修正點: 添加 < /dev/tty)
    read -p "請輸入選項 [0-4]: " num < /dev/tty
    case "$num" in
        1)
            install_warp
            ;;
        2)
            uninstall_warp
            ;;
        3)
            update_warp
            ;;
        4)
            view_logs
            ;;
        0)
            exit 0
            ;;
        *)
            clear
            echo -e "${RED}錯誤: 請輸入正確的數字 [0-4]${NC}"
            sleep 2
            start_menu
            ;;
    esac
}

# 腳本入口
check_docker
start_menu
