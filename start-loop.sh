#!/bin/bash

# 设置系统主机名
if [ -n "$HOSTNAME" ]; then
    echo "设置主机名: $HOSTNAME"
    sudo hostnamectl set-hostname "$HOSTNAME"
    # 更新 /etc/hosts
    sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$HOSTNAME/" /etc/hosts 2>/dev/null || true
    echo "✓ 主机名已设置为: $(hostname)"
fi

echo "正在安装 ttyd、code-server、Cloudflared、Tailscale..."

# 安装 ttyd（snap 依赖）
sudo apt update -y
sudo apt install snapd tmux -y
sudo snap install ttyd --classic &

# 后台并行安装（加快启动速度）
echo "后台并行安装 opencode、iflow-cli、code-server、Cloudflared、Tailscale..."
(curl -fsSL https://opencode.ai/install | bash) &
(bash -c "$(curl -fsSL https://gitee.com/iflow-ai/iflow-cli/raw/main/install.sh)") &
(curl -fsSL https://code-server.dev/install.sh | sh) &

# 后台安装 Cloudflared
(ARCH=$(uname -m)
 if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
     wget -q https://github.com/cloudflare/cloudflared/releases/download/2025.10.1/cloudflared-linux-arm64 -O cloudflared
 else
     wget -q https://github.com/cloudflare/cloudflared/releases/download/2025.10.1/cloudflared-linux-amd64 -O cloudflared
 fi
 chmod +x cloudflared
 sudo mv cloudflared /usr/local/bin/) &

# 后台安装 Tailscale
(curl -fsSL https://tailscale.com/install.sh | sh) &

# 等待所有后台安装完成
echo "等待后台安装完成..."
wait
echo "✓ 所有安装完成"

# 停止可能存在的进程
pkill -f ttyd 2>/dev/null || true
pkill -f cloudflared 2>/dev/null || true
pkill -f code-server 2>/dev/null || true

# 连接 Tailscale（手动登录）
echo "正在启动 Tailscale..."

# 先停止可能存在的 tailscaled 进程和清理 socket
sudo pkill -f tailscaled 2>/dev/null || true
sudo rm -f /var/run/tailscale/tailscaled.sock 2>/dev/null || true
sleep 2

# 启动 tailscaled
sudo tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock 2>/tmp/tailscaled.log &
sleep 5

# 检查 tailscaled 是否运行
if ! pgrep -x tailscaled > /dev/null; then
    echo "✗ tailscaled 启动失败"
    cat /tmp/tailscaled.log
fi

# 启动 Tailscale 并获取登录链接
echo "获取 Tailscale 登录链接..."
TAILSCALE_OUTPUT=$(sudo tailscale up --ssh 2>&1)
echo "Tailscale 输出: $TAILSCALE_OUTPUT"

# 尝试多种方式获取登录链接
LOGIN_URL=$(echo "$TAILSCALE_OUTPUT" | grep -oE 'https://login\.tailscale\.com/[a-zA-Z0-9]+' | head -1)
if [ -z "$LOGIN_URL" ]; then
    LOGIN_URL=$(echo "$TAILSCALE_OUTPUT" | grep -oE 'https://tailscale\.com/login/[a-zA-Z0-9]+' | head -1)
fi
if [ -z "$LOGIN_URL" ]; then
    LOGIN_URL=$(echo "$TAILSCALE_OUTPUT" | grep -oE 'http[s]?://[^ ]*login[^ ]*' | head -1)
fi

if [ -n "$LOGIN_URL" ]; then
    echo ""
    echo "============================================="
    echo "🔗 Tailscale 登录链接："
    echo "   $LOGIN_URL"
    echo "============================================="
    echo "请在浏览器中打开链接完成登录"
    echo ""

    # 等待登录完成（最多等待 5 分钟）
    echo "等待登录完成..."
    for i in $(seq 1 60); do
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
        if [ -n "$TAILSCALE_IP" ]; then
            TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | grep -o '"HostName":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
            echo ""
            echo "✓ Tailscale 登录成功"
            echo "  IP: $TAILSCALE_IP"
            echo "  主机名: $TAILSCALE_HOSTNAME"
            echo "  SSH: ssh $TAILSCALE_IP 或 ssh $TAILSCALE_HOSTNAME"
            break
        fi
        sleep 5
    done

    if [ -z "$TAILSCALE_IP" ]; then
        echo "⚠ 等待登录超时，请手动检查: tailscale status"
    fi
else
    # 可能已经登录过或输出格式变化
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
    if [ -n "$TAILSCALE_IP" ]; then
        TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | grep -o '"HostName":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
        echo "✓ Tailscale 已连接"
        echo "  IP: $TAILSCALE_IP"
        echo "  主机名: $TAILSCALE_HOSTNAME"
        echo "  SSH: ssh $TAILSCALE_IP 或 ssh $TAILSCALE_HOSTNAME"
    else
        echo "⚠ 未获取到登录链接，请手动运行: sudo tailscale up"
        echo "  查看日志: cat /tmp/tailscaled.log"
    fi
fi

# 启动 ttyd（关键：-W 允许写入，直接运行 bash）
echo "启动 ttyd..."
ttyd -p 7681 -W bash &
TTYD_PID=$!

# 等待启动
sleep 3

# 检查 ttyd 是否运行
if ps -p $TTYD_PID > /dev/null; then
    echo "✓ ttyd 启动成功 (PID: $TTYD_PID)"
else
    echo "✗ ttyd 启动失败，尝试重新启动..."
    ttyd -p 7681 -W bash &
    TTYD_PID=$!
    sleep 2
fi

# 检查端口
if netstat -tuln | grep -q ":7681"; then
    echo "✓ ttyd 正在监听端口 7681"
else
    echo "✗ ttyd 未监听端口 7681"
    exit 1
fi

# 启动 code-server
echo "启动 code-server..."
code-server --bind-addr 0.0.0.0:8080 --auth none &
CODE_PID=$!
sleep 5

# 检查 code-server 是否运行
if ps -p $CODE_PID > /dev/null; then
    echo "✓ code-server 启动成功 (PID: $CODE_PID)"
else
    echo "✗ code-server 启动失败"
fi

# 启动 Cloudflared 隧道
if [ -n "$CF_TUNNEL_TOKEN" ]; then
    echo "使用 Cloudflare 固定隧道..."
    # 固定隧道需要在 Cloudflare 控制台配置路由：
    # ttyd.yourdomain.com -> http://localhost:7681
    # code.yourdomain.com -> http://localhost:8080
    nohup cloudflared tunnel run --token "$CF_TUNNEL_TOKEN" > cloudflared.log 2>&1 &
    CLOUDFLARED_PID=$!
    sleep 5

    if ps -p $CLOUDFLARED_PID > /dev/null; then
        echo "✓ 固定隧道启动成功 (PID: $CLOUDFLARED_PID)"
    else
        echo "✗ 固定隧道启动失败，请检查 Token"
        cat cloudflared.log
    fi
    echo $CLOUDFLARED_PID > cloudflared.pid
else
    # 使用临时隧道（每次 URL 会变）
    echo "使用 Cloudflare 临时隧道..."

    # 启动 Cloudflared 隧道 (ttyd)
    echo "启动 Cloudflared 隧道 (ttyd)..."
    nohup cloudflared tunnel --url http://localhost:7681 > cloudflared-ttyd.log 2>&1 &
    CLOUDFLARED_TTYD_PID=$!

    # 启动 Cloudflared 隧道 (code-server)
    echo "启动 Cloudflared 隧道 (code-server)..."
    nohup cloudflared tunnel --url http://localhost:8080 > cloudflared-code.log 2>&1 &
    CLOUDFLARED_CODE_PID=$!
fi

# 等待隧道建立
echo "等待隧道建立..."
sleep 10

# 获取 URL（仅临时隧道需要）
if [ -z "$CF_TUNNEL_TOKEN" ]; then
    # 获取 ttyd 公共 URL
    TTYD_URL=""
    for i in {1..10}; do
        if [ -f cloudflared-ttyd.log ]; then
            TTYD_URL=$(grep -o "https://[a-zA-Z0-9.-]*\.trycloudflare\.com" cloudflared-ttyd.log | head -1)
            if [ -n "$TTYD_URL" ]; then
                break
            fi
        fi
        sleep 2
    done

    # 获取 code-server 公共 URL
    CODE_URL=""
    for i in {1..10}; do
        if [ -f cloudflared-code.log ]; then
            CODE_URL=$(grep -o "https://[a-zA-Z0-9.-]*\.trycloudflare\.com" cloudflared-code.log | head -1)
            if [ -n "$CODE_URL" ]; then
                break
            fi
        fi
        sleep 2
    done
fi

# 显示访问信息
IP=$(hostname -I | awk '{print $1}')
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | grep -o '"HostName":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")

echo ""
echo "=================================================="
echo "安装完成！"
echo "=================================================="

# Tailscale 信息
if [ -n "$TAILSCALE_IP" ]; then
    echo "【Tailscale SSH】"
    echo "  IP: $TAILSCALE_IP"
    echo "  主机名: $TAILSCALE_HOSTNAME"
    echo "  连接命令: ssh $TAILSCALE_IP"
    echo ""
fi

if [ -n "$CF_TUNNEL_TOKEN" ]; then
    echo "【固定隧道模式】"
    echo "  请在 Cloudflare 控制台配置域名路由："
    echo "  ttyd.yourdomain.com   -> http://localhost:7681"
    echo "  code.yourdomain.com   -> http://localhost:8080"
    echo ""
    echo "【ttyd 终端】"
    echo "  本地访问: http://$IP:7681"
    echo ""
    echo "【code-server】"
    echo "  本地访问: http://$IP:8080"
else
    echo "【ttyd 终端】"
    echo "  本地访问: http://$IP:7681"
    if [ -n "$TTYD_URL" ]; then
        echo "  外网访问: $TTYD_URL"
    else
        echo "  外网访问: 正在生成... (查看: cat cloudflared-ttyd.log)"
    fi
    echo ""
    echo "【code-server】"
    echo "  本地访问: http://$IP:8080"
    if [ -n "$CODE_URL" ]; then
        echo "  外网访问: $CODE_URL"
    else
        echo "  外网访问: 正在生成... (查看: cat cloudflared-code.log)"
    fi
fi
echo "=================================================="

# 保存进程信息
echo $TTYD_PID > ttyd.pid
echo $CODE_PID > code-server.pid
if [ -n "$CF_TUNNEL_TOKEN" ]; then
    echo $CLOUDFLARED_PID > cloudflared.pid
else
    echo $CLOUDFLARED_TTYD_PID > cloudflared-ttyd.pid
    echo $CLOUDFLARED_CODE_PID > cloudflared-code.pid
fi