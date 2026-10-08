# 添加 OpenSandbox

部署、密钥密封、升级与轮换的操作手册。架构决策、备选方案与权衡见 [ADR-007](../adr/007-opensandbox-platform.md)。

## 已部署组件

OpenSandbox 1.1 部署在同步波次 0，源目录 `apps/opensandbox/`，由 ArgoCD 通过 `argocd/platform-opensandbox.yaml`（sync-wave 0、`ServerSideApply=true`）管理。

| 文件 | 内容 |
|------|------|
| `base.yaml` | 7 个 CRD：3 个 `sandbox.opensandbox.io`（`BatchSandbox`、`Pool`、`SandboxSnapshot`）和 4 个 `sandbox.fast.io`（`Sandbox`、`SandboxTemplate`、`SandboxSnapshot`、`SandboxPool`），以及用户层 RBAC |
| `registry.yaml` | `registry:2` Deployment + Service（ClusterIP）+ 5Gi PVC，作为集群内 OCI 仓库 |
| `controller.yaml` | `opensandbox-controller-manager` Deployment、控制器 RBAC、metrics Service（默认未启用） |
| `gateway.yaml` | `opensandbox-ingress-gateway` Deployment + Service（ClusterIP）、gateway RBAC |
| `server.yaml` | `opensandbox-server` Deployment + Service、`configToml` ConfigMap。引用 `opensandbox-api-key` Secret 读取 API 密钥 |
| `ingress.yaml` | Traefik Ingress → `opensandbox-server:80`，主机名 `sandbox.lab.csharpkit.com` |
| `gateway-ingress.yaml` | Traefik Ingress → `opensandbox-ingress-gateway:80`，主机名 `sandbox-gateway.lab.csharpkit.com`；独立承载 URI 路由的沙箱流量 |
| `sealed-secret-api-key.yaml` | 由用户在首次部署后填充（见下）。不包含明文 |

### 网关路由

Server API 使用 `sandbox.lab.csharpkit.com`；按路径形式访问沙箱时使用独立的
`sandbox-gateway.lab.csharpkit.com`，该域名由 `gateway-ingress.yaml` 转发到
Ingress Gateway。URI 模式下 `gateway.address` 配置为具体主机名（不带协议或
`*.`）；现有 `*.lab.csharpkit.com` DNS A 记录覆盖此主机名，证书仍由现有
`letsencrypt-prod` HTTP-01 按具体域名签发。

```toml
[ingress]
mode = "gateway"
gateway.address = "sandbox-gateway.lab.csharpkit.com"
gateway.route.mode = "uri"
```

## 首次部署

合并到 `main` 后，ArgoCD 同步所有资源。`opensandbox-server` 在缺失 `opensandbox-api-key` Secret 时拒绝启动（fail-fast），因此首次部署后必须执行 `sealapi` 步骤。controller、gateway、registry 与 CRD 不依赖该 Secret，正常起来。

### 封印 API 密钥

在能访问集群的机器上（默认 `~/.kube/config` 指向本集群）：

```bash
KEY=$(openssl rand -base64 32)
unset HISTFILE   # 不要让密钥进入 shell 历史

kubectl create secret generic opensandbox-api-key \
  --namespace opensandbox-system \
  --from-literal=api-key="$KEY" \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace kube-system --format yaml \
    > apps/opensandbox/sealed-secret-api-key.yaml

unset KEY
git add apps/opensandbox/sealed-secret-api-key.yaml
git commit -m "feat(opensandbox): seal API key"
git push
```

密钥字段格式参考 `docs/examples/opensandbox-api-key.example.yaml`。

### 验证

```bash
# 所有 Pod 运行中
kubectl get pods -n opensandbox-system

# OpenSandbox 与 fast-sandbox CRD 已安装
kubectl get crd | grep -E 'sandbox\.(opensandbox|fast)\.io'

# API 到达 + 证书已签发
kubectl get certificate -n opensandbox-system opensandbox-server-tls
kubectl get certificate -n opensandbox-system opensandbox-gateway-tls
curl --fail https://sandbox.lab.csharpkit.com/health
```

在 ArgoCD UI 中确认 `opensandbox` Application 已变绿。

## 资源使用

| 组件 | requests | limits |
|--------|---------|--------|
| controller | 10m / 64Mi | 500m / 128Mi |
| server | 100m / 192Mi | 500m / 512Mi |
| gateway | 50m / 96Mi | 500m / 256Mi |
| registry | 50m / 96Mi | 250m / 256Mi |

合计约 16% CPU + 16% 内存，留出余量给沙箱任务。资源决策原因见 [ADR-007](../adr/007-opensandbox-platform.md#资源精简)。

## 升级

1. 在 `E:\GitHub\OpenSandbox` 中 `git fetch --tags && git checkout release-X.Y.Z`。
2. 查看上游 release notes（`docs/releases/X.Y.Z.md`），关注 CRD 字段名变化。
3. 在本仓库覆盖 `apps/opensandbox/` 下的渲染输出。values 重写示例：

```bash
cd E:/GitHub/OpenSandbox
VALUES=$TEMP/opensandbox-upgrade/values  # 自建目录，保留上游 values 覆盖
mkdir -p $VALUES
# 写入 base/controller/gateway/server 的 values.yaml（参见 git 历史中的初版）
helm template base         manifests/charts/base          -n opensandbox-system -f $VALUES/base.yaml     > /path/to/cloudhomelab/apps/opensandbox/base.yaml
helm template opensandbox-controller manifests/charts/controller -n opensandbox-system -f $VALUES/controller.yaml > /path/to/cloudhomelab/apps/opensandbox/controller.yaml
helm template ingress-gateway manifests/charts/ingress-gateway -n opensandbox-system -f $VALUES/gateway.yaml > /path/to/cloudhomelab/apps/opensandbox/gateway.yaml
helm template opensandbox-server manifests/charts/server -n opensandbox-system -f $VALUES/server.yaml > /path/to/cloudhomelab/apps/opensandbox/server.yaml
```

values 覆盖只调资源、路径内部资源开关、API key Secret 引用与网关公告；不要动手改动默认镜像、镜像仓库、ReplicaSet、端口。

不要手动在集群上运行 `helm install` / `helm upgrade` —— 本仓库使用渲染后的纯清单，两者会互覆盖（参见 [ADR-007](../adr/007-opensandbox-platform.md#渲染而非引用-chart)）。

## 轮换 API 密钥

1. 重新封印新的 API 密钥为 SealedSecret（同上）。
2. 推送到 `main`。
3. `kubectl rollout restart deployment/opensandbox-server -n opensandbox-system`。

## 已知遗留项

- 网关 `ClusterIP`，未对外暴露沙箱 URL。
- secure-access keyring 未配置（路由令牌未签名）。
- fast-sandbox（Firecracker）工作负载未启用 -- 本 VPS 无 KVM；其 CRD 已注册，但沙箱仍仅能跑为容器。
