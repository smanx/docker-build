#!/bin/bash

# 确保以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 用户运行此脚本"
    exec sudo -E bash "$0" "$@"
fi

echo "[start-loop.sh] 启动开始"
echo "[start-loop.sh] 当前目录: $(pwd)"
echo "[start-loop.sh] 当前用户: $(id -un) (uid=$(id -u))"

# ========== 环境变量配置 ==========
DISABLE_TTYD=${DISABLE_TTYD:-}
DISABLE_TAILSCALE=${DISABLE_TAILSCALE:-}
DISABLE_CLOUDFLARED=${DISABLE_CLOUDFLARED:-}

TTYD_USER=${TTYD_USER:-admin}
TTYD_PASS=${TTYD_PASS:-zc123456}
TTYD_PORT=${TTYD_PORT:-7681}
# ==================================

# 添加 snap 路径到 PATH
export PATH="/snap/bin:$PATH"

# ========== 耗时统计函数 ==========
SCRIPT_START_TIME=$(date +%s)

step_start() {
    STEP_START_TIME=$(date +%s)
}

step_end() {
    local step_name="$1"
    local step_end_time=$(date +%s)
    local duration=$((step_end_time - STEP_START_TIME))
    local mins=$((duration / 60))
    local secs=$((duration % 60))
    if [ $mins -gt 0 ]; then
        echo "⏱️  $step_name 耗时: ${mins}分${secs}秒"
    else
        echo "⏱️  $step_name 耗时: ${secs}秒"
    fi
}

total_time() {
    local total_end_time=$(date +%s)
    local duration=$((total_end_time - SCRIPT_START_TIME))
    local mins=$((duration / 60))
    local secs=$((duration % 60))
    echo "══════════════════════════════════════════════════"
    echo "📋 总耗时: ${mins}分${secs}秒"
    echo "══════════════════════════════════════════════════"
}

trap total_time EXIT
# ====================================

# ========== 设置主机名 ==========
step_start
if [ -n "$HOSTNAME" ]; then
    echo "设置主机名: $HOSTNAME"
    sudo hostnamectl set-hostname "$HOSTNAME"
    sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$HOSTNAME/" /etc/hosts 2>/dev/null || true
    echo "✓ 主机名已设置为: $(hostname)"
fi
step_end "设置主机名"
# ====================================

# 确保 ~/.local/bin 在 PATH 中
export PATH="$HOME/.local/bin:$PATH"

# ========== TTYD 安装和启动 ==========
setup_ttyd() {
    if [ "$DISABLE_TTYD" = "true" ]; then
        echo "⏭️  TTYD 已禁用 (DISABLE_TTYD=$DISABLE_TTYD)"
        return 0
    fi

    echo "[ttyd] 安装并启动..."

    # 安装
    sudo apt update -y > /dev/null 2>&1
    sudo apt install snapd tmux -y > /dev/null 2>&1
    sudo snap install ttyd --classic > /dev/null 2>&1

    TTYD_CMD=""
    if ! command -v ttyd &> /dev/null; then
        if [ -x /snap/bin/ttyd ]; then
            TTYD_CMD="/snap/bin/ttyd"
        else
            echo "[ttyd] ✗ 安装失败"
            return 1
        fi
    else
        TTYD_CMD="ttyd"
    fi
    echo "[ttyd] ✓ 已安装"

    # 停止可能存在的进程
    pkill -f ttyd 2>/dev/null || true
    sleep 1

    # 启动
    $TTYD_CMD -p $TTYD_PORT -W -c "$TTYD_USER:$TTYD_PASS" bash &
    TTYD_PID=$!

    # 等待端口就绪
    for i in $(seq 1 10); do
      if netstat -tuln 2>/dev/null | grep -q ":$TTYD_PORT" || ss -tuln 2>/dev/null | grep -q ":$TTYD_PORT"; then
        echo "[ttyd] ✓ 端口 $TTYD_PORT 就绪"
        break
      fi
      sleep 1
    done

    if ps -p $TTYD_PID > /dev/null; then
        echo "[ttyd] ✓ 启动成功 (PID: $TTYD_PID, 端口: $TTYD_PORT)"
        echo "  用户: $TTYD_USER"
        echo $TTYD_PID > ttyd.pid
    else
        echo "[ttyd] ✗ 启动失败"
        return 1
    fi
}
# ====================================

