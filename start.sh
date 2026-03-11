#!/bin/bash

echo "[start.sh] 启动开始"
echo "[start.sh] 当前目录: $(pwd)"
echo "[start.sh] 当前用户: $(id -un) (uid=$(id -u))"

echo "正在安装 ttyd、code-server 和 Cloudflared..."

# 安装 ttyd
sudo apt update -y
sudo apt install snapd tmux -y
sudo snap install ttyd --classic

# 安装 opencode
curl -fsSL https://opencode.ai/install | bash
bash -c "$(curl -fsSL https://gitee.com/iflow-ai/iflow-cli/raw/main/install.sh)"

# 安装 code-server
curl -fsSL https://code-server.dev/install.sh | sh

# 安装 Cloudflared
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    wget -q https://github.com/cloudflare/cloudflared/releases/download/2025.10.1/cloudflared-linux-arm64 -O cloudflared
else
    wget -q https://github.com/cloudflare/cloudflared/releases/download/2025.10.1/cloudflared-linux-amd64 -O cloudflared
fi
chmod +x cloudflared
sudo mv cloudflared /usr/local/bin/

# 停止可能存在的进程
pkill -f ttyd 2>/dev/null || true
pkill -f cloudflared 2>/dev/null || true
pkill -f code-server 2>/dev/null || true

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

# 启动 Cloudflared 隧道 (ttyd)
echo "启动 Cloudflared 隧道 (ttyd)..."
nohup cloudflared tunnel --url http://localhost:7681 > cloudflared-ttyd.log 2>&1 &
CLOUDFLARED_TTYD_PID=$!

# 启动 Cloudflared 隧道 (code-server)
echo "启动 Cloudflared 隧道 (code-server)..."
nohup cloudflared tunnel --url http://localhost:8080 > cloudflared-code.log 2>&1 &
CLOUDFLARED_CODE_PID=$!

# 等待隧道建立
echo "等待隧道建立..."
sleep 10

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

# 显示访问信息
IP=$(hostname -I | awk '{print $1}')
echo ""
echo "=================================================="
echo "安装完成！"
echo "=================================================="
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
echo "=================================================="

# 保存进程信息
echo $TTYD_PID > ttyd.pid
echo $CODE_PID > code-server.pid
echo $CLOUDFLARED_TTYD_PID > cloudflared-ttyd.pid
echo $CLOUDFLARED_CODE_PID > cloudflared-code.pid