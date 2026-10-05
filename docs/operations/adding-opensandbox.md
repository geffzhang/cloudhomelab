# 添加 OpenSandbox

OpenSandbox 1.1 是集群中的沙箱平台基础设施（与 cert-manager 同级），通过 kubebu 提供版本化的 Helm chart 源，本仓库用 `helm template` 渲染后以纯清单方式由 ArgoCD 同步。原始 chart 路径：`E:\GitHub\OpenSandbox\manifests\charts\`，渲染产出纯 HTML（含可审计的 diff）。

## 已部署组件

同步波次 0（与 cert-manager、sealed-secrets 同级），位于 `apps/opensandbox/`：

| 文件 | 来源 | 内容 |
|------|--------|------|
| `base.yaml` | `manifests/charts/base` | 3 个 CRD（`BatchSandbox`、`Pool`、`SandboxSnapshot`）及其用户层 RBAC。fast-sandbox 资源（`sandbox.fast.io` CRD 与控制平面 RBAC）显式禁用 -- 本 VPS 无 KVM。 |
| `registry.yaml` | 手写 | `registry:2` Deployment + Service（ClusterIP）+ 5Gi PVC，作为集群内唯一 SHA-01 仓库。控制器默认参数 `docker-registry.opensandbox-system.svc:5000` 即指向此处。不启用鉴权。 |
| `controller.yaml` | `manifests/charts/controller` | `opensandbox-controller-manager` Deployment、控制器 RBAC、metrics Service（8080 端口，明文 HTTP，默认未启用）。快照参数已覆盖默认参数。 |
| `gateway.yaml` | `manifests/charts/ingress-gateway` | `opensandbox-ingress-gateway` Deployment + Service（ClusterIP）、gateway RBAC。本 PR 启用副本 1、资源精简。 |
| `server.yaml` | `manifests/charts/server` | `opensandbox-server` Deployment + Service、`configToml` ConfigMap（Kubernetes 运行时风格）。`OPENSANDBOX_SERVER_API_KEY` 从 `opensandbox-api-key` Secret 引用。Gateway 公告已启用。 |
| `ingress.yaml` | 手写 | Traefik Ingress → `opensandbox-server:80`，主机名 `sandbox.lab.csharpkit.com`，`cert-manager.io/cluster-issuer: letsencrypt-prod`。 |
| `sealed-secret-api-key.yaml` | 手写 | 由用户在首次部署后填充（见下）。不包含明文。 |

ArgoCD 资源识别：`argocd/platform-opensandbox.yaml`，同步波次 0，启用 `ServerSideApply=true`（CRD 较大）。

## 首次部署

合并后，ArgoCD 会同步所有上述资源，但 `opensandbox-server` 会在 API 密钥 Secret 缺失时拒绝启动。这是预期的：服务器以 fail-fast 行为来避免在空认证下运行。

### 密封 API 密钥

在能访问集群的机器上（默认在 `~/.kube` 有 kubeconfig 指向本集群）：

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

密钥密钥格式参考 `docs/examples/opensandbox-api-key.example.yaml`。

### 验证

```bash
# 所有 Pod 运行中
kubectl get pods -n opensandbox-system

# CRD 已安装
kubectl get crd | grep opensandbox

# API 到达 + 证书已签发
kubectl get certificate -n opensandbox-system opensandbox-server-tls
curl --fail https://sandbox.lab.com/health
```

在 ArgoCD UI 中确认 `opensandbox` Application 已变绿。

## 资源使用

默认 chart 资源为服务器和网关请求 1 vCPU / 4Gi，远超本 VPS。为 1 vCPU / 4 GB 节点调整后：

| 组件 | requests | limits |
|--------|---------|--------|
| controller | 10m / 64Mi | 500m / 128Mi（默认） |
| server | 100m / 192Mi | 500m / 512Mi |
| gateway | 50m / 96Mi | 500m / 256Mi |
| registry | 50m / 96Mi | 250m / 256Mi |

合计约 16% 的 vCPU 与约 16% 的内存，剩余大部分可用于沙箱任务。

## 升级

1. 在 `E:\GitHub\OpenSandbox` 中 `git fetch --tags && git checkout release-X.Y.Z`。
2. 查看上游 release notes（`docs/releases/X.Y.Z.md`）。
3. 对每个 chart 重新渲染到本仓库 `apps/opensandbox/`：
   ```bash
   helm template base         manifests/charts/base          -n opensandbox-system -f $TEMP/opensandbox-render/base-values.yaml     > apps/opensandbox/base.yaml
   helm template opensandbox-controller manifests/charts/controller -n opensandbox-system -f $TEMP/opensandbox-render/controller-values.yaml > apps/opensandbox/controller.yaml
   helm template ingress-gateway manifests/charts/ingress-gateway -n opensandbox-system -f $TEMP/opensandbox-render/gateway-values.yaml    > apps/opensandbox/gateway.yaml
   helm template opensandbox-server    manifests/charts/server     -n opensandbox-system -f $TEMP/opensandbox-render/server-values.yaml    > apps/opensandbox/server.yaml
   ```
4. 查看 `git diff`，提交，推送。ArgoCD 自动应用。

不要手动在集群上运行 `helm install` / `helm upgrade` -- 本仓库使用渲染后的纯清单，两者会互覆盖。

## 轮换 API 密钥

1. 重新密封新的 API 密钥为 SealedSecret（同上）。
2. 推送到 `main`。
3. `kubectl rollout restart deployment/opensandbox-server -n opensandbox-system`。

## 已知遗留项
- **fast-sandbox 未启用。** Firecracker 需要 KVM（`/dev/kvm`），本 VPS 不可用。沙箱仅能通过默认 Kubernetes 运行时跑（普通容器）。
- **网关公网访问未启用。** `ingress-gateway` Service 是 ClusterIP，外部沙箱 URL 路由是另一项任务（可能再加一个 Traefik IngressRoute 做 TLS passthrough，或 NodePort）。本次 PR 不包含。
- **网关 secure-access keyring 未配置。** 默认 config 下路由令牌未签名。如果后续开启外部沙箱访问，需要配置 `server.gateway.secureAccess` 与 `gateway.secureAccess` 使用同一密钥环。