# ========== Tailscale 安装和启动 ==========
setup_tailscale() {
    if [ "$DISABLE_TAILSCALE" = "true" ]; then
        echo "⏭️  Tailscale 已禁用 (DISABLE_TAILSCALE=$DISABLE_TAILSCALE)"
        return 0
    fi

    echo "[tailscale] 安装并启动..."

    # 安装
    if ! command -v tailscale &> /dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh > /dev/null 2>&1
    fi

    if ! command -v tailscale &> /dev/null; then
        echo "[tailscale] ✗ 安装失败"
        return 1
    fi
    echo "[tailscale] ✓ 已安装"

    # 清理旧进程
    sudo systemctl stop tailscaled 2>/dev/null || true
    sudo pkill -9 -x tailscaled 2>/dev/null || true
    sudo ip link delete tailscale0 2>/dev/null || true
    sudo rm -f /var/run/tailscale/tailscaled.sock 2>/dev/null || true
    sleep 2

    # 启动 tailscaled
    if sudo systemctl start tailscaled 2>/dev/null; then
        echo "[tailscale] ✓ tailscaled 已启动"
    else
        echo "[tailscale] 手动启动 tailscaled..."
        sudo tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock 2>/tmp/tailscaled.log &
    fi

    # 等待 socket 就绪
    for i in $(seq 1 10); do
      if [ -S /var/run/tailscale/tailscaled.sock ]; then
        echo "[tailscale] ✓ socket 就绪"
        break
      fi
      sleep 1
    done

    # 检查是否已连接
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
    if [ -n "$TAILSCALE_IP" ]; then
        TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | grep -o '"HostName":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
        echo "[tailscale] ✓ 已连接"
        echo "  IP: $TAILSCALE_IP"
        echo "  主机名: $TAILSCALE_HOSTNAME"
    else
        echo "[tailscale] ⏳ 等待登录..."
        (
            sudo tailscale up --ssh 2>&1 | tee /tmp/tailscale-up.log &
            for i in $(seq 1 30); do
                if [ -f /tmp/tailscale-up.log ]; then
                    LOGIN_URL=$(grep -oE 'https://login\.tailscale\.com/[a-zA-Z0-9]+' /tmp/tailscale-up.log 2>/dev/null | head -1)
                    if [ -z "$LOGIN_URL" ]; then
                        LOGIN_URL=$(grep -oE 'https://tailscale\.com/login/[a-zA-Z0-9]+' /tmp/tailscale-up.log 2>/dev/null | head -1)
                    fi
                    if [ -n "$LOGIN_URL" ]; then
                        echo ""
                        echo "============================================="
                        echo "[tailscale] 🔗 登录链接: $LOGIN_URL"
                        echo "============================================="
                        break
                    fi
                fi
                sleep 1
            done

            for i in $(seq 1 60); do
                TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
                if [ -n "$TAILSCALE_IP" ]; then
                    TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | grep -o '"HostName":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
                    echo "[tailscale] ✓ 登录成功"
                    echo "  IP: $TAILSCALE_IP"
                    echo "  主机名: $TAILSCALE_HOSTNAME"
                    break
                fi
                sleep 5
            done
        ) &
    fi
}
# ====================================

# ========== Cloudflared 安装和启动 ==========
setup_cloudflared() {
    if [ "$DISABLE_CLOUDFLARED" = "true" ]; then
        echo "⏭️  Cloudflared 已禁用 (DISABLE_CLOUDFLARED=$DISABLE_CLOUDFLARED)"
        return 0
    fi

    echo "[cloudflared] 安装并启动..."

    # 安装
    if ! command -v cloudflared &> /dev/null; then
        ARCH=$(uname -m)
        if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
            DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/download/2025.10.1/cloudflared-linux-arm64"
        else
            DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/download/2025.10.1/cloudflared-linux-amd64"
        fi
        wget -q "$DOWNLOAD_URL" -O /tmp/cloudflared
        chmod +x /tmp/cloudflared
        sudo mv /tmp/cloudflared /usr/local/bin/cloudflared
    fi

    if ! command -v cloudflared &> /dev/null; then
        echo "[cloudflared] ✗ 安装失败"
        return 1
    fi
    echo "[cloudflared] ✓ 已安装"

    # 停止可能存在的进程
    pkill -f cloudflared 2>/dev/null || true

    # 启动
    if [ -n "$CF_TUNNEL_TOKEN" ]; then
        echo "[cloudflared] 使用固定隧道..."
        nohup cloudflared tunnel run --token "$CF_TUNNEL_TOKEN" > cloudflared.log 2>&1 &
        CLOUDFLARED_PID=$!

        for i in $(seq 1 10); do
          if ps -p $CLOUDFLARED_PID > /dev/null; then
            echo "[cloudflared] ✓ 固定隧道启动 (PID: $CLOUDFLARED_PID)"
            echo $CLOUDFLARED_PID > cloudflared.pid
            break
          fi
          sleep 1
        done

        if ! ps -p $CLOUDFLARED_PID > /dev/null; then
            echo "[cloudflared] ✗ 固定隧道启动失败"
        fi
    else
        echo "[cloudflared] 使用临时隧道..."
        nohup cloudflared tunnel --url http://localhost:$TTYD_PORT > cloudflared-ttyd.log 2>&1 &
        CLOUDFLARED_PID=$!

        for i in $(seq 1 30); do
            if [ -f cloudflared-ttyd.log ]; then
                TTYD_URL=$(grep -o "https://[a-zA-Z0-9.-]*\.trycloudflare\.com" cloudflared-ttyd.log | head -1)
                if [ -n "$TTYD_URL" ]; then
                    echo "[cloudflared] ✓ 临时隧道: $TTYD_URL"
                    echo $CLOUDFLARED_PID > cloudflared-ttyd.pid
                    break
                fi
            fi
            sleep 1
        done
    fi
}
# ====================================

