#!/bin/bash

# 确保以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 用户运行此脚本"
    exec sudo -E bash "$0" "$@"
fi

echo "[start-loop.sh] 启动开始"
echo "[start-loop.sh] 当前目录: $(pwd)"
echo "[start-loop.sh] 当前用户: $(id -un) (uid=$(id -u))"

echo "0=$0"
echo "PID=$$ PPID=$PPID"
echo "SHELL环境变量=$SHELL"
ps -p $$ -o pid=,ppid=,comm=,args=

. /root/.bashrc
. /root/.profile

# ========== 耗时统计函数 ==========
SCRIPT_START_TIME=$(date +%s)

# 记录步骤开始时间
step_start() {
    STEP_START_TIME=$(date +%s)
}

# 打印步骤耗时
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

# 打印总耗时
total_time() {
    local total_end_time=$(date +%s)
    local duration=$((total_end_time - SCRIPT_START_TIME))
    local mins=$((duration / 60))
    local secs=$((duration % 60))
    echo "══════════════════════════════════════════════════"
    echo "📋 总耗时: ${mins}分${secs}秒"
    echo "══════════════════════════════════════════════════"
}

# 确保脚本退出时打印总耗时
trap total_time EXIT
# ====================================

# 添加 snap 路径到 PATH
export PATH="/snap/bin:$PATH"

# ========== ttyd Basic Auth (写死) ==========
TTYD_USER="admin"
TTYD_PASS="zc123456"
# ==========================================

# 设置系统主机名
step_start
if [ -n "$HOSTNAME" ]; then
    echo "设置主机名: $HOSTNAME"
    sudo hostnamectl set-hostname "$HOSTNAME"
    # 更新 /etc/hosts
    sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$HOSTNAME/" /etc/hosts 2>/dev/null || true
    echo "✓ 主机名已设置为: $(hostname)"
fi
step_end "设置主机名"

# 确保 ~/.local/bin 在 PATH 中
export PATH="$HOME/.local/bin:$PATH"

echo "正在安装 ttyd、Cloudflared、Tailscale..."

# 安装 ttyd（snap 依赖）
step_start
echo ">>> [1/3] 安装 ttyd (apt update + snapd + tmux + ttyd)"
sudo apt update -y
sudo apt install snapd tmux -y
sudo snap install ttyd --classic
step_end "安装 ttyd"

# 验证 ttyd 是否可用
if ! command -v ttyd &> /dev/null; then
    # 尝试使用完整路径
    if [ -x /snap/bin/ttyd ]; then
        TTYD_CMD="/snap/bin/ttyd"
        echo "✓ ttyd 已安装: $TTYD_CMD"
    else
        echo "✗ ttyd 安装失败"
    fi
else
    TTYD_CMD="ttyd"
    echo "✓ ttyd 已安装"
fi

# 并行安装 Tailscale 和 Cloudflared
step_start
echo ">>> [2/3] 并行安装 Tailscale 和 Cloudflared..."

# 后台安装 Tailscale
(
  if ! command -v tailscale &> /dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "done" > /tmp/ts-install.done
  else
    echo "done" > /tmp/ts-install.done
  fi
) &
TS_PID=$!

# 后台安装 Cloudflared
(
  if ! command -v cloudflared &> /dev/null; then
    ARCH=$(uname -m)
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
      wget -q https://github.com/cloudflare/cloudflared/releases/download/2025.10.1/cloudflared-linux-arm64 -O /tmp/cloudflared
    else
      wget -q https://github.com/cloudflare/cloudflared/releases/download/2025.10.1/cloudflared-linux-amd64 -O /tmp/cloudflared
    fi
    chmod +x /tmp/cloudflared
    sudo mv /tmp/cloudflared /usr/local/bin/
    echo "done" > /tmp/cf-install.done
  else
    echo "done" > /tmp/cf-install.done
  fi
) &
CF_PID=$!

