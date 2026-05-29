#!/bin/bash

# 确保以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 用户运行此脚本"
    exec sudo -E bash "$0" "$@"
fi

echo "[start-loop.sh] 启动开始"
echo "[start-loop.sh] 当前目录: $(pwd)"
echo "[start-loop.sh] 当前用户: $(id -un) (uid=$(id -u))"

. /root/.bashrc
. /root/.profile

SCRIPT_START_TIME=$(date +%s)

step_end() {
    local step_name="$1"
    local duration=$(($(date +%s) - SCRIPT_START_TIME))
    local mins=$((duration / 60))
    local secs=$((duration % 60))
    echo "⏱️  $step_name 总耗时: ${mins}分${secs}秒"
}

trap 'step_end "全部完成"' EXIT

export PATH="/snap/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

TTYD_USER="admin"
TTYD_PASS="zc123456"

# 设置主机名
[ -n "$HOSTNAME" ] && sudo hostnamectl set-hostname "$HOSTNAME" 2>/dev/null

echo ">>> 启动并行安装..."

# 并行安装三个组件
(
    echo "[1/3] 安装 ttyd..."
    sudo apt update -y -qq
    sudo apt install -y -qq snapd tmux
    sudo snap install ttyd --classic 2>/dev/null || sudo apt install -y -qq ttyd
    echo "[1/3] ttyd 安装完成"
) &
PID_TTYD=$!

(
    echo "[2/3] 安装 Tailscale..."
    if ! command -v tailscale &>/dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh -s -- --no-daemon 2>/dev/null
    fi
    echo "[2/3] Tailscale 安装完成"
) &
PID_TS=$!

(
    echo "[3/3] 安装 Cloudflared..."
    if ! command -v cloudflared &>/dev/null; then
        ARCH=$(uname -m)
        URL="https://github.com/cloudflare/cloudflared/releases/download/2025.10.1/cloudflared-linux-${ARCH#arm}.tar.gz"
        [ "$ARCH" = "aarch64" ] && URL="https://github.com/cloudflare/cloudflared/releases/download/2025.10.1/cloudflared-linux-arm64"
        [ "$ARCH" = "x86_64" ] && URL="https://github.com/cloudflare/cloudflared/releases/download/2025.10.1/cloudflared-linux-amd64"
        curl -fsSL "$URL" -o /tmp/cloudflared.tar.gz
        tar -xzf /tmp/cloudflared.tar.gz -C /tmp
        sudo mv /tmp/cloudflared /usr/local/bin/cloudflared
        chmod +x /usr/local/bin/cloudflared
        rm -f /tmp/cloudflared.tar.gz
    fi
    echo "[3/3] Cloudflared 安装完成"
) &
PID_CF=$!

wait $PID_TTYD $PID_TS $PID_CF
echo "✅ 所有组件安装完成"

# 停止可能存在的旧进程
pkill -f ttyd 2>/dev/null || true
pkill -f cloudflared 2>/dev/null || true

echo ">>> 启动并行服务..."

# 启动 Tailscale
if command -v tailscale &>/dev/null; then
    echo ">>> 启动 Tailscale..."
    sudo systemctl stop tailscaled 2>/dev/null || true
    sudo pkill -9 -x tailscaled 2>/dev/null || true
    sleep 1

    # 使用 nohup 确保 Tailscale 持续运行
    nohup sudo tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock > /tmp/tailscaled.log 2>&1 &
    sleep 3

    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
    if [ -z "$TAILSCALE_IP" ]; then
        echo "⏳ Tailscale 正在后台连接..."
        # 后台执行登录，不阻塞
        (sudo tailscale up --ssh 2>&1 &
        sleep 60) &
    else
        echo "✅ Tailscale 已连接: $TAILSCALE_IP"
    fi
fi

# 启动 ttyd
TTYD_CMD="ttyd"
[ ! -x "$(command -v ttyd)" ] && [ -x "/snap/bin/ttyd" ] && TTYD_CMD="/snap/bin/ttyd"

if [ -x "$(command -v $TTYD_CMD)" ] || [ -x "$TTYD_CMD" ]; then
    $TTYD_CMD -p 7681 -W -c "$TTYD_USER:$TTYD_PASS" bash &
    echo "✅ ttyd 已启动 (端口 7681)"
fi

# 启动 Cloudflared 隧道
if [ -n "$CF_TUNNEL_TOKEN" ]; then
    nohup cloudflared tunnel run --token "$CF_TUNNEL_TOKEN" > cloudflared.log 2>&1 &
    echo "✅ Cloudflared 固定隧道已启动"
else
    nohup cloudflared tunnel --url http://localhost:7681 > cloudflared-ttyd.log 2>&1 &
    echo "✅ Cloudflared 临时隧道已启动"

    # 后台获取 URL
    (
        for i in $(seq 1 20); do
            TTYD_URL=$(grep -o "https://[a-zA-Z0-9.-]*\.trycloudflare\.com" cloudflared-ttyd.log 2>/dev/null | head -1)
            [ -n "$TTYD_URL" ] && echo "🌐 外网地址: $TTYD_URL" && break
            sleep 1
        done
    ) &
fi

# 等待服务端口就绪
sleep 2

# 显示访问信息
IP=$(hostname -I | awk '{print $1}')
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

echo ""
echo "=================================================="
echo "✅ 安装完成！"
echo "=================================================="
echo ""
echo "【ttyd 终端】"
echo "  本地访问: http://$IP:7681"
echo "  用户名: $TTYD_USER"
echo "  密码: $TTYD_PASS"
echo ""

if [ -n "$TAILSCALE_IP" ]; then
    echo "【Tailscale SSH】"
    echo "  IP: $TAILSCALE_IP"
    echo "  SSH: ssh $TAILSCALE_IP"
    echo ""
fi

if [ -n "$CF_TUNNEL_TOKEN" ]; then
    echo "【Cloudflare 固定隧道】"
    echo "  需在 Cloudflare 配置域名路由"
else
    echo "【外网访问】"
    echo "  查看地址: tail -f cloudflared-ttyd.log | grep trycloudflare"
fi

echo "=================================================="

# 保存 PID
pgrep -f "ttyd.*7681" > ttyd.pid 2>/dev/null || echo $$ > ttyd.pid
pgrep -f "cloudflared" > cloudflared.pid 2>/dev/null || echo $$ >> cloudflared.pid

# 执行自定义启动脚本（如果存在）
CUSTOM_START="/root/mydata/start.sh"
if [ -f "$CUSTOM_START" ]; then
    echo ""
    echo ">>> 执行自定义启动脚本..."
    bash "$CUSTOM_START" || echo "⚠ 自定义脚本执行完成"
fi

echo ""
echo "✅ 所有服务已启动，脚本将在工作流结束时停止"
