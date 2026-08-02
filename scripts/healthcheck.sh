#!/usr/bin/env bash
# ============================================================
# Redis 健康检查脚本
# - ping 检查 + 内存/连接数/持久化状态摘要
# 用法: bash healthcheck.sh
# ============================================================
set -euo pipefail

PASS=""
[[ -f /etc/redis/.redispass ]] && PASS="$(cat /etc/redis/.redispass)"
CLI=(redis-cli -a "$PASS" --no-auth-warning)

if ! "${CLI[@]}" ping 2>/dev/null | grep -q PONG; then
  echo "❌ Redis DOWN"
  exit 1
fi

echo "✅ Redis UP"
echo "  版本:   $("${CLI[@]}" info server | grep redis_version | cut -d: -f2 | tr -d '\r')"
echo "  内存:   $("${CLI[@]}" info memory | grep used_memory_human | cut -d: -f2 | tr -d '\r') / $("${CLI[@]}" info memory | grep maxmemory_human | cut -d: -f2 | tr -d '\r')"
echo "  连接数: $("${CLI[@]}" info clients | grep connected_clients | cut -d: -f2 | tr -d '\r')"
echo "  键数量: $("${CLI[@]}" dbsize)"
echo "  AOF:    $("${CLI[@]}" info persistence | grep aof_enabled | cut -d: -f2 | tr -d '\r')"
echo "  角色:   $("${CLI[@]}" info replication | grep role | cut -d: -f2 | tr -d '\r')"
