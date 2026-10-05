# 添加应用

集群运行的所有内容都在本仓库中声明。添加项目需要编写清单、加密其密钥并推送。ArgoCD 会自动发现并部署应用，cert-manager 会签发 TLS 证书，而通配符 DNS 已能解析其主机名。无需 SSH 登录，也无需修改 DNS。

本指南使用 `<name>` 表示新项目名称。如果需要基于 PVC 的服务，可参考 9Router；否则请根据实际需要选择相应的资源模式。目前集群只有一个自托管应用（9Router），因此没有客户端/服务器拆分或应用级登录的示例。

## 1. 在 `apps/<name>/` 中编写应用清单

在 `apps/<name>/` 中创建项目所需的 Kubernetes 对象。参照现有目录结构，保持清单精简，并尽量做到每个文件只负责一项功能。

典型的 Web 应用包含：

- **`client.yaml`**：一个 Deployment（使用 nginx 提供静态资源包）以及一个监听 80 端口的 Service。客户端 nginx 将 API 路径代理到集群内的 `server` Service。
- **`server.yaml`**：用于 API 的 Deployment 和一个 Service，通常还包含 ServiceMonitor（见第 5 步）。将 Service 命名为 `server`，这样客户端 nginx 的代理目标（`http://server:<port>`）才能正确解析。
- **`ingress.yaml`**：公网路由（见第 4 步）。
- 按需添加有状态组件：对于单写入者的持久化数据，使用设置了 `strategy: Recreate` 的 Deployment 和 PVC（参见 `apps/9router/deployment.yaml`）。如果应用需要为每个副本分别分配存储，则使用带有 `volumeClaimTemplates` 的 StatefulSet。

为每个容器设置资源 `requests` 和 `limits`。节点配置为 1 个 vCPU / 4 GB 内存，其中 CPU 资源尤为有限；不设上限的 Pod 会挤占其他工作负载的资源。可参考现有应用的资源配置作为起点。

