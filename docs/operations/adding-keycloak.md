# 添加 Keycloak

部署、密钥密封、升级与 OIDC 接入的操作手册。架构决策、备选方案与权衡见 [ADR-008](../adr/008-keycloak-platform.md)（PostgreSQL）与 [ADR-009](../adr/009-keycloak-platform.md)（Keycloak）。

## 已部署组件

Keycloak 26.8 + 平台 PostgreSQL 分三个同步波次，由 ArgoCD 通过 `apps/<name>/` 下的纯清单管理。

| 波次 | Application | 源目录 | 内容 |
|------|-------------|--------|---------|
| 0 | `keycloak-operator` | `apps/keycloak-operator/` | Keycloak Operator 26.8.0 + 4 个 CRD（`keycloaks.keycloak.org/v2alpha1`、`keycloakrealmimports`、`keycloakoidcclients`、`keycloaksamlclients`）|
| 1 | `platform-postgres` | `apps/postgres/` + `platform/postgres/` | Bitnami Helm chart 16.7.27（PG 17.6.0），`releaseName: keycloak-postgres` |
| 2 | `keycloak` | `apps/keycloak/` | `Keycloak` CR、`KeycloakRealmImport`、`Ingress`、`SealedSecret homelab-secrets` |

`apps/keycloak/keycloak-cr.yaml` 的 `db.host` 指向 `keycloak-postgres-postgresql.database.svc.cluster.local`（Bitnami chart 在 `releaseName` 后追加 `-postgresql`）。PostgreSQL 管理员/Keycloak 用户密码由 `apps/postgres/sealed-credentials.yaml` 中的 SealedSecret `postgres-credentials` 提供，Keycloak realm 凭据由 `apps/keycloak/sealed-secrets.yaml` 中的 `homelab-secrets` 提供。

## 首次部署

PR 1 不包含任何明文——ArgoCD 同步后：

- PostgreSQL Pod 启动，operator Pod 启动，Keycloak CR 处于 **Pending**（KeycloakRealmImport 的 `secretKeyRef` 解不到密文）。
- Ingress 等待 Keycloak 端点（`spec.ingressClassName: traefik`，cert-manager HTTP-01）。
- 一旦 `homelab-secrets` 与 `postgres-credentials` 完成密封并合入 `main`，operator 重启 Keycloak 调和循环，端到端联通。

`Keycloak` CR 未声明端点、Traefik Ingress 未拿到证书都属于**预期**的首次部署状态，不是审批问题。健康检查见下文 `验证` 一节。

### 封印 PostgreSQL 凭据

> 由合并 PR 的人执行。仅一次；推送到 `main` 后 ArgoCD 自动重新调和。

```bash
# 生成两个独立随机密码
PG_ADMIN_PW=$(openssl rand -base64 24)
PG_KC_PW=$(openssl rand -base64 24)
unset HISTFILE

kubectl create secret generic postgres-credentials \
  --namespace database \
  --from-literal=admin-password="$PG_ADMIN_PW" \
  --from-literal=keycloak-password="$PG_KC_PW" \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace kube-system --format yaml \
    > apps/postgres/sealed-credentials.yaml

unset PG_ADMIN_PW PG_KC_PW
git add apps/postgres/sealed-credentials.yaml
git commit -m "feat(postgres): seal postgres credentials"
git push
```

密封后 Bitnami chart 在首次启动 PostgreSQL 时把这两个密码作为初始凭据灌进 initdb。

### 封印 realm 凭据

5 个键——1 个管理员密码 + 4 个 OIDC 客户端密钥——写进 `homelab-secrets`：

```bash
KC_ADMIN_PW=$(openssl rand -base64 24)
ARG_CID=$(openssl rand -base64 32)
GRAF_CID=$(openssl rand -base64 32)
ROUTER_CID=$(openssl rand -base64 32)
SB_CID=$(openssl rand -base64 32)
unset HISTFILE

kubectl create secret generic homelab-secrets \
  --namespace keycloak \
  --from-literal=admin-password="$KC_ADMIN_PW" \
  --from-literal=argocd-client-secret="$ARG_CID" \
  --from-literal=grafana-client-secret="$GRAF_CID" \
  --from-literal=9router-client-secret="$ROUTER_CID" \
  --from-literal=opensandbox-client-secret="$SB_CID" \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace kube-system --format yaml \
    > apps/keycloak/sealed-secrets.yaml

unset KC_ADMIN_PW ARG_CID GRAF_CID ROUTER_CID SB_CID
git add apps/keycloak/sealed-secrets.yaml
git commit -m "feat(keycloak): seal realm credentials"
git push
```

SealedSecret 的 5 个键名必须与 `apps/keycloak/realm-import.yaml` 中 `users[].credentials[].valueFrom.secretKeyRef.key` 与 `clients[].secret.valueFrom.secretKeyRef.key` 完全一致。

### 验证

```bash
# PostgreSQL 就绪（Bitnami 在 initdb 后才允许客户端连接）
k3s kubectl get pods -n database -l app.kubernetes.io/name=postgresql
k3s kubectl exec -n database keycloak-postgres-postgresql-0 -- \
  psql -U postgres -tAc "SELECT 'pg up';"

# Operator 就绪
k3s kubectl get pods -n keycloak -l name=keycloak-operator

# Keycloak CR 已调和出 StatefulSet
k3s kubectl get keycloak -n keycloak keycloak
k3s kubectl get pods -n keycloak -l app=keycloak

# realm 导入完成
k3s kubectl logs -n keycloak -l app=keycloak --tail=200 | grep -E "(Realm homelab|Imported)"

# Ingress 证书已签发
k3s kubectl get certificate -n keycloak keycloak-tls

# 通过 HTTPS 调用 Keycloak
curl --fail https://keycloak.lab.csharpkit.com/realms/homelab/.well-known/openid-configuration
```

