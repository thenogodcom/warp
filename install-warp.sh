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

# 2. 生成 Dockerfile (已添加 procps 包)
echo -e "\n${YELLOW}[2/6] 生成 Dockerfile...${NC}"
cat <<'EOF' > Dockerfile
FROM debian:stable-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y curl gnupg ca-certificates lsb-release procps && \
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list && \
    apt-get update && \
    apt-get install -y cloudflare-warp && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
VOLUME /var/lib/cloudflare-warp
EXPOSE 40000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
EOF
echo "Dockerfile 已創建。"
echo -e "${YELLOW}注意: Dockerfile 中的 EXPOSE 指令已設定為 40000 端口，這是 WARP 代理模式的預設端口。${NC}"

# 3. 生成啟動腳本 entrypoint.sh (修復註冊邏輯)
echo -e "\n${YELLOW}[3/6] 生成 entrypoint.sh 啟動腳本...${NC}"
cat <<'EOF' > entrypoint.sh
#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}殺死任何現有的 warp-svc 進程 (如果存在)...${NC}"
if pkill -x warp-svc -9; then
  echo -e "${GREEN}✔ 已殺死現有 warp-svc 進程。${NC}"
else
  echo -e "${YELLOW}ℹ 未發現現有 warp-svc 進程。${NC}"
fi

echo -e "${GREEN}▶ 啟動 warp-svc 後台服務...${NC}"
# 啟動 warp-svc 並過濾掉 dbus 相關日誌，使其輸出更清晰
/usr/bin/warp-svc > >(grep -iv dbus) 2> >(grep -iv dbus >&2) &
WARP_PID=$! # 獲取 warp-svc 進程 ID

# 設置信號捕獲，用於容器優雅關閉時停止 warp-svc
trap "echo -e '\n${YELLOW}捕獲到停止信號 (SIGTERM/SIGINT)，正在優雅關閉 warp-svc...${NC}'; kill -TERM $WARP_PID; exit" SIGTERM SIGINT

# --- 嘗試註冊 WARP 服務 ---
MAX_ATTEMPTS=20 # 增加嘗試次數以確保服務有足夠時間啟動

echo -e "${YELLOW}⌛ 嘗試啟動 warp-svc 並進行註冊...${NC}"

# 函數：檢查服務狀態並嘗試註冊
function attempt_registration {
  # 首先檢查是否已經註冊
  # warp-cli --accept-tos registration info 會在未註冊時返回非零狀態
  if warp-cli --accept-tos registration info &>/dev/null; then
    echo -e "${GREEN}✔ warp-svc 已就緒且已註冊。${NC}"
    return 0 # 已經註冊，直接返回成功
  fi

  # 如果未註冊，則嘗試新註冊
  echo -e "${YELLOW}➕ 尚未註冊，開始新註冊...${NC}"
  local current_attempt=0 # 函數內部局部變量
  until warp-cli --accept-tos registration new &> /dev/null; do
    echo -e "${YELLOW}等待 warp-svc 初始化並可註冊... 嘗試 $((++current_attempt)) 之 $MAX_ATTEMPTS${NC}"
    sleep 1
    if [[ $current_attempt -ge $MAX_ATTEMPTS ]]; then
      echo -e "${YELLOW}❌ 經過 $MAX_ATTEMPTS 次嘗試後，未能成功註冊 WARP 服務。${NC}"
      return 1 # 返回失敗狀態
    fi
  done
  echo -e "${GREEN}✔ warp-svc 已成功啟動並完成新註冊！${NC}"
  return 0
}

# 調用註冊函數，如果失敗則退出
if ! attempt_registration; then
  echo -e "${YELLOW}❌ 啟動服務或註冊 WARP 時出現嚴重問題。請檢查容器日誌獲取詳細信息。${NC}"
  kill $WARP_PID # 殺死 warp-svc 進程
  exit 1 # 退出容器
fi

# --- 配置 WARP 服務 ---
echo -e "${YELLOW}🛠 設定 WARP 代理模式及相關配置...${NC}"

# 設定 SOCKS5 代理端口 (warp-cli proxy 模式默認監聽 40000 端口，此為顯式設置)
warp-cli --accept-tos proxy port 40000
echo -e "${GREEN}✔ 代理端口設定為 40000。${NC}"

# 設定為 SOCKS5 代理模式
warp-cli --accept-tos set-mode proxy
echo -e "${GREEN}✔ 設定為 SOCKS5 代理模式。${NC}"

# 禁用 DNS 日誌，以保護隱私或減少日誌量
warp-cli --accept-tos dns log disable
echo -e "${GREEN}✔ DNS 日誌已禁用。${NC}"

# 設定 DNS Families 模式 (例如: ipv4, ipv6, auto)
# 默認為 'auto'，可通過環境變數 FAMILIES_MODE 設置
FAMILIES_MODE_DEFAULT="auto"
if [[ -z "$FAMILIES_MODE" ]]; then
  echo -e "${YELLOW}⚠ 環境變數 FAMILIES_MODE 未設置，將使用默認值: ${FAMILIES_MODE_DEFAULT}${NC}"
  FAMILIES_MODE="${FAMILIES_MODE_DEFAULT}"
fi
warp-cli --accept-tos dns families "${FAMILIES_MODE}"
echo -e "${GREEN}✔ DNS Families 模式設定為: ${FAMILIES_MODE}${NC}"