自有镜像从 GHCR 拉取，镜像地址为 `ghcr.io/mateuseap/<name>-<component>:latest`，并设置 `imagePullPolicy: Always`。各应用仓库中的 CI 会在变更合并后构建并推送 `:latest` 镜像。第三方服务可以使用其上游镜像仓库，例如 9Router 使用 `decolua/9router:latest`。使用 `kubectl rollout restart` 重启受影响的 Deployment（见[升级组件](#升级组件)）。

## 2. 在 `argocd/` 中添加 Application 清单

参照以下 Application 清单模式添加 `argocd/app-<name>.yaml`，并设置应用名称、源路径和目标命名空间：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <name>
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2" # 应用在平台组件之后同步
spec:
  project: default
  source:
    repoURL: https://github.com/geffzhang/cloudhomelab
    targetRevision: main
    path: apps/<name>
  destination:
    server: https://kubernetes.default.svc
    namespace: <name>
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

`root` 应用集合会监视 `argocd/`，因此只需添加此文件，ArgoCD 就会开始管理该应用。Wave 2 可确保应用在 cert-manager、sealed-secrets 和监控组件运行正常后再进行同步。

如果希望命名空间像其他命名空间一样带有描述并受到保护、不被自动清理，请在 `platform/config/namespaces.yaml` 中添加该命名空间，并设置 `homelab.csharpkit.com/description` 注解和 `argocd.argoproj.io/sync-options: Prune=false`。否则，`CreateNamespace=true` 会创建一个不带其他配置的空命名空间。

## 3. Sealed Secret

绝不能提交明文密钥。在 `/tmp` 中创建明文 `Secret`，将其加密后提交加密结果，并彻底删除明文文件。

```bash
cp docs/examples/9router-secrets.example.yaml /tmp/secrets.yaml
# 编辑 /tmp/secrets.yaml：将 metadata.name 和 metadata.namespace 设为 <name>，然后填入真实值
kubeseal --controller-namespace kube-system --format yaml \
  < /tmp/secrets.yaml > apps/<name>/sealed-secrets.yaml
shred -u /tmp/secrets.yaml
```

生成的 `SealedSecret` 使用集群密钥加密，可以安全地存放在公开仓库中。Pod 使用 `secretKeyRef` 按名称引用解密后的 `Secret`。有关密钥备份和轮换方式，请参见 [ADR-003](../adr/003-sealed-secrets-for-public-repo.md) 和[安全文档](../security/security.md)。

## 4. Ingress

添加一个 `Ingress`，设置 `ingressClassName: traefik`，配置 `*.lab.csharpkit.com` 下的 `host:` 规则，并添加 cert-manager 注解：

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: traefik
  rules:
    - host: <name>.lab.csharpkit.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: client
                port: { number: 80 }
  tls:
    - hosts: [<name>.lab.csharpkit.com]
      secretName: <name>-tls
```

通配符记录已能解析该主机名，因此 cert-manager 会在首次请求时通过 HTTP-01 签发证书。如果服务还需要一个尚未解析的自定义域名，请将其配置在第二个 Ingress 中，避免待签发的证书影响已正常工作的主机名的 TLS 配置。参见[网络文档](../networking.md)。

## 5. ServiceMonitor（指标）

如果应用暴露 Prometheus 指标，请添加 `ServiceMonitor`，以便 kube-prometheus-stack 抓取指标。通用模式如下：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: <name>-server
  namespace: <name>
  labels:
    release: monitoring   # 必填：kube-prometheus-stack 的选择器会匹配此标签
spec:
  selector:
    matchLabels: { app: server }
  endpoints:
    - port: http          # Service 上的具名端口
      path: /metrics
      interval: 60s
  namespaceSelector:
    matchNames: [<name>]
```

有两项配置不可缺少：`release: monitoring` 标签（Operator 只会选择带有此标签的 ServiceMonitor），以及 Service 上的**具名端口**（端点通过名称引用端口）。`/metrics` 仅通过集群内部的 Service 端口提供，绝不能将其添加到公网 Ingress。

这些指标会显示在精心维护的 **Homelab Overview** 仪表板（`platform/config/grafana-dashboard-homelab.yaml`）中。该仪表板是带有 `grafana_dashboard: '1'` 标签的 ConfigMap，由 Grafana sidecar 加载。若要添加面板，请编辑该仪表板的 JSON；不要启用 Chart 的默认仪表板（在单节点环境中会产生过多无用信息）。

## 6. 推送

```bash
git checkout -b feat/<name>
git add apps/<name>/ argocd/app-<name>.yaml
git commit -m "feat: add <name>"
git push -u origin feat/<name>
```

创建 PR（参见 [CONTRIBUTING](../../CONTRIBUTING.md)）。合并到 `main` 后，ArgoCD 会同步新的 Application，cert-manager 会签发 TLS 证书，应用随后可通过 `https://<name>.lab.csharpkit.com` 访问。在 ArgoCD UI 中观察应用是否收敛到预期状态。

## 升级组件

- **应用镜像**使用 `:latest` 标签。自有镜像由 CI 在变更合并后推送；第三方镜像则跟随其上游仓库更新。只重启该应用中实际存在的 Deployment，例如 `kubectl -n <name> rollout restart deploy/<deployment>`。之后的里程碑中会考虑使用 argocd-image-updater 自动完成此操作。
- **基于 Helm 的平台组件**（cert-manager、sealed-secrets、kube-prometheus-stack）在各自的 `argocd/platform-*.yaml` 中固定 Chart 版本。升级时，更新 `targetRevision`，查看 Chart 更新日志中有关 CRD 或 values 变更的说明，然后推送。ArgoCD 会应用更改。监控应用使用 `ServerSideApply=true`，因为 Prometheus CRD 超出了客户端 apply 的大小限制。
- **ArgoCD 本身**由 `bootstrap/install.sh` 安装，该脚本跟踪 `stable` 通道（当前为 v3.4.5）。重新运行脚本即可升级；运行时精简配置（将 dex 和 notifications 副本数设为零、设置 `server.insecure=true`）会以幂等方式重新应用。
- **k3s** 在节点级别升级，通过 SSH 操作，不属于 GitOps 管理范围。

每次只升级一个组件。继续下一步之前，先确认应用在 ArgoCD 中恢复为绿色状态，并且在 Grafana 中运行正常。
