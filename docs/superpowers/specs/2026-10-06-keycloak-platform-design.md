# 引入 Keycloak 26.8 作为平台 OIDC 认证服务

## 目标

把 Keycloak 26.8 作为独立平台组件部署到集群，提供单一 OIDC 认证服务，未来接入 ArgoCD / Grafana / 9Router / OpenSandbox 全部 Web UI 入口。本次仅交付 Keycloak 平台本身；每个应用接入 OIDC 各开独立 PR。

## 背景

家庭实验室当前为单租户自托管平台：9Router（AI 网关）、OpenSandbox（沙箱控制平面）、ArgoCD（GitOps）、Grafana（监控）、OpenSandbox sandbox API。各自登录方式不统一：

- 9Router：API key，存在 PVC 上
- Grafana：admin 账号，密封 Secret 静态
- ArgoCD：当前无 SSO，bootstrap 中显式 `argocd-dex-server --replicas=0`，注释 "no dex, no SSO needed"
- OpenSandbox：API key（同 9Router 模式）

引入 Keycloak 把「身份」从「每个应用自己一套」统一为「一个 realm、一套用户、各应用 OIDC 客户端」。

### 设计选择空间

- **Keycloak Operator vs Helm chart**：上游 Keycloak 26.x 不发布官方 Helm chart；可选 codecentric/keycloakx（社区 Helm）或 Bitnami chart（Bitnami 镜像），但两者均为社区产物。Keycloak 26.x 官方推荐路径是 [Keycloak Operator](https://www.keycloak.org/2025/keycloak-2640-released) + `Keycloak` / `KeycloakRealmImport` CR。本仓库选 Operator 模式，与 OpenSandbox 同套路（渲染上游 chart 源至 `apps/`、ServerSideApply）。
- **PostgreSQL 随附 vs 独立**：Keycloak 必须持久化用户/会话/客户端。选 PostgreSQL 18 作为**独立平台组件**（不嵌在 Keycloak 应用下），未来 OpenSandbox / 9Router / 监控栈等需要数据库的应用直接共用同一集群的 PG，凭证按命名空间分发。
- **Realm 配置 GitOps vs admin UI**：选 RealmImport CR 完全 GitOps 化；四个客户端 + 初始 admin 一次性导入，后续调整由 operator 重协调。
- **ArgoCD 接入范围**：本次仅交付 Keycloak 平台，ArgoCD OIDC 接入另开 PR（保留 bootstrap 中 `dex --replicas=0` 现状）。

## 架构

### 同步波次

| 波次 | Application | 源 |
|------|-------------|---|
| 0 | cert-manager、sealed-secrets、opensandbox、**keycloak-operator** | 渲染上游 chart 源（operator wave 0 因仅提供 CRD，与 OpenSandbox 同款） |
| 1 | platform-config、monitoring、**platform-postgres** | Bitnami PostgreSQL Helm chart，multi-source 套件 |
| 2 | 9router、**keycloak**（CR + RealmImport） | Keycloak CR + RealmImport CR + Ingress；wave 2 严格依赖 wave 1 的 PostgreSQL Ready |

### 组件树

```
argocd/
  platform-keycloak-operator.yaml       # wave 0, ServerSideApply=true
  platform-postgres.yaml                # wave 1, multi-source Helm
  platform-keycloak.yaml                # wave 2

apps/keycloak-operator/
  # 渲染自 keycloak/keycloak-k8s-resources/kubernetes/charts/keycloak-operator
  # 包含 Namespace、CRDs（keycloaks/keycloakrealimports/...）、operator Deployment、RBAC

apps/postgres/
  namespace.yaml                        # database ns + 描述注解
  sealed-credentials.yaml               # SealedSecret: admin-password + keycloak-password

platform/postgres/
  values.yaml                           # Bitnami chart values（PG18、local-path 1Gi PVC）

platform/config/
  namespaces.yaml                       # 新增 database 条目

apps/keycloak/
  namespace.yaml                        # keycloak ns + 描述注解
  keycloak-cr.yaml                      # Keycloak CR
  realm-import.yaml                     # KeycloakRealmImport: homelab realm + 4 客户端 + admin
  sealed-secrets.yaml                   # SealedSecret: admin-password + 4 client secret
  ingress.yaml                          # Traefik Ingress: keycloak.lab.csharpkit.com

docs/
  operations/adding-keycloak.md         # 部署/封印/验证 手册
  adr/008-keycloak-platform.md          # 设计决策记录
```

### 资源（2 vCPU / 4 GB 节点预算）

| 组件 | requests | limits |
|------|----------|--------|
| keycloak-operator | 25m / 64Mi | 200m / 256Mi |
| keycloak StatefulSet | 200m / 384Mi | 500m / 768Mi |
| postgres Bitnami primary | 50m / 128Mi | 250m / 384Mi |

新增约 275m CPU + 576Mi 内存请求。叠加现有 ArgoCD (~291m / 768Mi) + OpenSandbox (~210m / 448Mi)，总请求 ~776m / 1.78Gi；监控栈 Prometheus + Grafana (~500m-1Gi) 与 9Router 仍在余量内。

## Keycloak 配置

### Keycloak CR 关键字段

```yaml
spec:
  hostname:
    hostname: keycloak.lab.csharpkit.com
    admin:    keycloak.lab.csharpkit.com
    strict:   false       # 信任 Traefik 转发的 X-Forwarded-*
  proxy:
    edgeHeaders: true    # edge 模式，上游终止 TLS
  instances: 1            # 单实例，不集群化
  features:
    enabled: [persistent-user-sessions]
  db:
    vendor: postgres
    host: keycloak-postgres.database.svc.cluster.local
    port: 5432
    database: keycloak
    username: keycloak
    password:
      valueFrom:
        secretKeyRef: { name: postgres-credentials, key: keycloak-password }
  http:
    tls: { enabled: false }  # Traefik 已终止 TLS
```

### RealmImport CR 关键字段

```yaml
spec:
  realm:
    realm: homelab
    sslRequired: external
    registrationAllowed: false
    ssoSessionIdleTimeout: 28800
  users:
    - username: homelab-admin
      realmRoles: [realm-admin]
      credentials:
        - type: password
          valueFrom:
            secretKeyRef: { name: homelab-secrets, key: admin-password }
  clients:
    - clientId: argocd
      rootUrl: https://argo.lab.csharpkit.com
      redirectUris: [https://argo.lab.csharpkit.com/auth/callback]
      webOrigins:    [https://argo.lab.csharpkit.com]
      secret:
        valueFrom:
          secretKeyRef: { name: homelab-secrets, key: argocd-client-secret }
    # grafana / 9router / opensandbox 同款结构
```

四个客户端均为 confidential（持有 secret）、Authorization Code Flow、关闭 Resource Owner Password Grant。`sslRequired: external` 强制所有认证流走 HTTPS。

> **API 验证 caveat**：上面 `Keycloak` 与 `KeycloakRealmImport` CR 的字段（如 `spec.hostname.strict`、`spec.proxy.edgeHeaders`、`spec.http.tls.enabled`、`spec.clients[].secret.valueFrom.secretKeyRef`）按 Keycloak 26.8 operator CRD 草拟；落地前用 `kubectl explain` 对照实际 CRD 字段定义逐项确认；operator 版本与 Keycloak server 版本需严格对齐。

## 凭证

### SealedSecret 清单

| 命名空间 | SealedSecret | key | 用途 |
|----------|-------------|-----|------|
| `database` | `postgres-credentials` | `admin-password`、`keycloak-password` | Bitnami chart via `existingSecret`；Keycloak CR 跨 ns `secretKeyRef` |
| `keycloak` | `homelab-secrets` | `admin-password`、`argocd-client-secret`、`grafana-client-secret`、`9router-client-secret`、`opensandbox-client-secret` | RealmImport CR via `secretKeyRef` |

共 2 个 SealedSecret、7 个加密 key。生成流程沿用 `docs/operations/adding-opensandbox.md#sealing-the-api-key`，命令改为 `k3s kubectl` 与 `kubeseal` 串联，明文仅经 stdin/stdout、`unset HISTFILE` + `unset <VAR>` 防 shell 历史。

### 轮换

- 重新生成 → `kubeseal` → 推送。Bitnami 检测 `existingSecret` 变化自动滚动；Keycloak 通过 `secretKeyRef` 自动取新值；RealmImport 重协调。
- 不需要重启任何 Pod（除 Bitnami PG StatefulSet）。

## 首次部署序列

沿用 OpenSandbox 的两段 commit 模式：

**PR 1：基础设施** —— 提交所有 manifest，SealedSecret 仅元数据（encryptedData 空）。ArgoCD 同步后 Keycloak 启动，**无 realm、无 admin**。

**PR 2：封印密钥** —— 用户在能访问集群的机器上生成 7 个 secret → `k3s kubectl create secret --dry-run` → `kubeseal` → 写回两个 SealedSecret。ArgoCD 重新协调，RealmImport 导入 `homelab` realm，admin 用户与四个客户端落地。

完整命令见 `docs/operations/adding-keycloak.md`（PR 2 流程）。

## 安全

- **无明文进 git**：所有 secret 在加密前只在内存中存在；`/tmp` 不留临时文件。
- **`sslRequired: external`**：admin 控制台也强制走 `keycloak.lab.csharpkit.com`，杜绝从集群内部绕过 TLS 直接调管理 API。
- **关闭自注册**：`registrationAllowed: false`，用户必须由 admin 显式创建。
- **`directAccessGrantsEnabled: false`**：仅允许 Authorization Code 流程，禁止 Resource Owner Password Grant。

## 验证

PR 2 合并后：

```bash
export K3S_CMD="k3s kubectl"

# operator + CRDs
$K3S_CMD -n keycloak get deploy keycloak-operator
$K3S_CMD get crd keycloaks.k8s.keycloak.org keycloakrealmsimports.k8s.keycloak.org
$K3S_CMD get crd | grep keycloak

# PostgreSQL 在线
$K3S_CMD -n database get sts keycloak-postgres
$K3S_CMD -n database get secret postgres-credentials -o jsonpath='{.data.keycloak-password}' | base64 -d | \
  $K3S_CMD -n database exec -i sts/keycloak-postgres -- psql -U keycloak -d keycloak -c '\dt'

# Keycloak pod Ready
$K3S_CMD -n keycloak wait --for=condition=Ready pod -l app=keycloak --timeout=300s

# realm 已导入
$K3S_CMD -n keycloak get keycloakrealmimport homelab

# TLS 证书签发
$K3S_CMD -n keycloak get certificate keycloak-tls

# OIDC discovery 端点
curl --fail https://keycloak.lab.csharpkit.com/realms/homelab/.well-known/openid-configuration

# admin console 可达
curl --fail -o /dev/null -w '%{http_code}\n' https://keycloak.lab.csharpkit.com/admin/master/console/
```

ArgoCD UI 中 `keycloak`、`keycloak-operator`、`platform-postgres` 三个 Application 全部 Healthy/Synced。

## 不在本次范围

- **ArgoCD OIDC 接入**：另开 PR，bootstrap install.sh 中加 `oidc.config`，argo.lab 走 Keycloak 登录；本地 admin 账号保留为后门。
- **Grafana OIDC 接入**：另开 PR，Grafana values 加 `auth.generic_oauth` 配置段。
- **9Router OIDC 接入**：另开 PR，9router 加 OIDC provider。
- **OpenSandbox OIDC 接入**：另开 PR，OpenSandbox server 配置 OIDC 客户端认证。
- **多副本 / Infinispan**：单节点无 KVM，1 副本足够；26.6+ zero-downtime rolling 在多副本下才有意义。
- **Keycloak metrics 抓取**：v1 不加 ServiceMonitor，后续可加进 monitoring。

## 参考

- ADR-007：OpenSandbox 1.1 平台决策（资源精简、wave 0 决策、ServerSideApply）
- ADR-003：sealed-secrets 用于公开仓库
- ADR-004：cert-manager HTTP-01
- ADR-005：通配符 DNS + Traefik SNI 路由
- `docs/operations/adding-opensandbox.md`：两段 commit 模式借鉴对象
- `docs/operations/argocd-resource-limits.md`：节点资源预算参考
- Keycloak 26.4 release notes：<https://www.keycloak.org/2025/keycloak-2640-released>
- Keycloak Kubernetes Helm 选型：<http://www.golinuxcloud.com/install-keycloak-helm/>
- Keycloak 26 HA：<https://labhub.hopto.org/blog/devops/2026-06-12-keycloak-ha-kubernetes-clustering-guide>