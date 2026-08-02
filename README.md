# Redis 规范化部署 (redis-deployment)

Redis 单机规范化部署的 GitOps 仓库：一键安装、混合持久化、安全加固、自动备份、Web UI。

## 📦 仓库结构

```
redis-deployment/
├── install.sh                 # 一键安装脚本 (Debian/Ubuntu)
├── config/
│   └── redis.conf             # 规范化配置模板 (RDB+AOF 混合持久化, 密码认证)
└── scripts/
    ├── backup.sh              # 本地打包 + 可选远程推送备份
    ├── redisinsight.sh        # RedisInsight Web UI (Docker)
    └── healthcheck.sh         # 健康检查 (ping/内存/连接数/持久化)
```

## 🚀 快速开始

```bash
# 1. 克隆仓库到目标机器 (如 OCI Heavy Node 134.185.90.98)
git clone https://github.com/nvd11/redis-deployment.git
cd redis-deployment

# 2. 一键安装 (自动生成随机密码，写入 /etc/redis/.redispass)
sudo bash install.sh

# 3. 健康检查
sudo bash scripts/healthcheck.sh

# 4. 可选: 部署 RedisInsight Web UI
sudo bash scripts/redisinsight.sh
# 访问: http://<tailscale-ip>:5540

# 5. 可选: 配置每日备份 + 推送远程节点
# crontab -e
0 2 * * * /opt/redis-deployment/scripts/backup.sh --remote gateman@100.115.214.26:/home/gateman/redis-backups
```

## ⚙️ 配置要点

| 项目 | 配置 | 说明 |
|------|------|------|
| 持久化 | `appendonly yes` + `aof-use-rdb-preamble yes` | RDB 快照 + AOF 增量混合模式，最多丢 1 秒数据 |
| 安全 | `requirepass` (随机生成) | 密码文件 `/etc/redis/.redispass` (权限 600) |
| 网络 | `bind 127.0.0.1` + `protected-mode yes` | 默认仅本地访问，公网访问必须经 nginx 反代 + 认证 |
| 内存 | `maxmemory-policy noeviction` | 实验环境不限制内存；生产建议设置 `maxmemory` + `allkeys-lru` |

## 🔐 安全须知

- Redis 默认仅绑定本地 (127.0.0.1)，**不要**直接暴露公网 6379 端口
- 需要公网访问时：nginx 反代 + Basic Auth → RedisInsight (5540)，Redis 本身保持本地
- 密码勿提交到 Git，使用环境变量或 secrets 管理

## 📌 备份策略

- 本地: `/backup/redis-<日期>.tar.gz`，保留最近 7 份 (`--keep`)
- 远程: 推送至 Moon 跳板机 `100.115.214.26:/home/gateman/redis-backups/`
- 还原: 解压 tar.gz 至 `/var/lib/redis` 后 `systemctl restart redis-server`

## 🧪 实验环境

推荐部署节点: **OCI Heavy Node** `134.185.90.98` (4C24G ARM, Always Free)
共享入口 nginx 规划中。
