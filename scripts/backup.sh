#!/usr/bin/env bash
# ============================================================
# Redis 数据备份脚本
# - 本地 tar 打包 /var/lib/redis
# - 保留最近 N 份
# - 可选: scp 推送到远程备份节点
#
# 用法:
#   bash backup.sh [--remote user@host:/path] [--keep 7]
# 建议 crontab:
#   0 2 * * * /opt/redis-deployment/scripts/backup.sh --remote gateman@100.115.214.26:/home/gateman/redis-backups
# ============================================================
set -euo pipefail

DATA_DIR="/var/lib/redis"
BACKUP_DIR="/backup"
KEEP=7
REMOTE=""
STAMP="$(date +%F-%H%M%S)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) REMOTE="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

[[ $EUID -ne 0 ]] && { echo "❌ 请用 sudo 运行"; exit 1; }
mkdir -p "$BACKUP_DIR"

echo "==> 1/3 备份 $DATA_DIR"
# 用 redis-cli 先触发一次 BGSAVE 保证 RDB 是最新的
if command -v redis-cli >/dev/null; then
  PASS=""
  [[ -f /etc/redis/.redispass ]] && PASS="$(cat /etc/redis/.redispass)"
  redis-cli -a "$PASS" --no-auth-warning BGSAVE >/dev/null 2>&1 || true
  sleep 1
fi

ARCHIVE="$BACKUP_DIR/redis-$STAMP.tar.gz"
tar czf "$ARCHIVE" -C / "$(basename "$DATA_DIR")" 2>/dev/null || tar czf "$ARCHIVE" "$DATA_DIR"
echo "   ✅ $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

echo "==> 2/3 清理旧备份 (保留 $KEEP 份)"
ls -1t "$BACKUP_DIR"/redis-*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
echo "   剩余备份: $(ls -1 "$BACKUP_DIR"/redis-*.tar.gz 2>/dev/null | wc -l) 份"

echo "==> 3/3 远程推送"
if [[ -n "$REMOTE" ]]; then
  scp "$ARCHIVE" "$REMOTE" && echo "   ✅ 已推送至 $REMOTE"
else
  echo "   (未指定 --remote，跳过)"
fi

echo "🎉 备份完成"
