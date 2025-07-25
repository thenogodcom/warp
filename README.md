# 🌐 Caddy + WARP + Hysteria (hwc) 終極一鍵部署與管理腳本

---

## 🚀 一鍵安裝

請使用 `root` 權限在終端執行以下命令：

```bash
curl -sSL https://raw.githubusercontent.com/thenogodcom/warp/main/hwc.sh | sudo bash
```

首次執行會自動安裝腳本至 `/usr/local/bin/hwc` 並進入主選單。
之後僅需執行：

```bash
hwc
```

即可隨時啟動管理介面。

---

<img width="100%" alt="Caddy + WARP + Hysteria" src="https://github.com/user-attachments/assets/83c1984a-a809-451b-b84a-19dfb8c0aa1f" />

---

## 🧩 安裝順序建議

為獲得最佳體驗，建議按照以下步驟操作：

### 1️⃣ 安裝 Caddy

* 主選單 ➜ `1. 管理 Caddy` ➜ `1. 安裝 Caddy`
* 輸入您的 **域名** 與 **Email**，自動申請 HTTPS 證書

### 2️⃣ 安裝 WARP

* 返回主選單 ➜ `2. 管理 WARP` ➜ `1. 安裝 WARP`

### 3️⃣ 安裝 Hysteria2

* 返回主選單 ➜ `3. 管理 Hysteria` ➜ `1. 安裝 Hysteria`
* 預設會偵測 Caddy 配置的域名，您只需輸入連線密碼

---

## 📋 快速開始指南

在啟動腳本前，請確認以下條件已準備完成：

### ✅ 系統需求

1. 已安裝 **Docker** 與 **Docker Compose** 的 Linux 伺服器
   （Ubuntu / Debian / CentOS 等皆可）

2. 一個有效的域名，並將其 **A/AAAA 記錄** 指向伺服器的公開 IP

3. 防火牆已開啟以下端口：

| 協議  | 端口  | 用途           |
| --- | --- | ------------ |
| TCP | 80  | Caddy 申請憑證   |
| TCP | 443 | HTTPS 流量與憑證  |
| UDP | 443 | Hysteria2 傳輸 |

---

## ⚙️ 功能總覽

這是一款集成以下功能的一站式自動化部署腳本：

* ✅ **Caddy** – 自動配置 TLS/HTTPS，憑證自動續期
* ✅ **Cloudflare WARP** – 提供高匿名、低延遲的流量中繼
* ✅ **Hysteria2** – 基於 UDP 的極速代理協議，突破網路限制
* ✅ **Docker 化部署** – 可攜、乾淨、可重複的管理方式

---

## 🧠 項目目的

透過一行命令，快速構建一個：

* 穩定安全的 HTTPS 入口
* 高效加密的代理後端
* 零手動配置的全自動化方案

---

歡迎 star ⭐ 本專案，並持續關注更多功能更新！

👉 GitHub Repo: [thenogodcom/warp](https://github.com/thenogodcom/warp)

---
