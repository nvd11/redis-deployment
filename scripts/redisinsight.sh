#!/usr/bin/env bash
# ============================================================
# RedisInsight 部署脚本 (Web UI 浏览缓存数据)
# - Docker 部署，数据卷持久化
# - 默认只绑 Tailscale/内网 (走 host 网络 5540 端口)
#
# 用法:
#   sudo bash redisinsight.sh [--port 5540]
#   访问: http://<tailscale-ip>:5540
# ============================================================
set -euo pipefail

PORT=5540

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

echo "==> 1/3 检查 Docker"
if ! command -v docker >/dev/null; then
  echo "   ⚠️ 未安装 Docker，正在安装..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

echo "==> 2/3 启动 RedisInsight 容器"
docker rm -f redisinsight >/dev/null 2>&1 || true
docker run -d --name redisinsight \
  --restart unless-stopped \
  -p "$PORT":5540 \
  -v redisinsight:/data \
  redis/redisinsight:latest

echo "==> 3/3 验证"
sleep 3
if docker ps --format '{{.Names}} {{.Status}}' | grep -q redisinsight; then
  echo "✅ RedisInsight 运行中: http://<本机IP>:$PORT"
  echo "   在 UI 中添加 Redis 连接: host=127.0.0.1, port=6379, password=见 /etc/redis/.redispass"
else
  echo "❌ 启动失败: docker logs redisinsight"
  exit 1
fi
