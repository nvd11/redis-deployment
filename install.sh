#!/usr/bin/env bash
# ============================================================
# Redis 规范化安装脚本 (Debian/Ubuntu)
# - 安装 redis-server
# - 应用规范化配置 (持久化 + 安全)
# - 启动并验证
#
# 用法:
#   sudo bash install.sh [--port 6379] [--password <pwd>]
#   不带 --password 时自动生成随机密码并写入 /etc/redis/.redispass
# ============================================================
set -euo pipefail

PORT=6379
PASSWORD=""
CONF_SRC="$(dirname "$(readlink -f "$0")")/config/redis.conf"
REDIS_CONF="/etc/redis/redis.conf"
PASS_FILE="/etc/redis/.redispass"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "❌ 请用 sudo 运行"
  exit 1
fi

echo "==> 1/5 安装 redis-server"
apt-get update -qq
apt-get install -y -qq redis-server

echo "==> 2/5 生成/校验密码"
if [[ -z "$PASSWORD" ]]; then
  if [[ -f "$PASS_FILE" ]]; then
    PASSWORD="$(cat "$PASS_FILE")"
    echo "   复用已有密码: $PASS_FILE"
  else
    PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)"
    echo "$PASSWORD" > "$PASS_FILE"
    chmod 600 "$PASS_FILE"
    echo "   已生成随机密码 -> $PASS_FILE"
  fi
else
  echo "$PASSWORD" > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
  echo "   使用指定密码"
fi

echo "==> 3/5 应用规范化配置"
if [[ -f "$CONF_SRC" ]]; then
  cp "$CONF_SRC" "$REDIS_CONF"
  sed -i "s/^port .*/port $PORT/" "$REDIS_CONF"
  sed -i "s/^# requirepass .*/requirepass $PASSWORD/" "$REDIS_CONF"
  sed -i "s/^requirepass .*/requirepass $PASSWORD/" "$REDIS_CONF"
  echo "   已应用 $CONF_SRC (port=$PORT)"
else
  echo "   ⚠️ 未找到 $CONF_SRC，跳过配置（仅安装）"
fi

echo "==> 4/5 启动服务"
systemctl enable redis-server >/dev/null 2>&1 || true
systemctl restart redis-server

echo "==> 5/5 验证"
sleep 1
if redis-cli -a "$PASSWORD" --no-auth-warning ping | grep -q PONG; then
  echo "✅ Redis 运行正常 (127.0.0.1:$PORT)"
  echo "   密码文件: $PASS_FILE"
  echo "   查看: redis-cli -a <密码> --no-auth-warning ping"
else
  echo "❌ Redis 启动验证失败，请查看: journalctl -u redis-server -n 50"
  exit 1
fi