# 套用 WARP+ License（可選）
if [[ -n "$WARP_LICENSE_KEY" ]]; then # 使用 WARP_LICENSE_KEY 與 docker-compose.yml 保持一致
  echo -e "${YELLOW}🔑 正在套用 WARP+ 授權碼...${NC}"
  # 注意：即使授權碼無效，此命令也可能不會立即返回非零狀態，後續狀態檢查更重要
  warp-cli --accept-tos registration license "$WARP_LICENSE_KEY" || echo -e "${YELLOW}警告: 授權碼可能無效、已使用或存在其他問題。${NC}"
else
  echo -e "${YELLOW}ℹ 未提供 WARP_LICENSE_KEY，將使用免費 WARP 服務。${NC}"
fi

# --- 連接 WARP 服務 ---
echo -e "${YELLOW}🌐 嘗試連線 WARP 服務...${NC}"
warp-cli --accept-tos connect

# 循環檢查連接狀態，直到連接成功，或達到最大嘗試次數
MAX_CONNECT_ATTEMPTS=60 # 給予足夠時間嘗試連接 (60 秒)
connect_attempt_counter=0
while true; do
  if warp-cli --accept-tos status | grep -iq connected; then
    echo -e "${GREEN}✔ WARP 已成功連線！${NC}"
    break # 連接成功，退出循環
  else
    echo -e "${YELLOW}WARP 仍在嘗試連接中... 嘗試 $((++connect_attempt_counter)) 之 $MAX_CONNECT_ATTEMPTS${NC}"
    if [[ $connect_attempt_counter -ge $MAX_CONNECT_ATTEMPTS ]]; then
        echo -e "${YELLOW}❌ 經過 $MAX_CONNECT_ATTEMPTS 次嘗試後，未能成功連線 WARP。${NC}"
        warp-cli --accept-tos status # 顯示最終狀態，方便排查問題
        kill $WARP_PID # 殺死 warp-svc 進程
        exit 1 # 退出容器
    fi
    sleep 1 # 等待一秒後再次檢查
  fi
done

# --- 顯示最終 WARP 狀態 ---
echo -e "\n${GREEN}=== 最終 WARP 服務狀態 ===${NC}"
warp-cli --accept-tos status || true # 顯示當前 WARP 連接狀態
warp-cli --accept-tos registration info || true # 顯示註冊信息（包括是否為 WARP+）

echo -e "${GREEN}✅ WARP SOCKS5 代理已成功啟動並運行在主機的 40000 端口。${NC}"
echo -e "${GREEN}容器將保持運行以持續提供 WARP 代理服務。${NC}"

# 等待 warp-svc 進程結束，以確保容器保持活躍，直到 warp-svc 停止
wait $WARP_PID
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
      - "40000:40000" # 映射容器內部的 40000 端口到主機的 40000 端口
    environment:
      TZ: "Asia/Shanghai" # 設定時區，可根據需要修改
      # WARP_LICENSE_KEY: "YOUR_LICENSE_KEY_HERE" # 如果您有 WARP+ 授權碼，請在此處填寫並取消註釋
      # FAMILIES_MODE: "auto" # 可選：設置 DNS Families 模式 (例如: ipv4, ipv6, auto)。默認為 "auto"。
    cap_add:
      - MKNOD # 允許創建特殊文件，可能對某些 VPN 隧道類型有幫助
      - AUDIT_WRITE # 允許寫入審計日誌
      - NET_ADMIN # 允許執行網絡管理任務，如修改路由表、設置接口等
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=0 # 確保 IPv6 未禁用
      - net.ipv4.conf.all.src_valid_mark=1 # 啟用防火牆標記路由
    volumes:
      - ./data:/var/lib/cloudflare-warp # 將 WARP 數據持久化到主機的 ./data 目錄
EOF
echo "docker-compose.yml 已創建。"

# 5. 使用 Docker Compose 構建並在後台啟動容器
echo -e "\n${YELLOW}[5/6] 使用 Docker Compose 構建並啟動容器...${NC}"
docker compose up -d --build --force-recreate

# 6. 驗證代理服務
echo -e "\n${YELLOW}[6/6] 驗證代理服務...${NC}"
echo "容器正在後台啟動並連接 WARP，這可能需要一些時間（約 20-60 秒）..."
sleep 20 # 初始等待時間
for i in {1..4}; do # 再檢查 4 次，每次等待 10 秒
    if curl --socks5-hostname 127.0.0.1:40000 --retry 5 --retry-connrefused --connect-timeout 10 https://cloudflare.com/cdn-cgi/trace | grep -q "warp=on"; then
        echo -e "\n${GREEN}=== 部署成功！ ==="
        echo -e "WARP SOCKS5 代理正在運行於: 127.0.0.1:40000${NC}"
        echo "你可以通過以下命令查看容器日誌: cd ${PROJECT_DIR} && docker compose logs -f"
        echo "停止服務請運行: cd ${PROJECT_DIR} && docker compose down"
        exit 0
    fi
    echo -e "${YELLOW}驗證中... (${i}/4) 等待 10 秒後重試...${NC}"
    sleep 10
done

echo -e "\n${YELLOW}=== 部署可能失敗 ===${NC}"
echo "未能從驗證信息中檢測到 'warp=on'，或者服務啟動超時。"
echo "請手動檢查容器日誌以排除故障: cd ${PROJECT_DIR} && docker compose logs -f"
exit 1
