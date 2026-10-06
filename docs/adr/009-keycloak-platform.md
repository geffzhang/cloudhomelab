# ADR-009：引入 Keycloak 26.8 作为平台 OIDC 认证服务

**状态：** 已接受 · **日期：** 2026-10-06

## 背景

家庭实验室当前为单租户自托管平台：9Router（AI 网关）、OpenSandbox（沙箱控制平面）、ArgoCD（GitOps）、Grafana（监控）、sandbox API。各自登录方式不统一：

- 9Router：API key，存在 PVC 上
- Grafana：admin 账号，密封 Secret 静态
- ArgoCD：当前无 SSO，bootstrap 中显式 `argocd-dex-server --replicas=0`，注释 "no dex, no SSO needed"
- OpenSandbox：API key（同 9Router 模式）

引入 Keycloak 把「身份」从「每个应用自己一套」统一为「一个 realm、一套用户、各应用 OIDC 客户端」。PostgreSQL 作为独立平台数据库组件，参见 [ADR-008](008-keycloak-platform.md)。

## 决策

### Keycloak Operator 模式（与 OpenSandbox 同款）

Keycloak 26.x 上游**不发布官方 Helm chart**。可选 codecentric/keycloakx（社区 Helm）、Bitnami chart（社区维护 Bitnami 镜像），均为社区产物。Keycloak 官方推荐路径是 [Keycloak Operator](https://www.keycloak.org/2025/keycloak-2640-released) + `Keycloak` / `KeycloakRealmImport` CR。

本仓库选 Operator 模式：

1. 下载 `keycloak/keycloak-k8s-resources` 上游仓库 tarball（tag `26.8.0`）
2. `kubectl kustomize homelab-patch/`（含 `resources: [../kubernetes]` + operator Deployment 资源 patch）渲染至 `apps/keycloak-operator/operator.yaml`
3. ArgoCD Application `keycloak-operator`（wave 0，`ServerSideApply=true`）管理

> **注：** 上游 26.8.0 仅以 Kustomize 形式分发 operator 资源（`kubernetes/` 目录），**没有 Helm chart**。`helm template` 命令被否决——这是相对于早期探索中曾被列为方案的修订。

理由：

- **官方维护路径**：operator 与 server 同版本号（26.8 ↔ 26.8）由同一团队维护
- **CRD 集中**：Keycloak / KeycloakRealmImport / Client 等 CRD 与 controller 同包，版本耦合风险低
- **复用 OpenSandbox 套路**：参见 [ADR-007](007-opensandbox-platform.md)，wave 0、渲染上游、ServerSideApply — 与本仓库已有模式一致

### 同步波次

| 波次 | Application | 关键资源 |
|------|-------------|----------|
| 0 | **keycloak-operator**（新增） | operator Deployment + CRDs |
| 1 | platform-config、monitoring、**platform-postgres**（参见 [ADR-008](008-keycloak-platform.md)） | PostgreSQL（v1 实际 PG 17.6.0，详见 ADR-008 备选方案） |
| 2 | 9router、**keycloak**（新增） | Keycloak CR + RealmImport CR + Ingress |

**wave 0 给 operator**：与 OpenSandbox 同推理，operator 仅提供 CRD 与 controller pod，不依赖任何应用层资源。

**wave 2 给 Keycloak**：Keycloak pod 启动后立即尝试连 PostgreSQL；wave 1 的 PG 必须 Ready。把 Keycloak 放 wave 2 让依赖显式化。

### 单 realm「homelab」

- **单 realm 而非多 realm**：一个 realm + 一套用户库，跨应用共用；多 realm 会让用户管理膨胀，单租户家庭实验室无必要
- **`homelab-admin`**：唯一 admin 用户，role `realm-admin`；密码 SealedSecret 收纳
- **`registrationAllowed: false`**：关闭自注册，用户必须由 admin 添加
- **`sslRequired: external`**：所有认证流强制 HTTPS（含 admin console）；杜绝从集群内部绕过 TLS 直接调管理 API
- **`directAccessGrantsEnabled: false`**：四个客户端均关闭 Resource Owner Password Grant，只走 Authorization Code 流程

### 四个 OIDC 客户端（GitOps 一次性导入）

| Client ID | Redirect URI | 接入 PR |
|------------|-------------------|--------|
| `argocd` | `https://argo.lab.csharpkit.com/auth/callback` | 另开 PR（bootstrap 加 `oidc.config`） |
| `grafana` | `https://grafana.lab.csharpkit.com/login/generic_oauth` | 另开 PR（Grafana values 加 `auth.generic_oauth`） |
| `9router` | `https://9router.lab.csharpkit.com/auth/callback` | 另开 PR |
| `opensandbox` | `https://sandbox.lab.csharpkit.com/auth/callback` | 另开 PR |

所有客户端：

- **confidential**（持有 secret）而非 public，避免 PKCE 配置漂移
- **standardFlowEnabled**：Authorization Code 流程
- **directAccessGrantsEnabled: false**：仅 OIDC，不支持密码模式

RealmImport CR 一次性导入；后续每个应用接入 OIDC 各开独立 PR，配置 `clientId` + `clientSecret`（SealedSecret）即可。

### Traefik + cert-manager 复用

公网入口 `keycloak.lab.csharpkit.com` 与 9router / argo / grafana / sandbox 同 Traefik + cert-manager HTTP-01 体系，无需新增 ingress controller 或新 ClusterIssuer（参见 [ADR-004](004-cert-manager-http01-vs-dns01.md)、[ADR-005](005-wildcard-dns-traefik-sni-routing.md)）。

Keycloak CR 配置：

```yaml
spec:
  hostname:
    hostname: keycloak.lab.csharpkit.com
    admin:    keycloak.lab.csharpkit.com
    strict:   false      # 信任 Traefik 转发的 X-Forwarded-*
  proxy:
    edgeHeaders: true   # edge 模式，上游终止 TLS
  http:
    tls:
      enabled: false     # Traefik 已解 TLS
```

三层信任：realm 级 `sslRequired: external` + operator 级 `strict: false` + 代理级 `edgeHeaders: true`，admin console 走 OIDC 公开域名，但内部 `k3s kubectl port-forward` 仍可调 admin 排查。

### SealedSecret 单源

`keycloak` 命名空间下 `homelab-secrets` SealedSecret 收纳五个 key：

- `admin-password`：homelab-admin 初始密码
- `argocd-client-secret`、`grafana-client-secret`、`9router-client-secret`、`opensandbox-client-secret`：四个 OIDC 客户端 secret

RealmImport CR 的 `users[].credentials[].valueFrom.secretKeyRef` 与 `clients[].secret.valueFrom.secretKeyRef` 引用同一份 Secret；轮换时改一个文件即可。

> Keycloak 26.x operator supports `secretKeyRef` 形式引用 secret；落地前用 `kubectl explain k8s.keycloak.org/v2alpha1.KeycloakRealmImport.spec.clients.secret` 验证字段定义；若 API 仅支持明文，回退为「operator 自动生成 + 后续 PR 提取 Secret 配置应用」模式。

### 资源精简

| 组件 | requests | limits |
|------|----------|--------|
| keycloak-operator | 25m / 64Mi | 200m / 256Mi |
| keycloak StatefulSet | 200m / 384Mi | 500m / 768Mi |

合计 ~225m / 448Mi。叠加 [ADR-008](008-keycloak-platform.md) 的 PostgreSQL（50m / 128Mi requests）、OpenSandbox（~210m / 448Mi）、ArgoCD（~291m / 768Mi）总请求约 776m / 1.78Gi；监控栈 Prometheus + Grafana（~500m-1Gi）与 9Router 仍在余量内。

### 两段 commit 部署（沿用 OpenSandbox 模式）

**PR 1：基础设施** —— 提交所有 manifest，SealedSecret 仅元数据（`encryptedData: {}`）。ArgoCD 同步后 Keycloak 启动，**无 realm、无 admin**。

**PR 2：封印密钥** —— 用户在能访问集群的机器上：

```bash
export K3S_CMD="k3s kubectl"
# 生成 5 个 realm secret + 2 个 PG secret，全部经 stdin → kubeseal → SealedSecret
```

PR 2 合并后 ArgoCD 重新协调，RealmImport 导入 `homelab` realm，admin 用户与四个客户端落地。完整步骤参见 `docs/operations/adding-keycloak.md`。

### 备选方案

- **codecentric/keycloakx Helm chart**：社区维护，使用官方 Quay 镜像，但 Keycloak 官方不推荐 Helm 路径。拒绝：本决策与上游官方建议对齐
- **Bitnami Keycloak chart**：Bitnami 打包镜像，与平台其他 cert-manager/monitoring 风格不一致。拒绝
- **多 realm 拆分**：每个应用独立 realm。拒绝：单租户家庭实验室无必要，用户管理膨胀
- **ArgoCD 同时接入 Keycloak**：本次仅交付 Keycloak 平台；argo.lab 走 Keycloak 登录另开 PR（保留 bootstrap 中 `dex --replicas=0` 现状）
- **多副本 + Infinispan 集群**：26.6+ zero-downtime rolling 在多副本下才有意义；单节点无 KVM 不需要
- **裸 Meta API Keycloak**：用 Keycloak Postman collection 手工管理 realm。拒绝：违背 GitOps

## 后果

- **明文 secret 仅在内存**：所有 7 个 secret 在 PR 2 生成时只在 shell 变量中存在，`unset HISTFILE` + `unset <VAR>` 防泄漏；不写 `/tmp` 临时文件
- **跨命名空间 secretKeyRef**：Keycloak operator 默认 ClusterRole 含 cluster-wide `secrets get`，可跨 ns 读 `postgres-credentials`（[ADR-008](008-keycloak-platform.md) 决策）；若 RBAC 受限，回退为在 `keycloak` 命名空间放一份 SealedSecret 副本
- **v1 仅交付 Keycloak 平台**：ArgoCD / Grafana / 9Router / OpenSandbox 的 OIDC 接入各开独立 PR，本仓库 `apps/9router/deployment.yaml` 等文件不修改
- **单副本 Keycloak**：滚动更新期间短暂不可用；多副本 + Infinispan 留作多节点扩展时
- **依赖 Keycloak Operator API 演进**：`KeycloakRealmImport.spec.users[].credentials[].valueFrom` 与 `clients[].secret.valueFrom` 是 26.x API；跨大版本可能变更；本仓库绑定 Keycloak 26.x 升级路径
- **依赖 Bitnami postgresql chart 维护活跃度**：[ADR-008](008-keycloak-platform.md) 中已分析