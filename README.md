# Redis 规范化部署 (redis-deployment)

Redis 规范化部署的 GitOps 仓库。**当前生产方案：Kubernetes (K3s) 部署 + ArgoCD GitOps 自动发布**，另有 Docker Compose 与 apt 两种备选。

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

**数据路径**: LiteLLM -> Tailscale P2P 直连 -> `100.105.130.0:6379`（free-arm-vm 节点 IP），**不过 KIC/Ingress**。Redis 用 `hostNetwork` 直接绑节点 6379 端口，无 NodePort 映射层。约 168ms 延迟对 prompt 缓存场景完全可接受（LLM 调用本身是秒级）。

**设计原则**: 无状态应用（LiteLLM）在 GCP 伦敦（随时可回收）；有状态数据（Redis/MySQL）在 OCI 新加坡（Always Free 稳定区）。

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

### 两层职责分离 (Application vs Manifest)

- **ArgoCD Application** (`redis-app.yaml`) 只指定: 部署到哪个**集群** (`destination.name: tencent-dp1-cluster`) + 哪个 **namespace**
- **Deployment Manifest** (`k8s/redis.yaml`) 指定: Pod 落到哪个**节点** (`nodeSelector: free-arm-vm`) + 运行参数
- 节点调度是 K8s scheduler 的职责，ArgoCD 不干预

## ArgoCD GitOps 自动部署原理

### 完整链路

```
你 push redis-deployment.git (改 k8s/redis.yaml)
    ↓ (最多 3 分钟)
ArgoCD application-controller 轮询 redis-deployment.git
    ↓ 发现 path: k8s 目录有变更 (diff 非空)
自动 sync 到 tencent-dp1-cluster
    ↓
free-arm-vm 上的 Redis 更新 (拉新镜像/改配置/滚动)
```

### 触发机制: 谁发现新提交?

**ArgoCD 轮询的是每个 Application 自己的 `source.repoURL`**，不是统一仓库:

- `redis-app.yaml` 的 `source.repoURL: https://github.com/nvd11/redis-deployment.git` -> ArgoCD 轮询它
- `source.path: k8s` -> 只盯 k8s 子目录
- `source.targetRevision: HEAD` -> 跟踪分支最新提交 (任何 push 都会触发重新同步)

### 轮询间隔定义在哪?

| 组成部分 | 定义位置 | 可改性 |
|---------|---------|--------|
| 轮询哪个 repo | Application `spec.source.repoURL` | 改 Git 里的 app YAML |
| 轮询哪个目录 | Application `spec.source.path` | 改 Git 里的 app YAML |
| 跟踪哪个分支 | Application `spec.source.targetRevision` | 改 Git 里的 app YAML |
| **每 3 分钟一次** | ArgoCD 内置默认 (`--poll-interval=180s`) | ConfigMap 覆盖, 实验项目不用动 |
| 发现变化自动 sync | Application `spec.syncPolicy.automated` | 改 Git 里的 app YAML |

查证: 当前集群 `argocd-cmd-params-cm` 无自定义, controller 无 `--poll-interval` 参数, 用默认 180s。

### App-of-Apps 自动发现

- `root-bootstrap` Application 管理 `my-argocd-manifests.git` 的 `argocd-apps/` 目录
- 目录里**每个 .yaml 文件 = 一个子 Application**，root-bootstrap 自动发现
- 添加 `redis-app.yaml` 到该目录 -> root-bootstrap 3 分钟内捡起它 -> 创建 redis Application -> 该 Application 再去轮询 redis-deployment.git
- **不需要任何 UI/API 注册操作**，加文件 = 加应用，删文件 = prune 删应用
- 已验证: root-bootstrap 资源树里现有 5 个子 Application (fastapi-svc/gateway-api-crds/kong-gateway-infra/kong-ingress-controller/quarkus-svc)

### 什么变更会真正触发部署?

| 场景 | 行为 |
|------|------|
| push 新代码到 `k8s/` 资源变更 | 自动部署 (≤3 分钟) |
| 只改 README/文档 | 不触发部署 (diff 为空) |
| 手动改了集群里 Redis | selfHeal 自动纠偏回 Git 状态 |
| 删除 Manifest 里的资源 | prune 自动清理集群里对应资源 |

## GitHub Actions 的角色 (重要澄清)

**Redis 部署不需要 GitHub Actions。** 纯 GitOps: push 进 Git -> ArgoCD 轮询 -> 部署。

### 两类仓库的分工

| 仓库类型 | push 后发生什么 | 部署执行者 |
|---------|---------------|-----------|
| **自建应用仓库** (需构建镜像) | CI 构建 -> dispatch -> 更新 manifest -> ArgoCD 部署 | ArgoCD |
| **纯 Manifest 仓库** (redis-deployment) | 什么都不发生 (无 workflow) -> ArgoCD 轮询 -> 部署 | ArgoCD |
| **my-argocd-manifests** (App 定义) | 只有 dispatch 触发 workflow; 普通 push 靠 root-bootstrap 轮询 | ArgoCD |

### update-image-tag.yml 机制 (my-argocd-manifests)

- 触发方式: `repository_dispatch` (外部 API 远程唤醒), **不是 push**
- 调用方: 自建应用仓库的 CI (构建完镜像后 POST dispatch API)
- 作用: 用 sed 改 `argocd-apps/<svc>-app.yaml` 里的镜像 tag, commit + push
- 本质: 跨仓库的"打电话"机制 —— 应用 CI 构建完, 通知清单仓库"该更新 tag 了"
- 部署仍由 ArgoCD 完成, workflow 只负责把新 tag 写进 Git 清单
- 已验证: 8 次运行全部 repository_dispatch 触发, 无一例外
- **Redis 不需要它**: 固定官方镜像 (redis:7.2-alpine), 无自建镜像, 无 tag 更新需求

### dispatch 与 API 调用的区别

- `repository_dispatch` 是**事件语义** (仓库收到一个外部信号), 属于 GitHub Actions 事件家族 (push/pull_request/schedule/workflow_dispatch 平级)
- API 调用是**传输方式** (HTTP POST)
- workflow 通过 `types: [update-image-tag]` 精确订阅自己关心的事件类型

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
| ArgoCD | 阿里云 K3s | root-bootstrap (App-of-Apps), 管理 5+ 子应用 |
