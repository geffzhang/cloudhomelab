# ADR-007：引入 OpenSandbox 1.1 作为沙箱平台基础设施

**状态：** 已接受 · **日期：** 2026-10-05

## 背景

集群当前为单租户 AI 网关（9Router），需要在受控环境中执行不可信代码（agent 工作负载、第三方工具调用、临时脚本）。沙箱需具备：

- 通过 Kubernetes API 声明式创建与挂起/恢复
- 每次沙箱之间相互隔离（文件系统、网络、进程）
- 与现有 `*.lab.csharpkit.com` 公网接入复用同一套 Traefik + cert-manager 体系

可选方案：

- **OpenSandbox**（Apache-2.0，Kubernetes-native，提供 `BatchSandbox` / `Pool` CRD 与完整生命周期 API）
- **其他 sandbox-on-K8s 项目**（agent-sandbox、e2b、kubet 等）：与单节点 k3s 的契合度、维护活跃度均不如 OpenSandbox
- **自建沙箱**：开发与运维成本过高

## 决策

引入 OpenSandbox 1.1 作为同步波次 0 的平台组件，使用与 cert-manager、sealed-secrets 同样的渲染-提交模式。

### 同步波次 0

OpenSandbox 不依赖任何应用层资源，仅提供 CRD 与 control plane 控制器，因此可与 cert-manager/sealed-secrets 同处波次 0（参见 ADR-002）。其余波次不受影响。

### 渲染而非引用 chart

OpenSandbox 发布的是**chart 源**（`manifests/charts/`），不发布 `.tgz` 包，因此 ArgoCD Helm 模式无法直接消费（其依赖 chart 仓库解析 `dependencies`）。本仓库采用官方 GitOps 文档推荐的 `helm template` 方式：本地 `checkout release-1.1.0` → 渲染到 `apps/opensandbox/*.yaml` → 提交纯清单 → ArgoCD 直接应用。升级时切换到新版 tag 重渲染。

### 跳过 fast-sandbox

OpenSandbox 提供两个沙箱运行时：

- **Kubernetes 运行时**（默认）：沙箱跑为普通 Pod，可在本 VPS 工作
- **fast-sandbox（Firecracker）**：microVM 隔离更强，但**需要 KVM（`/dev/kvm`）与兼容内核**，本 VPS 均不具备

在 `base` chart 中显式禁用 `fastSandbox.crds.install`、`fastSandbox.rbac.create`、`fastSandbox.namespaces.create`，避免在集群中留下永远用不上的资源。沙箱实际跑为容器，pause/resume 仍可通过后续 controller 工作使用快照镜像。

### 集群内 registry 而非外部镜像仓库

控制器将沙箱快照镜像推送至 OCI registry。默认 controller 参数 `docker-registry.opensandbox-system.svc:5000` 直接部署一个 `registry:2` Deployment + ClusterIP Service + 5Gi PVC。考虑过的方案：

- **外部镜像仓库**（如腾讯云 COS 镜像服务）：引入额外鉴权与跨可用区成本
- **复用 local-path 临时存储**：PVC-bound 限制，不适合做快照镜像仓库
- **集群内 registry**（已选）：无鉴权（ClusterIP 仅集群内可达），与控制器默认参数对齐

### 资源精简

chart 默认请求：

| 组件 | chart 默认 requests | 节点实际资源 |
|--------|-------------------|-------------|
| server | 1 vCPU / 4 Gi | 整个节点 |
| gateway | 1 vCPU / 4 Gi | 整个节点 |
| controller | 10m / 64Mi | 合身 |
| registry | n/a | n/a |

默认下 server 和 gateway 一起请求的资源已超出整个 1 vCPU / 4 GB 节点。覆盖为：

| 组件 | 实际 requests | limits |
|--------|-------------|--------|
| controller | 10m / 64Mi | 500m / 128Mi |
| server | 100m / 192Mi | 500m / 512Mi |
| gateway | 50m / 96Mi | 500m / 256Mi |
| registry | 50m / 96Mi | 250m / 256Mi |

合计约 16% CPU + 16% 内存，留出余量给沙箱任务。

### `ServerSideApply=true`

OpenSandbox CRD 体积较大，超过 `kubectl apply` 客户端注解上限。开启 ArgoCD 的 `ServerSideApply=true` 走服务端应用。监控栈已经为此开启（参见 ADR-002）。

### 复用 Traefik Ingress

公网 API 入口 `sandbox.lab.csharpkit.com` 与 9router / argo / grafana 同样走 Traefik + cert-manager HTTP-01（参见 ADR-004、ADR-005），无需新增 Ingress controller 或新 ClusterIssuer。

## 后果

- **secret 双向依赖**：lifecycle server 拒绝在缺失 `opensandbox-api-key` 时启动（fail-fast），首次部署后必须由用户在能访问集群的机器上密封 API 密钥（参见 `docs/operations/adding-opensandbox.md#sealing-the-api-key`）。未密封前 server Pod 会 `CrashLoopBackOff`，但其余组件（controller、gateway、registry、CRD）正常服务。
- **gateway 公网入口留作下一项**。`ingress-gateway` Service 当前为 ClusterIP，外部沙箱 URL 路由未启用（需考虑 TLS passthrough 或 NodePort）。本次仅开通 lifecycle API 入口。
- **secure-access keyring 未配置**。默认配置下 gateway 路由令牌未签名；后续开启外部沙箱访问时必须同步配置 server 与 gateway 共享密钥环。
- **本仓库绑定 OpenSandbox 1.1 升级路径**。后续大版本升级需重新 `helm template` 整组 chart，可能涉及 CRD 升级、values API 变更、Controller/Server 启动参数差异。
- **local-path 存储类**。registry PVC 使用 `local-path`（k3s 内置，单节点够用）。如未来扩展为多节点，需迁移到分布式存储。
