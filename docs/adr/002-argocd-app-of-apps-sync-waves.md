# ADR-002：使用 ArgoCD 应用集合模式与同步波次

**状态：** 已接受 · **日期：** 2026-07-23

## 背景

集群必须能够通过 Git 重现并具备自愈能力：新节点应在引导阶段之后无需手动执行 `kubectl apply`，即可收敛到声明的状态；任何配置偏差也应自动回滚。平台还有一些先后顺序约束：cert-manager 的 CRD 必须先创建，之后才能签发证书；应用密钥必须先解密，挂载这些密钥的 Pod 才能启动；Ingress 请求证书前，Let's Encrypt 颁发者必须已经创建。

因此需要回答两个问题：由什么机制驱动协调，以及如何表达资源的部署顺序。

## 决策

采用 **ArgoCD** 的**应用集合（app-of-apps）**布局，并使用**同步波次（sync waves）**控制部署顺序。

### 应用集合模式

安装 ArgoCD 后，`bootstrap/install.sh` 只应用一个对象：`root` Application（`bootstrap/root.yaml`）。`root` 会监视本仓库的 `argocd/` 目录，其中的每个 Application 清单都会成为受管理的应用。添加项目只需向 `argocd/` 添加一个文件并推送。从引导完成后，Git 即为事实来源，不再需要执行其他命令式操作。

每个 Application（包括 `root`）都启用 `automated: { prune: true, selfHeal: true }`，因此被删除的资源会恢复，手动对集群所做的修改也会被回滚。

### 同步波次

使用 `argocd.argoproj.io/sync-wave` 注解声明顺序。波次编号较小的应用先同步：

| 波次 | 应用 | 原因 |
|------|--------------|--------|
| 0 | `cert-manager`、`sealed-secrets`、`platform-coredns` | CRD 与密钥解密能力，以及 Pod 上游 DNS 永久化（参见 ADR-010） |
| 1 | `platform-config`、`monitoring` | `platform-config` 需要 cert-manager 的 CRD（ClusterIssuer）；监控需要 Operator 的 CRD |
| 2 | `chesskernel`、`pixelhub` | 平台运行正常后，最后同步应用 |

## 后果

- 引导过程只需执行一组命令式操作（安装 k3s、安装 ArgoCD、应用 `root`）；其余资源均以声明式方式管理并持续协调。
- 针对节点资源有限的情况，对 ArgoCD 做了精简：将 dex 和 notifications controller 的副本数设为零；服务器使用 `server.insecure=true`，使 TLS 仅在 Traefik 处终止（参见 ADR-005）。这些设置通过 `install.sh` 在运行时打补丁，而非写入清单，因为它们用于配置 ArgoCD 本身。
- 部分资源需要特殊的同步处理。监控 Application 使用 `ServerSideApply=true`，因为 Prometheus CRD 超出了客户端应用注解的大小限制。Prometheus Operator 的准入 Webhook 证书由 cert-manager 签发，而非由 Chart 中会自行删除的补丁 Job 签发；否则这些 Job 可能与 ArgoCD 健康检查发生竞态，导致每次同步都被标记为失败。
- 在应用级别启用 `prune: true` 功能强大，但也有风险。我们通过为命名空间单独添加 `argocd.argoproj.io/sync-options: Prune=false` 注解（`platform/config/namespaces.yaml`），使其不受自动清理影响。因此，从清单中删除某个命名空间配置行，不会删除仍在运行的命名空间及其中的所有资源。