# 等待两个安装完成
wait $TS_PID $CF_PID
step_end "并行安装 Tailscale/Cloudflared"

# 检查安装结果
echo "检查安装结果..."
if command -v tailscale &> /dev/null; then
    echo "✓ Tailscale 安装成功"
else
    echo "⚠ Tailscale 安装失败"
fi

if command -v cloudflared &> /dev/null; then
    echo "✓ Cloudflared 安装成功"
else
    echo "⚠ Cloudflared 安装失败"
fi

echo "✓ 所有安装完成"

# 停止可能存在的进程
pkill -f ttyd 2>/dev/null || true
pkill -f cloudflared 2>/dev/null || true

# 连接 Tailscale（手动登录）
step_start
echo ">>> 启动 Tailscale"
if ! command -v tailscale &> /dev/null; then
    echo "⚠ Tailscale 未安装，跳过"
else
    echo "正在启动 Tailscale..."

    # 彻底清理 tailscaled 相关进程和资源
    sudo systemctl stop tailscaled 2>/dev/null || true
    sudo pkill -9 -x tailscaled 2>/dev/null || true
    sudo ip link delete tailscale0 2>/dev/null || true
    sudo rm -f /var/run/tailscale/tailscaled.sock 2>/dev/null || true
    sleep 2

    # 使用 systemd 启动（如果可用）
    if sudo systemctl start tailscaled 2>/dev/null; then
        echo "✓ 使用 systemd 启动 tailscaled"
    else
        # 回退到手动启动
        echo "手动启动 tailscaled..."
        sudo tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock 2>/tmp/tailscaled.log &
    fi

    # 等待 socket 就绪（最多 10 秒）
    for i in $(seq 1 10); do
      if [ -S /var/run/tailscale/tailscaled.sock ]; then
        echo "✓ tailscaled socket 就绪"
        break
      fi
      sleep 1
    done

    # 检查 tailscaled 是否运行
    if ! pgrep -x tailscaled > /dev/null; then
        echo "✗ tailscaled 启动失败"
        cat /tmp/tailscaled.log 2>/dev/null || true
    fi

    # 检查是否已连接
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
    if [ -n "$TAILSCALE_IP" ]; then
        TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | grep -o '"HostName":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
        echo "✓ Tailscale 已连接"
        echo "  IP: $TAILSCALE_IP"
        echo "  主机名: $TAILSCALE_HOSTNAME"
        echo "  SSH: ssh $TAILSCALE_IP 或 ssh $TAILSCALE_HOSTNAME"
    else
        # 后台运行 tailscale up，监控链接并打印
        echo "⏳ Tailscale 正在后台获取登录链接..."
        (
            sudo tailscale up --ssh 2>&1 | tee /tmp/tailscale-up.log &
            TAILSCALE_PID=$!
            
            # 监控日志文件，有链接就打印
            for i in $(seq 1 30); do
                if [ -f /tmp/tailscale-up.log ]; then
                    LOGIN_URL=$(grep -oE 'https://login\.tailscale\.com/[a-zA-Z0-9]+' /tmp/tailscale-up.log 2>/dev/null | head -1)
                    if [ -z "$LOGIN_URL" ]; then
                        LOGIN_URL=$(grep -oE 'https://tailscale\.com/login/[a-zA-Z0-9]+' /tmp/tailscale-up.log 2>/dev/null | head -1)
                    fi
                    if [ -n "$LOGIN_URL" ]; then
                        echo ""
                        echo "============================================="
                        echo "🔗 Tailscale 登录链接："
                        echo "   $LOGIN_URL"
                        echo "============================================="
                        break
                    fi
                fi
                sleep 1
            done
            
            # 等待登录完成
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
        ) &
    fi
fi
step_end "启动 Tailscale"

# 启动 ttyd（关键：-W 允许写入，直接运行 bash；-c 开启 Basic Auth）
step_start
echo ">>> 启动 ttyd"
if [ -z "$TTYD_CMD" ]; then
    echo "✗ ttyd 未安装，跳过"
    exit 1