在 ArgoCD UI 中确认 `keycloak-operator`、`platform-postgres`、`keycloak` 三个 Application 全部变绿。Admin Console：<https://keycloak.lab.csharpkit.com/admin/master/console>，用 `homelab-admin` + 密封的 `admin-password` 登录。

## 资源使用

| 组件 | requests | limits |
|--------|---------|--------|
| keycloak-operator | 25m / 64Mi | 200m / 256Mi |
| postgres（primary）| 50m / 128Mi | 250m / 384Mi |
| keycloak | 200m / 384Mi | 500m / 768Mi |

合计约 33% CPU + 16% 内存（2 vCPU / 4 GB 节点预算）。Operator 与 Keycloak 启动时短暂尖峰会更高，需要 ArgoCD `IgnoreExtraneous` 或 `server-side apply` 容忍状态抖动。资源决策原因见 [ADR-009](../adr/009-keycloak-platform.md#资源精简)。

## 升级

### Keycloak Operator + Keycloak CR

1. `git fetch --tags` upstream `keycloak/keycloak-k8s-resources`。
2. `cd E:/GitHub/keycloak-k8s-resources && git checkout 26.Y.0`。
3. `kubectl kustomize kubernetes > app/k8s-resources/operator.yaml`。
4. 在 `homelab-patch/kustomization.yaml` 中调整镜像版本与资源 requests/limits。
5. 同步 `apps/keycloak/keycloak-cr.yaml` 中 `spec.image`（如需）、`features.enabled`、`db` 字段。
6. 推送到 `main`，ArgoCD 滚动升级。

不要在集群上手动 `kubectl apply` —— ArgoCD 会把它覆盖回去（参见 [ADR-009](../adr/009-keycloak-platform.md#gitops-渲染而非-helm-install)）。

### PostgreSQL

Bitnami chart 16.7.27 锁住 PG 17.6.0。升级到 chart 18.x（PG 18）需要：

1. 在本地跑 `helm dependency build platform/postgres/` 更新 `charts/`。
2. 修改 `platform/postgres/values.yaml` 的 `image.tag` 与 `auth.database.majorVersion`。
3. 推送到 `main`，ArgoCD 触发 StatefulSet 滚动重启；Bitnami chart 自动处理 `pg_upgrade` 步骤。

跨大版本升级（17 → 18）需要预先 dump/restore；详见 Bitnami chart README `Major version upgrade` 一节。

### realm / OIDC 客户端调整

`apps/keycloak/realm-import.yaml` 是一次性 `KeycloakRealmImport`。**直接改 realm CR 不会重导入**——Keycloak Operator 只在 realm CR 首次出现时执行 realm bootstrap。后续调整有两种路径：

1. **小改（增删客户端、调整 redirect URI）**：Admin Console UI 手改即可，realm 不需要重导入。
2. **大改（换 SSO 流程、撤换 realm 整体结构）**：删除现有 `KeycloakRealmImport` CR，让 operator 清理；然后提交新 realm CR。

不要在 cluster 上手跑 `kc.sh import`——它会与 ArgoCD 状态漂移。

## 轮换密钥

### realm 管理员密码 / OIDC 客户端密钥

```bash
# 重新生成并密封（同上"封印 realm 凭据"）
# 推送到 main，ArgoCD 重新调和 KeycloakRealmImport
k3s kubectl rollout restart statefulset/keycloak -n keycloak
```

注意：`KeycloakRealmImport` 不会刷新已存在的用户/客户端——只更新密钥值。推荐在 Admin Console 中删除原 `homelab-admin` 用户与同名客户端后再触发 reconcile，确保凭据真正轮换。

### PostgreSQL 密码

```bash
# 在 apps/postgres/sealed-credentials.yaml 中替换明文 → 重新密封 → 推送
k3s kubectl rollout restart statefulset/keycloak-postgres-postgresql -n database
k3s kubectl rollout restart statefulset/keycloak -n keycloak
```

PostgreSQL 密码更新后，Keycloak 也必须重启——它的连接池在启动时建立，运行时不重读 `db.password`。

## 排错

| 症状 | 原因 | 处理 |
|------|------|------|
| `Keycloak` CR 一直 `Pending` | SealedSecret 密文未合入 | 检查 `homelab-secrets` 与 `postgres-credentials` 的 `encryptedData` 是否非空 |
| Keycloak Pod `CrashLoopBackOff`，事件 `db connection refused` | PostgreSQL 还没就绪 / 密码不匹配 | 检查 `database` 命名空间下 Pod；`k3s kubectl exec` 进 PG 手动 `psql -U keycloak` 验证 |
| `cert-manager` `Certificate not ready` | HTTP-01 校验失败 | 检查 `keycloak.lab.csharpkit.com` DNS 是否解析到 Traefik；`k3s kubectl logs -n cert-manager -l app=cert-manager` |
| 客户端收到 `invalid_client_secret` | SealedSecret 字段名不匹配 | 核对 `realm-import.yaml` 中 `secretKeyRef.key` 与 SealedSecret `encryptedData` 键名 |

## 已知遗留项

- 仅交付 Keycloak 平台，**ArgoCD / Grafana / 9Router / OpenSandbox 接入 OIDC 留到各自 PR**。
- Keycloak 升级时 operator 26.8.0 可能需要显式 `spec.image` 字段；目前依赖 chart 默认镜像版本（`quay.io/keycloak/keycloak:26.8.0`），跟 operator 同号。
- Bitnami chart 16.7.27 钉的是 PG 17.6.0，**不是原计划的 PG 18**——chart 18.x OCI 仓库在当前网络下不可达（详见 [ADR-008](../adr/008-keycloak-platform.md#备选方案)）。