# ========== 主流程 ==========
echo ""
echo "============================================="
echo "配置信息"
echo "============================================="
echo "DISABLE_TTYD=$DISABLE_TTYD (端口: $TTYD_PORT)"
echo "DISABLE_TAILSCALE=$DISABLE_TAILSCALE"
echo "DISABLE_CLOUDFLARED=$DISABLE_CLOUDFLARED"
echo "============================================="

step_start
echo ""
echo ">>> 并行安装并启动服务..."
echo ""

# Tailscale 需要串行安装（安装脚本可能有交互）
setup_tailscale

# ttyd 和 cloudflared 可以并行
setup_ttyd &
PID_TTYD=$!
setup_cloudflared &
PID_CF=$!

wait $PID_TTYD $PID_CF

step_end "并行安装并启动服务"

# 打印服务启动总耗时
SERVICE_END=$(date +%s)
SERVICE_DURATION=$((SERVICE_END - SCRIPT_START_TIME))
SERVICE_MINS=$((SERVICE_DURATION / 60))
SERVICE_SECS=$((SERVICE_DURATION % 60))
echo ""
echo "══════════════════════════════════════════════════"
echo "📋 服务启动总耗时: ${SERVICE_MINS}分${SERVICE_SECS}秒"
echo "══════════════════════════════════════════════════"

# 显示访问信息
echo ""
echo "=================================================="
echo "安装完成！"
echo "=================================================="

IP=$(hostname -I | awk '{print $1}')

if [ "$DISABLE_TTYD" != "true" ]; then
    echo ""
    echo "【ttyd 终端】"
    echo "  本地访问: http://$IP:$TTYD_PORT"
    if [ -n "$TTYD_URL" ]; then
        echo "  外网访问: $TTYD_URL"
    fi
fi

if [ "$DISABLE_TAILSCALE" != "true" ]; then
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
    if [ -n "$TAILSCALE_IP" ]; then
        TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | grep -o '"HostName":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
        echo ""
        echo "【Tailscale SSH】"
        echo "  IP: $TAILSCALE_IP"
        echo "  主机名: $TAILSCALE_HOSTNAME"
        echo "  连接: ssh $TAILSCALE_IP"
    fi
fi

if [ "$DISABLE_CLOUDFLARED" != "true" ] && [ -n "$CF_TUNNEL_TOKEN" ]; then
    echo ""
    echo "【固定隧道模式】"
    echo "  请在 Cloudflare 控制台配置域名路由："
    echo "  ttyd.yourdomain.com -> http://localhost:$TTYD_PORT"
fi

echo "=================================================="

# 自定义启动脚本
step_start
CUSTOM_START="/root/mydata/start.sh"
if [ -f "$CUSTOM_START" ]; then
    echo ""
    echo "检测到自定义启动脚本: $CUSTOM_START"
    if [ -x "$CUSTOM_START" ]; then
        "$CUSTOM_START" || echo "⚠ 自定义启动脚本执行失败: $CUSTOM_START"
    else
        bash "$CUSTOM_START" || echo "⚠ 自定义启动脚本执行失败: $CUSTOM_START"
    fi
else
    echo ""
    echo "未检测到自定义启动脚本: $CUSTOM_START"
    echo "如需自定义启动命令，请创建该脚本文件"
fi
step_end "自定义启动脚本"
