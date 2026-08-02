# Redis 规范化部署 (redis-deployment)

Redis 规范化部署的 GitOps 仓库。**当前生产方案：Kubernetes (K3s) 部署**，另有 Docker Compose 与 apt 两种备选。

## 当前架构 (2026-08)

```
GCP 伦敦 (europe-west2-c)                 OCI 新加坡 (ap-singapore-1)
+----------------------------+  Tailscale   +----------------------------------+
|  LiteLLM Proxy (实验 app)   | --直连 168ms-+> |  free-arm-vm (4C24G ARM)         |
|  . prompt 缓存 + 限流        |              |  K3s worker, hostNetwork Redis   |
|  . Redis 客户端              |              |  100.105.130.0:6379              |
+----------------------------+              +----------------------------------+
        |  A
        |  | 计费/评测数据 (已有通道)
        v  |
   OCI MySQL rin-heatwave (10.0.0.247:3306, 新加坡)
```

**数据路径**: LiteLLM -> Tailscale P2P 直连 -> 100.105.130.0:6379（free-arm-vm 节点 IP），**不过 KIC/Ingress**。Redis 用 `hostNetwork` 直接绑节点 6379 端口，无 NodePort 映射层。约 168ms 延迟对 prompt 缓存场景完全可接受（LLM 调用本身是秒级）。

**LiteLLM 侧启用 Redis 缓存配置** (config.yaml):

```yaml
cache: true
cache_params:
  type: redis
  host: 100.105.130.0
  port: 6379
  password: YOUR_STRONG_PASSWORD
```

连接参数: host `100.105.130.0`, port `6379`, 密码通过环境变量注入（勿写入明文配置文件）。

## Kubernetes (K3s) 部署 —— 当前方案

### Manifest: `k8s/redis.yaml`

```bash
# 1. 替换密码 (或从 secrets 管理注入)
kubectl create secret generic redis-secret \
  --from-literal=redis-password='YOUR_STRONG_PASSWORD' -n redis

# 2. 部署
kubectl apply -f k8s/redis.yaml

# 3. 确认调度到 free-arm-vm
kubectl -n redis get pods -o wide

# 4. 从集群外验证 (LiteLLM 所在机器或任意 Tailscale 节点)
redis-cli -h 100.105.130.0 -p 6379 -a YOUR_STRONG_PASSWORD ping   # 应返回 PONG
```

### K8s Manifest 要点

| 项目 | 配置 | 说明 |
|------|------|------|
| 网络 | `hostNetwork: true` | 直接绑节点 6379，外部经 Tailscale IP 直连，不过 KIC |
| 调度 | `nodeSelector: kubernetes.io/hostname=free-arm-vm` | 钉在 OCI ARM worker，避免跨架构/跨区域漂移 |
| 持久化 | `local-path` PVC (10Gi) | K3s 自带存储类，数据落 free-arm-vm 本地磁盘 |
| 高可用 | 单副本 + liveness/readiness 探针 | 实验场景；需要 HA 时改 StatefulSet + 多副本 + 主从 |
| 密码 | Secret 注入 | `CHANGE_ME` 占位符必须替换 |

## 备选: Docker Compose 方式

```bash
sudo bash docker-up.sh   # 自动生成 .env 随机密码, Redis + RedisInsight 一条命令全起
```
- 适用于**没有 K8s 的单机环境**（如裸机实验）
- 端口只绑 `127.0.0.1`，公网访问走 nginx 反代 + Basic Auth

## 备选: apt + systemd 方式

```bash
sudo bash install.sh     # apt 装 redis-server, 配置注入, 随机密码到 /etc/redis/.redispass
sudo bash scripts/healthcheck.sh
```
- 资源开销最低（无 Docker daemon），适合小内存机器
- RedisInsight: `sudo bash scripts/redisinsight.sh`

## 备份策略

- **K8s**: 数据在 `redis-data` PVC (local-path)，落于 `/var/lib/rancher/k3s/storage/`，备份:
  ```bash
  kubectl -n redis exec deploy/redis -- redis-cli -a $PASS --no-auth-warning BGSAVE
  # 然后 tar PVC 数据目录或按 local-path 卷备份
  ```
- **Compose/apt**: `scripts/backup.sh --remote gateman@100.115.214.26:/home/gateman/redis-backups`
- 远程备份目标: Moon 跳板机 `100.115.214.26`

## 安全须知

- Redis 默认仅绑定 Tailscale/内网可达地址，**不要**直接暴露公网 6379
- 需要公网访问时：nginx 反代 + Basic Auth -> RedisInsight (5540)，Redis 本身保持私网
- 密码一律通过 Secret/`.env` 管理，**绝不入库**
- K8s 集群内 `kubectl` 访问权限要收敛（Redis 密码在 Secret 中可见）

## 环境速查

| 组件 | 位置 | 地址 |
|------|------|------|
| LiteLLM Proxy | GCP 伦敦 europe-west2-c | Alice VM (Tailscale 100.94.13.17) |
| Redis | OCI 新加坡 ap-singapore-1 | free-arm-vm, `100.105.130.0:6379` |
| MySQL (计费) | OCI Singapore | rin-heatwave, `10.0.0.247:3306` |
| K3s 集群 | 腾讯云 + OCI + NUC | 3 节点 (vm-0-2-debian / free-arm-vm / nuc) |
| KIC (Kong) | 腾讯云 K3s | kong-system namespace (HTTP 网关, 与 Redis 无关) |
