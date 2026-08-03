# Redis 规范化部署 (redis-deployment)

Redis 规范化部署的 GitOps 仓库。**当前生产方案：ArgoCD 自动部署到 OCI free-arm-vm（K3s 集群），客户端经 Kong Gateway L4 Stream 连接**，另有 Docker Compose 与 apt 两种备选。

## 当前架构 (2026-08)

```
GCP 伦敦 (europe-west2-c)                 OCI 新加坡 (ap-singapore-1)
+----------------------------+  Tailscale   +----------------------------------+
|  LiteLLM Proxy (实验 app)   | --直连 168ms-+> |  free-arm-vm (4C24G ARM)         |
|  . prompt 缓存 + 限流        |              |  K3s worker                      |
|  . Redis 客户端              |              |  Redis Pod (10.43.x.x:6379)     |
+----------------------------+              |  ClusterIP Service (redis:6379)   |
        |  A                                 +--------------+-------------------+
        |  | 计费/评测数据 (已有通道)                         |
        v  |                                       Kong Gateway (DaemonSet)
   OCI MySQL rin-heatwave (10.0.0.247:3306, 新加坡)     3 节点 L4 Stream:6379
                                              ^                        |
                                              | TCPIngress (redis-tcp)  |
                                              +------------------------+
                                             客户端 -> Kong :6379 -> Redis Service
```

**数据路径 (LiteLLM -> Redis)**：`LiteLLM -> Tailscale -> Kong Gateway :6379 (L4 Stream 透传) -> TCPIngress 路由 -> Redis ClusterIP Service -> Redis Pod (free-arm-vm)`。

- Kong 以 DaemonSet 运行在每个节点，`proxy.stream` 已开启 6379 端口 L4 透传，客户端连任意节点 `:6379` 均可达
- Redis 通过 `TCPIngress` (Kong CRD) 暴露，不直接绑定节点端口，网络路径统一收口到网关层（后续可加认证/审计/限流）
- 约 168ms 延迟对 prompt 缓存场景完全可接受（LLM 调用本身是秒级）

**设计原则**: 无状态应用（LiteLLM）在 GCP 伦敦（随时可回收）；有状态数据（Redis/MySQL）在 OCI 新加坡（Always Free 稳定区）。

## 部署方案：ArgoCD GitOps

### 组件清单

| 组件 | 位置 | 说明 |
|------|------|------|
| Redis Manifest | 本仓库 `k8s/redis.yaml` | Deployment + PVC + Service，nodeSelector 钉 free-arm-vm |
| ArgoCD Application | `my-argocd-manifests/argocd-apps/redis-app.yaml` | 指向本仓库 `k8s/` 目录，目标集群 tencent-dp1-cluster |
| Kong TCPIngress | `my-argocd-manifests/` 或本仓库 | 把 Kong 6379 Stream 转发到 Redis Service |

### 部署流程（三步）

```bash
# 1. 确保 Kong 已开启 6379 Stream (kong-controller-app.yaml 已配置 proxy.stream)
#    确认: kubectl -n kong-system get svc kong-ingress-controller-kong-proxy
#          6379:30745/TCP 已监听

# 2. 在 my-argocd-manifests/argocd-apps/ 添加 redis-app.yaml:
#    apiVersion: argoproj.io/v1alpha1
#    kind: Application
#    metadata:
#      name: redis
#      namespace: argocd
#      annotations:
#        argocd.argoproj.io/sync-wave: "3"   # 在 Kong 之后
#    spec:
#      project: default
#      source:
#        repoURL: 'https://github.com/nvd11/redis-deployment.git'
#        path: k8s
#        targetRevision: HEAD
#      destination:
#        name: 'tencent-dp1-cluster'
#        namespace: redis
#      syncPolicy:
#        automated:
#          prune: true
#          selfHeal: true
#        syncOptions:
#          - CreateNamespace=true

# 3. 配置 Redis 密码 Secret (先于 ArgoCD 同步，或首次同步后手动创建)
kubectl create secret generic redis-secret \
  --from-literal=redis-password='YOUR_STRONG_PASSWORD' -n redis

# 推送后 ArgoCD 自动同步 (≤3 分钟)，确认:
kubectl -n redis get pods -o wide    # redis pod 应调度到 free-arm-vm
kubectl -n redis get svc             # redis ClusterIP Service
```

### 连接验证 (LiteLLM 侧)

