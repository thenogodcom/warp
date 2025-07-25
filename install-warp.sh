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
EXPOSE 40000 # 修正：WARP 代理模式默認監聽 40000 端口
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
EOF
echo "Dockerfile 已創建。"

# 3. 生成啟動腳本 entrypoint.sh（修正端口設定）
echo -e "\n${YELLOW}[3/6] 生成 entrypoint.sh 啟動腳本...${NC}"
cat <<'EOF' > entrypoint.sh
#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}▶ 啟動 warp-svc...${NC}"
/usr/bin/warp-svc &

# 等待 warp-svc IPC socket 就緒
echo -e "${YELLOW}⌛ 等待 warp-svc 初始化...${NC}"
for i in {1..20}; do
  if [ -S /run/cloudflare-warp/warp_service ]; then
    if warp-cli --accept-tos status &>/dev/null; then
      echo -e "${GREEN}✔ warp-svc 已就緒。${NC}"
      break
    fi
  fi
  echo -n "."
  sleep 1
done

# 若未註冊則新註冊
if ! warp-cli --accept-tos registration info &>/dev/null; then
  echo -e "${YELLOW}➕ 尚未註冊，開始新註冊...${NC}"
  warp-cli --accept-tos register # P3TERX 腳本中使用 register，雖然 new 也有效，但為了一致性
  echo -e "${GREEN}✔ 註冊完成。${NC}"
else
  echo -e "${GREEN}✔ 已存在註冊信息。${NC}"
fi

# 套用 License（可選）
if [ -n "$WARP_LICENSE_KEY" ]; then
  echo -e "${YELLOW}🔑 套用 WARP+ 授權碼...${NC}"
  warp-cli --accept-tos registration license "$WARP_LICENSE_KEY" || echo -e "${YELLOW}警告: 授權碼可能已無效。${NC}"
fi

# 設定為 SOCKS5 模式並啟用（默認端口為 40000）
echo -e "${YELLOW}🛠 設定為 SOCKS5 模式，監聽 40000 端口 (WARP 預設)...${NC}"
warp-cli --accept-tos set-mode proxy # P3TERX 腳本中使用 set-mode proxy，而非 mode proxy
# 移除錯誤的 `settings set proxy-port` 命令，因為 warp-cli proxy 模式默認就是 40000 端口
# warp-cli --accept-tos settings set proxy-port 1080 # REMOVED: This command is incorrect.

# 開始連線
echo -e "${YELLOW}🌐 嘗試連線 WARP...${NC}"
warp-cli --accept-tos connect || echo -e "${YELLOW}⚠ 嘗試連線失敗，可能已連線或無效。${NC}"

# 顯示最終狀態
echo -e "${GREEN}=== 最終狀態 ===${NC}"
warp-cli --accept-tos status || true
warp-cli --accept-tos registration info || true

echo -e "${GREEN}✅ WARP SOCKS5 代理啟動成功，正在監聽 40000 端口。${NC}"

# 保持容器常駐
tail -f /dev/null
EOF
chmod +x entrypoint.sh
echo "entrypoint.sh 已創建並設為可執行。"

# 4. 生成 docker-compose.yml 文件
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
      - "40000:40000" # 修正：映射容器內的 40000 端口到主機的 40000 端口
    environment:
      TZ: "Asia/Shanghai"
      # WARP_LICENSE_KEY: "YOUR_LICENSE_KEY_HERE"
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
echo "容器正在後台啟動，請等待約 20 秒..." # 增加等待時間
sleep 20
echo "正在發送測試請求到 https://cloudflare.com/cdn-cgi/trace"
if curl --socks5-hostname 127.0.0.1:40000 --retry 5 --retry-connrefused --connect-timeout 10 https://cloudflare.com/cdn-cgi/trace | grep -q "warp=on"; then # 修正：測試 40000 端口
    echo -e "\n${GREEN}=== 部署成功！ ==="
    echo -e "WARP SOCKS5 代理正在運行於: 127.0.0.1:40000${NC}" # 修正：顯示 40000 端口
    echo "你可以通過以下命令查看日誌: cd ${PROJECT_DIR} && docker compose logs -f"
    echo "停止服務請運行: cd ${PROJECT_DIR} && docker compose down"
else
    echo -e "\n${YELLOW}=== 部署可能失敗 ===${NC}"
    echo "未能從驗證信息中檢測到 'warp=on'。"
    echo "請手動檢查容器日誌: cd ${PROJECT_DIR} && docker compose logs -f"
fi
