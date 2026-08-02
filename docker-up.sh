#!/usr/bin/env bash
# ============================================================
# Docker Compose 方式部署 Redis + RedisInsight
# - 自动生成 .env (含随机密码)，无需手动编辑
# - docker compose up -d 一条命令起全部服务
#
# 用法: sudo bash docker-up.sh
# 访问: http://<tailscale-ip>:5540 (RedisInsight)
#       redis-cli -h 127.0.0.1 -a <密码在 .env>
# ============================================================
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

echo "==> 1/4 检查 Docker"
if ! command -v docker >/dev/null; then
  echo "   ⚠️ 未安装 Docker，正在安装..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi
docker compose version >/dev/null 2>&1 || { echo "❌ docker compose 插件不可用，请安装"; exit 1; }

echo "==> 2/4 准备 .env"
if [[ ! -f .env ]]; then
  PASS="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)"
  cat > .env <<EOF
REDIS_PASSWORD=${PASS}
EOF
  chmod 600 .env
  echo "   已生成 .env (密码随机生成，权限 600)"
else
  echo "   复用已有 .env"
fi

echo "==> 3/4 启动服务"
docker compose up -d --wait --wait-timeout 60 || docker compose up -d

echo "==> 4/4 验证"
sleep 2
PASS="$(grep REDIS_PASSWORD .env | cut -d= -f2)"
if docker exec redis redis-cli -a "$PASS" --no-auth-warning ping | grep -q PONG; then
  echo "✅ Redis 运行中: 127.0.0.1:6379 (密码见 .env)"
  echo "✅ RedisInsight: http://127.0.0.1:5540 (SSH 隧道/Tailscale 访问)"
  echo "   在 UI 中添加连接: host=redis, port=6379, password=见 .env"
else
  echo "❌ 验证失败: docker compose logs redis"
  exit 1
fi