```bash
# 方式 1: 走 Kong Gateway (推荐, 生产路径)
redis-cli -h <任意节点 Tailscale IP> -p 6379 -a YOUR_STRONG_PASSWORD ping   # PONG
# 例如: redis-cli -h 100.105.130.0 -p 6379 -a ... ping   (free-arm-vm)
#        redis-cli -h 100.77.64.95 -p 6379 -a ... ping    (腾讯云节点, 同样可达)

# 方式 2: 集群内直连 (Kong 未就绪时临时用)
kubectl -n redis exec deploy/redis -- redis-cli -a $PASS --no-auth-warning ping
```

**LiteLLM 侧配置** (config.yaml):

```yaml
cache: true
cache_params:
  type: redis
  host: <Kong 节点 Tailscale IP>   # 如 100.105.130.0 (free-arm-vm)
  port: 6379
  password: YOUR_STRONG_PASSWORD
```

## 为什么走 Kong Gateway 而不是 hostNetwork 直连

| 对比项 | hostNetwork 直连 (旧方案) | Kong Gateway L4 Stream (当前方案) |
|--------|--------------------------|----------------------------------|
| 端口暴露 | Redis 直绑节点 6379 | 统一由 Kong 管理，Redis 只暴露 ClusterIP |
| 安全 | Redis 裸奔节点端口 | 网关层统一收口，可加认证/审计 |
| 高可用 | 单节点，挂了就断 | 3 节点 Kong DaemonSet 都能转发 |
| 运维 | 每台机器单独管理 | GitOps 声明式，改代码即生效 |

## Kubernetes (K3s) 部署细节

### Manifest: `k8s/redis.yaml`

```bash
# 手动方式 (不依赖 ArgoCD 时)
kubectl apply -f k8s/redis.yaml

# 确认调度到 free-arm-vm
kubectl -n redis get pods -o wide
```

### K8s Manifest 要点

| 项目 | 配置 | 说明 |
|------|------|------|
| 调度 | `nodeSelector: kubernetes.io/hostname=free-arm-vm` | 钉在 OCI ARM worker，避免跨架构/跨区域漂移 |
| 网络 | ClusterIP Service (6379) | 不再用 hostNetwork，统一经 Kong 暴露 |
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

## Kong Gateway 连接细节

### 前置条件

- Kong Controller 已按 DaemonSet 部署且 `proxy.stream` 包含 6379 (见 `my-argocd-manifests/argocd-apps/kong-controller-app.yaml`)
- `TCPIngress` CRD 已安装 (Kong chart 附带, `tcpingresses.configuration.konghq.com`)

### TCPIngress 示例 (待添加到 GitOps)

```yaml
apiVersion: configuration.konghq.com/v1beta1
kind: TCPIngress
metadata:
  name: redis-tcp
  namespace: redis
  annotations:
    kubernetes.io/ingress.class: kong
spec:
  rules:
    - port: 6379
      backend:
        serviceName: redis
        servicePort: 6379
```

推送后 ArgoCD/Kong Controller 自动同步, 客户端连任意节点 `:6379` 即被转发到 Redis Service。

### 验证 Kong 6379 连通性

```bash
# 三个节点 6379 均应开放 (Kong Stream 监听)
for ip in 100.77.64.95 100.105.130.0 100.104.150.19; do
  timeout 5 bash -c "echo > /dev/tcp/$ip/6379" && echo "$ip:6379 → 开放" || echo "$ip:6379 → 不通"
done
```

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

- Redis 通过 Kong Gateway 暴露，Redis 本身只暴露 ClusterIP；**不要**将 Redis 直接暴露公网 6379
- 公网访问必须走 Kong + 认证层（Basic Auth / Kong ACL），Redis 保持私网
- 密码一律通过 Secret/`.env` 管理，**绝不入库**
- K8s 集群内 `kubectl` 访问权限要收敛（Redis 密码在 Secret 中可见）
- TCPIngress 的 backend 指向 Redis Service，端口号要一致（6379）

## 环境速查

| 组件 | 位置 | 地址 |
|------|------|------|
| LiteLLM Proxy | GCP 伦敦 europe-west2-c | Alice VM (Tailscale 100.94.13.17) |
| Redis | OCI 新加坡 ap-singapore-1 | free-arm-vm, ClusterIP Service `redis:6379` |
| Kong 入口 | 3 节点 DaemonSet | `:6379` (任意节点 Tailscale IP 均可) |
| MySQL (计费) | OCI Singapore | rin-heatwave, `10.0.0.247:3306` |
| K3s 集群 | 腾讯云 + OCI + NUC | 3 节点 (vm-0-2-debian / free-arm-vm / nuc) |
| ArgoCD | 阿里云 K3s | root-bootstrap (App-of-Apps), 管理 5+ 子应用 |
