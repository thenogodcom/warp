#!/bin/bash

# 當任何命令失敗時立即退出腳本
set -e

# --- 美化輸出 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
# ---

# 檢查 Docker 和 Docker Compose 是否已安裝
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}錯誤: Docker 未安裝。請先安裝 Docker 再運行此腳本。${NC}"
    exit 1
fi
if ! docker compose version &> /dev/null; then
    echo -e "${YELLOW}錯誤: Docker Compose 未安裝。請先安裝 Docker Compose 再運行此腳本。${NC}"
    exit 1
fi

PROJECT_DIR="my-warp-proxy"

echo -e "${GREEN}=== 開始部署自定義 WARP 代理容器 ===${NC}"

# 1. 創建並進入項目目錄
echo -e "\n${YELLOW}[1/6] 創建項目目錄: ${PROJECT_DIR}${NC}"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"
echo "完成。當前目錄: $(pwd)"

# 2. 生成 Dockerfile
echo -e "\n${YELLOW}[2/6] 生成 Dockerfile...${NC}"
cat <<'EOF' > Dockerfile
FROM debian:stable-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y curl gnupg ca-certificates lsb-release && \
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list && \
    apt-get update && \
    apt-get install -y cloudflare-warp && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
VOLUME /var/lib/cloudflare-warp
EXPOSE 1080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
EOF
echo "Dockerfile 已創建。"

# 3. 生成啟動腳本 entrypoint.sh (最終穩健版)
echo -e "\n${YELLOW}[3/6] 生成 entrypoint.sh 啟動腳本...${NC}"
cat <<'EOF' > entrypoint.sh
#!/bin/bash
set -e
echo "Starting WARP entrypoint script..."
/usr/bin/warp-svc &
sleep "${WARP_SLEEP:-5}"

echo "Setting WARP to SOCKS5 proxy mode..."
warp-cli --accept-tos mode proxy || echo "Failed to set mode, continuing..."
warp-cli --accept-tos proxy-port 1080 || echo "Failed to set port, continuing..."

if [ ! -f /var/lib/cloudflare-warp/reg.json ]; then
  echo "WARP is not registered. Registering now..."
  warp-cli --accept-tos registration new
  echo "Registration complete."
else
  echo "WARP is already registered."
fi

if [ -n "$WARP_LICENSE_KEY" ]; then
    echo "Setting WARP+ license key..."
    warp-cli --accept-tos registration license "$WARP_LICENSE_KEY"
    echo "License key set."
fi

echo "Connecting to WARP..."
warp-cli --accept-tos connect

echo "WARP proxy is running. Tailing logs to keep container alive."
tail -f /dev/null
EOF
chmod +x entrypoint.sh
echo "entrypoint.sh 已創建並設為可執行。"

# 4. 生成 docker-compose.yml 文件 (已移除 version 標籤)
echo -e "\n${YELLOW}[4/6] 生成 docker-compose.yml...${NC}"
cat <<'EOF' > docker-compose.yml
services:
  warp:
    build: .
    image: my-warp-proxy:latest
    container_name: warp-proxy-custom
    restart: always
    device_cgroup_rules:
      - 'c 10:200 rwm'
    ports:
      - "1080:1080"
    environment:
      - WARP_SLEEP=5
      # - WARP_LICENSE_KEY=YOUR_LICENSE_KEY_HERE
    cap_add:
      - MKNOD
      - AUDIT_WRITE
      - NET_ADMIN
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv4.conf.all.src_valid_mark=1
    volumes:
      - ./data:/var/lib/cloudflare-warp
EOF
echo "docker-compose.yml 已創建。"

# 5. 構建並在後台啟動容器
echo -e "\n${YELLOW}[5/6] 使用 Docker Compose 構建並啟動容器...${NC}"
docker compose up -d --build

# 6. 驗證結果
echo -e "\n${YELLOW}[6/6] 驗證代理服務...${NC}"
echo "容器正在後台啟動，請等待約 15 秒..."
sleep 15
echo "正在發送測試請求到 https://cloudflare.com/cdn-cgi/trace"
if curl --socks5-hostname 127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace | grep -q "warp=on"; then
    echo -e "\n${GREEN}=== 部署成功！ ==="
    echo -e "WARP SOCKS5 代理正在運行於: 127.0.0.1:1080${NC}"
    echo "你可以通過以下命令查看日誌: cd ${PROJECT_DIR} && docker compose logs -f"
    echo "停止服務請運行: cd ${PROJECT_DIR} && docker compose down"
else
    echo -e "\n${YELLOW}=== 部署可能失敗 ===${NC}"
    echo "未能從驗證信息中檢測到 'warp=on'。"
    echo "請手動檢查容器日誌: cd ${PROJECT_DIR} && docker compose logs -f"
fi