fi
$TTYD_CMD -p 7681 -W -c "$TTYD_USER:$TTYD_PASS" bash &
TTYD_PID=$!

# 等待端口就绪（最多 5 秒）
for i in $(seq 1 5); do
  if netstat -tuln | grep -q ":7681"; then
    echo "✓ ttyd 端口就绪"
    break
  fi
  sleep 1
done

# 检查 ttyd 是否运行
if ps -p $TTYD_PID > /dev/null; then
    echo "✓ ttyd 启动成功 (PID: $TTYD_PID)"
else
    echo "✗ ttyd 启动失败，尝试重新启动..."
    $TTYD_CMD -p 7681 -W -c "$TTYD_USER:$TTYD_PASS" bash &
    TTYD_PID=$!
fi

# 检查端口
if netstat -tuln | grep -q ":7681"; then
    echo "✓ ttyd 正在监听端口 7681"
else
    echo "✗ ttyd 未监听端口 7681"
    exit 1
fi
step_end "启动 ttyd"

# 启动 Cloudflared 隧道
step_start
echo ">>> 启动 Cloudflared 隧道"
if [ -n "$CF_TUNNEL_TOKEN" ]; then
    echo "使用 Cloudflare 固定隧道..."
    nohup cloudflared tunnel run --token "$CF_TUNNEL_TOKEN" > cloudflared.log 2>&1 &
    CLOUDFLARED_PID=$!

    # 等待进程启动（最多 5 秒）
    for i in $(seq 1 5); do
      if ps -p $CLOUDFLARED_PID > /dev/null; then
        echo "✓ 固定隧道进程启动 (PID: $CLOUDFLARED_PID)"
        break
      fi
      sleep 1
    done

    if ! ps -p $CLOUDFLARED_PID > /dev/null; then
        echo "✗ 固定隧道启动失败，请检查 Token"
        cat cloudflared.log
    fi
    echo $CLOUDFLARED_PID > cloudflared.pid
else
    # 使用临时隧道（每次 URL 会变）
    echo "使用 Cloudflare 临时隧道..."
    nohup cloudflared tunnel --url http://localhost:7681 > cloudflared-ttyd.log 2>&1 &
    CLOUDFLARED_TTYD_PID=$!
fi
step_end "启动 Cloudflared 隧道"

# 获取 URL（仅临时隧道需要）
if [ -z "$CF_TUNNEL_TOKEN" ]; then
    # 获取 ttyd 公共 URL（最多等待 20 秒）
    TTYD_URL=""
    for i in $(seq 1 20); do
        if [ -f cloudflared-ttyd.log ]; then
            TTYD_URL=$(grep -o "https://[a-zA-Z0-9.-]*\.trycloudflare\.com" cloudflared-ttyd.log | head -1)
            if [ -n "$TTYD_URL" ]; then
                echo "✓ 隧道 URL 已生成"
                break
            fi
        fi
        sleep 1
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
    echo ""
    echo "【ttyd 终端】"
    echo "  本地访问: http://$IP:7681"
else
    echo "【ttyd 终端】"
    echo "  本地访问: http://$IP:7681"
    if [ -n "$TTYD_URL" ]; then
        echo "  外网访问: $TTYD_URL"
    else
        echo "  外网访问: 正在生成... (查看: cat cloudflared-ttyd.log)"
    fi
fi
echo "=================================================="

# 保存进程信息
echo $TTYD_PID > ttyd.pid
if [ -n "$CF_TUNNEL_TOKEN" ]; then
    echo $CLOUDFLARED_PID > cloudflared.pid
else
    echo $CLOUDFLARED_TTYD_PID > cloudflared-ttyd.pid
fi

# 可选：执行自定义启动脚本
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
fi
step_end "自定义启动脚本"
