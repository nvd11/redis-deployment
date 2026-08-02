# Redis 规范化部署 (redis-deployment)

Redis 单机规范化部署的 GitOps 仓库。提供 **两种部署方式**：
- 🐳 **Docker Compose（推荐）**：声明式、可复现、Redis + RedisInsight 一条命令全起
- 📦 **apt + systemd（备选）**：传统方式，资源开销最低

## 📦 仓库结构

```
redis-deployment/
├── docker-compose.yml         # [推荐] Redis + RedisInsight 编排
├── docker-up.sh               # [推荐] 一键 Compose 部署 (自动生成密码)
├── install.sh                 # apt 方式安装脚本
├── config/redis.conf          # apt 方式配置模板 (混合持久化, 密码认证)
├── .env.example               # Compose 密码模板 (不入库)
└── scripts/
    ├── backup.sh              # 本地打包 + 可选远程推送备份
    ├── redisinsight.sh        # (apt 方式) RedisInsight Web UI
    └── healthcheck.sh         # (apt 方式) 健康检查
```

## 🚀 快速开始 (Docker Compose 方式)

```bash
# 1. 克隆仓库到目标机器 (如 OCI Heavy Node 134.185.90.98)
git clone https://github.com/nvd11/redis-deployment.git
cd redis-deployment

# 2. 一键部署 (自动生成随机密码到 .env，权限 600)
sudo bash docker-up.sh

# 3. 访问 RedisInsight: http://<tailscale-ip>:5540
#    UI 中添加连接: host=redis, port=6379, password=见 .env
```

### Compose 细节
- `redis` 容器: `redis:7.2-alpine`，AOF 混合持久化挂载 `redis-data` 卷
- `redisinsight` 容器: 官方镜像，数据卷 `redisinsight-data`
- **端口只绑 127.0.0.1**，公网访问必须走 nginx 反代 + 认证
- 密码通过 `.env` 注入 (`REDIS_PASSWORD`)，`.env` 已在 `.gitignore` 中

## 🚀 快速开始 (apt 方式)

```bash
# 1. 克隆仓库
git clone https://github.com/nvd11/redis-deployment.git
cd redis-deployment

# 2. 一键安装 (自动生成随机密码，写入 /etc/redis/.redispass)
sudo bash install.sh

# 3. 健康检查
sudo bash scripts/healthcheck.sh

# 4. 可选: 部署 RedisInsight Web UI
sudo bash scripts/redisinsight.sh

# 5. 可选: 配置每日备份 + 推送远程节点
# crontab -e
0 2 * * * /opt/redis-deployment/scripts/backup.sh --remote gateman@100.115.214.26:/home/gateman/redis-backups
```

## ⚙️ 配置要点

| 项目 | 配置 | 说明 |
|------|------|------|
| 持久化 | `appendonly yes` + `aof-use-rdb-preamble yes` | RDB 快照 + AOF 增量混合模式，最多丢 1 秒数据 |
| 安全 | `requirepass` (随机生成) | Compose: `.env` 注入；apt: `/etc/redis/.redispass` (600) |
| 网络 | `bind 127.0.0.1` + `protected-mode yes` | 默认仅本地访问，公网访问必须经 nginx 反代 + 认证 |
| 内存 | `maxmemory-policy noeviction` | 实验环境不限制内存；生产建议设置 `maxmemory` + `allkeys-lru` |

## 🔐 安全须知

- Redis 默认仅绑定本地 (127.0.0.1)，**不要**直接暴露公网 6379 端口
- 需要公网访问时：nginx 反代 + Basic Auth → RedisInsight (5540)，Redis 本身保持本地
- 密码勿提交到 Git，使用 `.env` (Compose) 或 `/etc/redis/.redispass` (apt)

## 📌 备份策略

- Compose: Redis 数据在 `redis-data` 卷 (`docker volume`)，备份方式:
  ```bash
  docker run --rm -v redis-deployment_redis-data:/data -v /backup:/backup alpine \
    tar czf /backup/redis-$(date +%F).tar.gz -C /data .
  ```
- apt: `/backup/redis-<日期>.tar.gz`，保留最近 7 份 (`--keep`)
- 远程: 推送至 Moon 跳板机 `100.115.214.26:/home/gateman/redis-backups/`
- 还原: 解压至数据目录后重启容器/服务

## 🧪 实验环境

推荐部署节点: **OCI Heavy Node** `134.185.90.98` (4C24G ARM, Always Free)
共享入口 nginx 规划中。
