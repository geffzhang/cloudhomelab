# Keycloak 26.8 平台部署实施计划

> **给 agentic 执行者说明：** 必须使用的子技能：superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 来逐任务执行。步骤使用 checkbox（`- [ ]`）语法跟踪。

**目标：** 在 2 vCPU / 4 GB 节点上以 GitOps 方式部署 Keycloak 26.8（Operator 模式）+ 独立 PostgreSQL 18 平台组件，为 ArgoCD / Grafana / 9Router / OpenSandbox 提供 OIDC 认证服务。

**架构：** 渲染上游 `keycloak-keycloak-k8s-resources` 的 Keycloak Operator chart 至 `apps/keycloak-operator/`（wave 0，提供 Keycloak/KeycloakRealmImport CRD）；用 Bitnami postgresql Helm chart 16.x（PG 18）作 `platform-postgres`（wave 1）；Keycloak CR + KeycloakRealmImport CR + Ingress 作 `platform-keycloak`（wave 2）；三个 SealedSecret 收纳 admin / client / postgres 凭证。两段 PR：先合并清单（SealedSecret 占位），再合并加密数据。

**技术栈：** Keycloak Operator 26.x、Keycloak 26.8 server、Bitnami postgresql Helm chart 16.x、PostgreSQL 18、Traefik、cert-manager、sealed-secrets、ArgoCD App-of-Apps。

**Spec：** [docs/superpowers/specs/2026-10-06-keycloak-platform-design.md](../specs/2026-10-06-keycloak-platform-design.md)

## 全局约束

- 节点配置：2 vCPU / 4 GB（参见 `docs/architecture/overview.md` 与 `docs/operations/argocd-resource-limits.md`）
- 所有 `kubectl` 命令使用 `k3s kubectl`（参见 `bootstrap/install.sh`），Windows Git Bash 下应使用正斜杠路径
- 所有 SealedSecret 使用同一集群密钥加密（kubeseal 默认 controller-namespace=kube-system）
- 明文 secret 仅经 stdin/stdout 流入 `kubeseal`，不在 `/tmp` 落地，`unset HISTFILE` + `unset <VAR>` 防泄漏
- Keycloak Operator CRD 字段（`spec.proxy.edgeHeaders`、`spec.http.tls.enabled`、`spec.clients[].secret.valueFrom.secretKeyRef`）落地前用 `kubectl explain` 对照实际 CRD；operator 版本与 Keycloak server 版本必须严格对齐（26.8 ↔ 26.8）
- chart 版本一律 pin 到具体 tag（参考 `argocd/platform-monitoring.yaml`、`platform-logging.yaml` 既有写法）

---

## 文件清单（全部新建）

```
platform/config/namespaces.yaml                 # 修改：新增 database + keycloak 条目
apps/keycloak-operator/operator.yaml           # 渲染自上游 chart 源（operator + CRDs）
argocd/platform-keycloak-operator.yaml         # wave 0, ServerSideApply=true
apps/postgres/sealed-credentials.yaml          # 占位 SealedSecret（PR 1）
platform/postgres/values.yaml                  # Bitnami chart values（PG 18、local-path 1Gi）
argocd/platform-postgres.yaml                  # wave 1, multi-source Helm
apps/keycloak/keycloak-cr.yaml                 # Keycloak CR
apps/keycloak/realm-import.yaml                # KeycloakRealmImport CR（homelab + 4 客户端 + admin）
apps/keycloak/ingress.yaml                     # Traefik Ingress → keycloak.lab.csharpkit.com
apps/keycloak/sealed-secrets.yaml              # 占位 SealedSecret（PR 1）
argocd/platform-keycloak.yaml                  # wave 2
docs/operations/adding-keycloak.md             # 部署/封印/验证手册
docs/adr/008-keycloak-platform.md              # 设计决策记录
```

---

### Task 1：扩展命名空间清单

**文件：**
- 修改：`platform/config/namespaces.yaml`

**目的：** 让 `database` 与 `keycloak` 命名空间带上 `homelab.csharpkit.com/description` 注解与 `argocd.argoproj.io/sync-options: Prune=false`，受 `platform-config`（wave 1）保护。

- [ ] **Step 1：在文件末尾追加两个 Namespace 资源**

打开 `platform/config/namespaces.yaml`，在最后一个 `---` 分隔符之后追加：

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: database
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
    homelab.csharpkit.com/description: >-
      Shared platform PostgreSQL 18 (Bitnami chart). Hosts databases/users
      consumed by platform apps; first consumer is the Keycloak `keycloak`
      database/user.
  labels:
    app.kubernetes.io/part-of: homelab
---
apiVersion: v1
kind: Namespace
metadata:
  name: keycloak
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
    homelab.csharpkit.com/description: >-
      Keycloak 26.8 OIDC identity provider (operator-managed). Hosts the
      Keycloak server StatefulSet and the `homelab` realm import. Public
      admin console at keycloak.lab.csharpkit.com.
  labels:
    app.kubernetes.io/part-of: homelab
```

- [ ] **Step 2：验证 YAML 结构**

```bash
cd e:/GitHub/cloudhomelab
yq eval 'document_index' platform/config/namespaces.yaml | wc -l
```

期望：8（原有 6 个 + 新增 2 个）。`yq` 未安装时改用 Python：

```bash
python -c "import yaml,sys;print(len(list(yaml.safe_load_all(open('platform/config/namespaces.yaml')))))"
```

- [ ] **Step 3：本地 dry-run（不连集群）**

```bash
k3s kubectl apply --dry-run=client -f platform/config/namespaces.yaml
```

期望：两个 `namespace/database`、`namespace/keycloak` 行，无报错。

- [ ] **Step 4：提交**

```bash
git add platform/config/namespaces.yaml
git commit -m "feat(namespaces): add database and keycloak namespace annotations"
```

---

### Task 2：渲染 Keycloak Operator

**文件：**
- 创建：`apps/keycloak-operator/operator.yaml`

**目的：** 把上游 `keycloak/keycloak-k8s-resources` 仓库的 operator chart 用 `helm template` 渲染到本仓库，server-side apply 走 ArgoCD。Operator 在此提供 Keycloak / KeycloakRealmImport / Client 等 CRD，是 wave 0 的理由。

- [ ] **Step 1：克隆上游并切到 26.8 tag**

```bash
if [ ! -d "E:/GitHub/keycloak-k8s-resources" ]; then
  git clone https://github.com/keycloak/keycloak-k8s-resources "E:/GitHub/keycloak-k8s-resources"
fi
cd "E:/GitHub/keycloak-k8s-resources"
git fetch --tags
LATEST=$(git tag --sort=-version:refname | grep '^26\.8' | head -1)
git checkout "$LATEST"
echo "checked out $LATEST"
```

期望：终端打印形如 `checked out 26.8.0` 的 tag。若仓库无 26.8 tag，`grep` 无输出，停在 HEAD；回退方案用最新 ≥26.8 的 `26.x` tag。

- [ ] **Step 2：写入覆盖 values**

在 `E:/GitHub/keycloak-k8s-resources/kubernetes/charts/keycloak-operator/` 下创建临时覆盖文件 `values-homelab.yaml`：

```yaml
# values-homelab.yaml
operator:
  replicas: 1
  resources:
    requests: { cpu: 25m, memory: 64Mi }
    limits:   { cpu: 200m, memory: 256Mi }
```

> chart 字段名以 `kubectl explain keycloak-operator-operator` 为准；本计划假定 `operator.*` 顶层 key。落地时按 chart values 实际定义调整。

- [ ] **Step 3：渲染到本仓库**

```bash
cd "E:/GitHub/keycloak-k8s-resources"
helm template keycloak-operator kubernetes/charts/keycloak-operator \
  -n keycloak \
  --include-crds \
  -f values-homelab.yaml \
  > "E:/GitHub/cloudhomelab/apps/keycloak-operator/operator.yaml"
wc -l "E:/GitHub/cloudhomelab/apps/keycloak-operator/operator.yaml"
```

期望：文件长度 ≥ 200 行（含 CRDs）。若 `helm template` 报错 `field operator not found`，把 `--include-crds` 单独验证后调整 values key。

- [ ] **Step 4：基础 dry-run**

```bash
cd e:/GitHub/cloudhomelab
k3s kubectl apply --dry-run=client -f apps/keycloak-operator/operator.yaml 2>&1 | tail -30
```

期望：所有资源 `configured` 字样，无 `error`。CRDs 可能触发 `metadata.annotations: Too long`，属正常，本计划稍后用 ServerSideApply 解决。

- [ ] **Step 5：精简文件头**

```bash
head -1 "E:/GitHub/cloudhomelab/apps/keycloak-operator/operator.yaml"
```

若首行非 `---`，追加一个 `---` 让多文档流合法：

```bash
# 仅在缺失时执行
sed -i '1i ---' "E:/GitHub/cloudhomelab/apps/keycloak-operator/operator.yaml"
```

- [ ] **Step 6：提交**

```bash
git add apps/keycloak-operator/operator.yaml
git commit -m "feat(keycloak): render Keycloak Operator 26.8 chart"
```

---

### Task 3：创建 keycloak-operator ArgoCD Application

**文件：**
- 创建：`argocd/platform-keycloak-operator.yaml`

**目的：** 让 root app-of-apps 把 operator 纳入管理，sync-wave 0，ServerSideApply 走 CRD 大文件。

- [ ] **Step 1：写入 Application 清单**

```yaml
---
# Keycloak 26.8 Operator. Wave 0 alongside cert-manager, sealed-secrets,
# opensandbox: the operator only ships Keycloak/RealmImport/Client CRDs and
# its controller pod, nothing else in the cluster depends on app-layer
# workloads. CRDs trigger the client-side `last-applied-configuration`
# annotation limit, so ServerSideApply is required.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: keycloak-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://github.com/geffzhang/cloudhomelab
    targetRevision: main
    path: apps/keycloak-operator
  destination:
    server: https://kubernetes.default.svc
    namespace: keycloak
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2：YAML 结构验证**

```bash
cd e:/GitHub/cloudhomelab
python -c "import yaml;d=yaml.safe_load(open('argocd/platform-keycloak-operator.yaml'));print(d['kind'],d['metadata']['name'])"
```

期望：`Application keycloak-operator`。

- [ ] **Step 3：提交**

```bash
git add argocd/platform-keycloak-operator.yaml
git commit -m "feat(argocd): add keycloak-operator Application (wave 0)"
```

---

### Task 4：Postgres 命名空间占位与 SealedSecret 占位

**文件：**
- 创建：`apps/postgres/sealed-credentials.yaml`

**目的：** 占位 SealedSecret，PR 1 时仅元数据，PR 2 时由用户封印真实值。

- [ ] **Step 1：写入 SealedSecret 占位**

```yaml
---
# SealedSecret placeholder for the shared PostgreSQL 18 platform service.
# Encrypted data is filled in during the second PR (see
# docs/operations/adding-keycloak.md#sealing-the-credentials). Without
# this file existing, Bitnami's existingSecret lookup fails and the
# chart auto-generates throwaway passwords; the Keycloak CR's
# secretKeyRef then resolves once encrypted data lands.
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: postgres-credentials
  namespace: database
spec:
  encryptedData: {}
  template:
    metadata:
      name: postgres-credentials
      namespace: database
```

- [ ] **Step 2：YAML 验证**

```bash
cd e:/GitHub/cloudhomelab
python -c "import yaml;d=yaml.safe_load(open('apps/postgres/sealed-credentials.yaml'));print(d['spec']['template']['metadata']['namespace'])"
```

期望：`database`。

- [ ] **Step 3：提交**

```bash
git add apps/postgres/sealed-credentials.yaml
git commit -m "feat(postgres): add postgres-credentials SealedSecret placeholder"
```

---

### Task 5：PostgreSQL 18 chart values

**文件：**
- 创建：`platform/postgres/values.yaml`

**目的：** 把 Bitnami postgresql chart 配置成 PG 18 + local-path 1Gi + 单节点资源 + 通过 `existingSecret` 读取密钥。

- [ ] **Step 1：写入 values**

```yaml
# platform/postgres/values.yaml
# Bitnami postgresql chart, pinned to a 16.x release that supports
# PostgreSQL 18. Single primary, no replication. SealedSecret supplies
# the admin + application passwords (apps/postgres/sealed-credentials.yaml).
global:
  postgresql:
    image:
      tag: 18.0.0
    auth:
      existingSecret: postgres-credentials
      secretKeys:
        adminPasswordKey: admin-password
        userPasswordKey: keycloak-password
      username: keycloak
      database: keycloak
      enablePostgresUser: true
primary:
  persistence:
    size: 1Gi
    storageClass: local-path
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits:   { cpu: 250m, memory: 384Mi }
metrics:
  enabled: false
```

> 若 chart 16.x 版本 `global.postgresql.image.tag` 字段不存在，把 image tag 移到 `image.tag` 顶层，按 `helm show values bitnami/postgresql --version 16.x` 实际定义调整。

- [ ] **Step 2：chart 渲染 dry-run**

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
CHART_VER=$(helm search repo bitnami/postgresql --versions --regexp '^16\.' | head -1 | awk '{print $2}')
helm template keycloak-postgres bitnami/postgresql \
  --version "$CHART_VER" \
  -n database \
  -f e:/GitHub/cloudhomelab/platform/postgres/values.yaml \
  > /tmp/postgres-rendered.yaml
echo "rendered $(wc -l < /tmp/postgres-rendered.yaml) lines with chart $CHART_VER"
```

期望：渲染 ≥ 200 行且无 `Error` 字样。把 `$CHART_VER` 实际值记下，Task 6 钉版本用。

- [ ] **Step 3：本地 dry-run**

```bash
k3s kubectl apply --dry-run=client -f /tmp/postgres-rendered.yaml 2>&1 | tail -20
```

期望：每个资源 `configured`，无 `error`。`local-path` StorageClass 在目标集群存在（k3s 默认带），否则 PVC 报 `storageClass not found`，不影响 dry-run 客户端校验。

- [ ] **Step 4：清理临时**

```bash
rm /tmp/postgres-rendered.yaml
```

- [ ] **Step 5：提交**

```bash
git add platform/postgres/values.yaml
git commit -m "feat(postgres): Bitnami postgresql values for PG 18"
```

---

### Task 6：创建 platform-postgres ArgoCD Application

**文件：**
- 创建：`argocd/platform-postgres.yaml`

**目的：** 多源 Helm Application（chart + 仓库 values），sync-wave 1。

- [ ] **Step 1：写入 Application 清单**

```yaml
---
# Shared platform PostgreSQL 18. Wave 1: needs no CRDs, but Keycloak
# (wave 2) depends on this being Ready. Multi-source mirrors the
# monitoring/logging pattern: chart from Bitnami, values from this repo.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-postgres
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  sources:
    - repoURL: https://charts.bitnami.com/bitnami
      chart: postgresql
      targetRevision: 16.7.4 # TODO: pin to actual latest 16.x after chart release check
      helm:
        releaseName: keycloak-postgres
        valueFiles:
          - $values/platform/postgres/values.yaml
    - repoURL: https://github.com/geffzhang/cloudhomelab
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: database
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2：把 `targetRevision` 改成 Task 5 Step 2 实际拿到的版本**

```bash
# 已在 Step 1 写入占位版本；按实际 helm search 输出替换 16.7.4
```

- [ ] **Step 3：YAML 结构验证**

```bash
cd e:/GitHub/cloudhomelab
python -c "import yaml;d=yaml.safe_load(open('argocd/platform-postgres.yaml'));print(d['metadata']['name'],d['spec']['sources'][0]['chart'],d['spec']['sources'][0]['targetRevision'])"
```

期望：`platform-postgres postgresql 16.x.x`。

- [ ] **Step 4：提交**

```bash
git add argocd/platform-postgres.yaml
git commit -m "feat(argocd): add platform-postgres Application (wave 1)"
```

---

### Task 7：Keycloak CR

**文件：**
- 创建：`apps/keycloak/keycloak-cr.yaml`

**目的：** operator 协调后启动 Keycloak StatefulSet，对接 PostgreSQL、配置 hostname 与代理信任。

- [ ] **Step 1：写入 Keycloak CR**

```yaml
---
# Keycloak 26.8 instance. Reconciles a single StatefulSet; the operator
# fills the rest (Service, ServiceMonitor opt-in, etc.). host +
# proxy + http.tls are the Traefik passthrough config: Traefik
# terminates TLS, forwards plain HTTP, Keycloak trusts X-Forwarded-*.
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak
  namespace: keycloak
spec:
  instances: 1
  hostname:
    hostname: keycloak.lab.csharpkit.com
    admin:    keycloak.lab.csharpkit.com
    strict:   false
  proxy:
    edgeHeaders: true
  features:
    enabled:
      - persistent-user-sessions
  db:
    vendor: postgres
    host: keycloak-postgres.database.svc.cluster.local
    port: 5432
    database: keycloak
    username: keycloak
    password:
      valueFrom:
        secretKeyRef:
          name: postgres-credentials
          key: keycloak-password
  http:
    tls:
      enabled: false
  resources:
    requests: { cpu: 200m, memory: 384Mi }
    limits:   { cpu: 500m, memory: 768Mi }
```

> 字段名以 `kubectl explain k8s.keycloak.org/v2alpha1.Keycloak.spec` 输出为准；若 `proxy.edgeHeaders` 或 `http.tls.enabled` 不存在，对照 `kubectl explain k8s.keycloak.org/v2alpha1.Keycloak.spec.proxy` 与 `...http` 调整。

- [ ] **Step 2：dry-run（CRD 未装则跳过）**

```bash
cd e:/GitHub/cloudhomelab
k3s kubectl apply --dry-run=client -f apps/keycloak/keycloak-cr.yaml 2>&1 | tail -10
```

期望：无 `no matches for kind` 错误即视为 CRD 已存在（集群已部署过 operator）；若报 `no matches`，属预期，本计划后续由 ArgoCD 走 server-side apply 安装 CRD 后再校验。

- [ ] **Step 3：提交**

```bash
git add apps/keycloak/keycloak-cr.yaml
git commit -m "feat(keycloak): Keycloak CR"
```

---

### Task 8：KeycloakRealmImport CR

**文件：**
- 创建：`apps/keycloak/realm-import.yaml`

**目的：** 一次性导入 `homelab` realm 与 4 个 OIDC 客户端（argocd、grafana、9router、opensandbox），未来每个应用接入 OIDC 时直接用已存在的 client。

- [ ] **Step 1：写入 RealmImport CR**

```yaml
---
# One-shot realm import: creates the `homelab` realm, the
# `homelab-admin` user with realm-admin role, and four OIDC
# clients (argocd / grafana / 9router / opensandbox). Each client is
# confidential with a sealed secret; admin password is sealed too.
apiVersion: k8s.keycloak.org/v2alpha1
kind: KeycloakRealmImport
metadata:
  name: homelab
  namespace: keycloak
spec:
  realm:
    realm: homelab
    enabled: true
    sslRequired: external
    registrationAllowed: false
    loginWithEmailAllowed: true
    rememberMe: true
    internationalizationEnabled: false
    ssoSessionIdleTimeout: 28800
    accessTokenLifespan: 1800
  users:
    - username: homelab-admin
      enabled: true
      emailVerified: true
      realmRoles:
        - realm-admin
      credentials:
        - type: password
          valueFrom:
            secretKeyRef:
              name: homelab-secrets
              key: admin-password
  clients:
    - clientId: argocd
      enabled: true
      publicClient: false
      standardFlowEnabled: true
      directAccessGrantsEnabled: false
      rootUrl: https://argo.lab.csharpkit.com
      baseUrl: /
      redirectUris:
        - https://argo.lab.csharpkit.com/auth/callback
      webOrigins:
        - https://argo.lab.csharpkit.com
      secret:
        valueFrom:
          secretKeyRef:
            name: homelab-secrets
            key: argocd-client-secret

    - clientId: grafana
      enabled: true
      publicClient: false
      standardFlowEnabled: true
      directAccessGrantsEnabled: false
      rootUrl: https://grafana.lab.csharpkit.com
      baseUrl: /
      redirectUris:
        - https://grafana.lab.csharpkit.com/login/generic_oauth
      webOrigins:
        - https://grafana.lab.csharpkit.com
      secret:
        valueFrom:
          secretKeyRef:
            name: homelab-secrets
            key: grafana-client-secret

    - clientId: 9router
      enabled: true
      publicClient: false
      standardFlowEnabled: true
      directAccessGrantsEnabled: false
      rootUrl: https://9router.lab.csharpkit.com
      baseUrl: /
      redirectUris:
        - https://9router.lab.csharpkit.com/auth/callback
      webOrigins:
        - https://9router.lab.csharpkit.com
      secret:
        valueFrom:
          secretKeyRef:
            name: homelab-secrets
            key: 9router-client-secret

    - clientId: opensandbox
      enabled: true
      publicClient: false
      standardFlowEnabled: true
      directAccessGrantsEnabled: false
      rootUrl: https://sandbox.lab.csharpkit.com
      baseUrl: /
      redirectUris:
        - https://sandbox.lab.csharpkit.com/auth/callback
      webOrigins:
        - https://sandbox.lab.csharpkit.com
      secret:
        valueFrom:
          secretKeyRef:
            name: homelab-secrets
            key: opensandbox-client-secret
```

> `users[].credentials[].valueFrom.secretKeyRef` 与 `clients[].secret.valueFrom.secretKeyRef` 是 Keycloak 26.x operator API。落地前用 `kubectl explain k8s.keycloak.org/v2alpha1.KeycloakRealmImport.spec.users.credentials.value` 与 `...clients.secret` 验证字段定义；若 API 仅支持明文字符串，回退为「operator 自动生成 + 后续 PR 提取 Secret 配置应用」模式。

- [ ] **Step 2：dry-run（CRD 未装可跳过）**

```bash
cd e:/GitHub/cloudhomelab
k3s kubectl apply --dry-run=client -f apps/keycloak/realm-import.yaml 2>&1 | tail -10
```

期望：无 schema 错误。

- [ ] **Step 3：提交**

```bash
git add apps/keycloak/realm-import.yaml
git commit -m "feat(keycloak): homelab realm + 4 OIDC clients"
```

---

### Task 9：Keycloak Ingress

**文件：**
- 创建：`apps/keycloak/ingress.yaml`

**目的：** Traefik 终止 TLS，HTTP 后端转发到 Keycloak 8080；cert-manager HTTP-01 自动签发 `keycloak.lab.csharpkit.com` 证书。

- [ ] **Step 1：写入 Ingress**

```yaml
---
# Public route to Keycloak. Traefik terminates TLS via the
# letsencrypt-prod ClusterIssuer; the upstream is plain HTTP on
# port 8080 (Keycloak trusts the X-Forwarded-* headers from
# Traefik per spec.proxy.edgeHeaders). sync-wave 5 so the
# Ingress waits for the Keycloak CR to be reconciled first.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak
  namespace: keycloak
  annotations:
    argocd.argoproj.io/sync-wave: "5"
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: traefik
  rules:
    - host: keycloak.lab.csharpkit.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: keycloak
                port:
                  number: 8080
  tls:
    - hosts: [keycloak.lab.csharpkit.com]
      secretName: keycloak-tls
```

- [ ] **Step 2：dry-run**

```bash
cd e:/GitHub/cloudhomelab
k3s kubectl apply --dry-run=client -f apps/keycloak/ingress.yaml
```

期望：`ingress.networking.k8s.io/keycloak configured`。

- [ ] **Step 3：提交**

```bash
git add apps/keycloak/ingress.yaml
git commit -m "feat(keycloak): Traefik ingress for keycloak.lab.csharpkit.com"
```

---

### Task 10：homelab-secrets SealedSecret 占位

**文件：**
- 创建：`apps/keycloak/sealed-secrets.yaml`

**目的：** RealmImport 引用的 SealedSecret 占位。PR 2 时由用户封印 5 个 key。

- [ ] **Step 1：写入 SealedSecret 占位**

```yaml
---
# SealedSecret placeholder for Keycloak realm credentials. Encrypted
# data is filled in by the user during PR 2 (see
# docs/operations/adding-keycloak.md#sealing-the-credentials).
# KeycloakRealmImport CR's users[].credentials[].valueFrom.secretKeyRef
# and clients[].secret.valueFrom.secretKeyRef resolve only after the
# encrypted data lands; operator retries until then.
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: homelab-secrets
  namespace: keycloak
spec:
  encryptedData: {}
  template:
    metadata:
      name: homelab-secrets
      namespace: keycloak
```

- [ ] **Step 2：YAML 验证**

```bash
cd e:/GitHub/cloudhomelab
python -c "import yaml;d=yaml.safe_load(open('apps/keycloak/sealed-secrets.yaml'));print(d['spec']['template']['metadata']['namespace'])"
```

期望：`keycloak`。

- [ ] **Step 3：提交**

```bash
git add apps/keycloak/sealed-secrets.yaml
git commit -m "feat(keycloak): add homelab-secrets SealedSecret placeholder"
```

---

### Task 11：创建 platform-keycloak ArgoCD Application

**文件：**
- 创建：`argocd/platform-keycloak.yaml`

**目的：** 把 Keycloak CR / RealmImport / Ingress / SealedSecret 纳入 ArgoCD 管理，sync-wave 2。

- [ ] **Step 1：写入 Application 清单**

```yaml
---
# Keycloak 26.8 instance: Keycloak CR + KeycloakRealmImport + Ingress.
# Wave 2: depends on keycloak-operator (wave 0, CRDs) and
# platform-postgres (wave 1, database). SealedSecret in this same
# path triggers operator reconciliation; realm import is idempotent
# and re-runs once encrypted data lands in PR 2.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: keycloak
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  source:
    repoURL: https://github.com/geffzhang/cloudhomelab
    targetRevision: main
    path: apps/keycloak
  destination:
    server: https://kubernetes.default.svc
    namespace: keycloak
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2：YAML 结构验证**

```bash
cd e:/GitHub/cloudhomelab
python -c "import yaml;d=yaml.safe_load(open('argocd/platform-keycloak.yaml'));print(d['kind'],d['metadata']['name'],d['spec']['destination']['namespace'])"
```

期望：`Application keycloak keycloak`。

- [ ] **Step 3：提交**

```bash
git add argocd/platform-keycloak.yaml
git commit -m "feat(argocd): add keycloak Application (wave 2)"
```

---

### Task 12：操作手册 docs/operations/adding-keycloak.md

**文件：**
- 创建：`docs/operations/adding-keycloak.md`

**目的：** 部署步骤、PR 2 封印命令、验证清单全部收录；后续 onboarding / 故障排查直接看本文。

- [ ] **Step 1：写入操作手册**

```markdown
# 添加 Keycloak 26.8 平台

部署、密钥封印、升级与故障排查手册。设计决策与备选方案见 [ADR-008](../adr/008-keycloak-platform.md)。

## 已部署组件

| 文件 | 内容 |
|------|------|
| `apps/keycloak-operator/operator.yaml` | 渲染自 keycloak/keycloak-k8s-resources 26.8；含 Namespace、CRDs（Keycloak / KeycloakRealmImport / Client 等）、operator Deployment、ServiceAccount、ClusterRole(Binding) |
| `apps/postgres/sealed-credentials.yaml` | SealedSecret：postgres 超级用户密码 + keycloak 应用用户密码 |
| `platform/postgres/values.yaml` | Bitnami postgresql chart 16.x values（PG 18、local-path 1Gi、existingSecret） |
| `apps/keycloak/keycloak-cr.yaml` | `Keycloak` CR：hostname / proxy / db（secretKeyRef）/ http.tls |
| `apps/keycloak/realm-import.yaml` | `KeycloakRealmImport` CR：`homelab` realm + 4 个 OIDC 客户端 + `homelab-admin` |
| `apps/keycloak/sealed-secrets.yaml` | SealedSecret：realm admin + 4 client secret |
| `apps/keycloak/ingress.yaml` | Traefik Ingress：`keycloak.lab.csharpkit.com` → `keycloak:8080` |
| `argocd/platform-keycloak-operator.yaml` | wave 0，ServerSideApply=true |
| `argocd/platform-postgres.yaml` | wave 1，multi-source Helm |
| `argocd/platform-keycloak.yaml` | wave 2 |

## 首次部署（两段 PR）

PR 1 合并后，ArgoCD 同步三个 Application。Keycloak pod 会启动但没有 `homelab` realm、没有 admin；用户登录 `https://keycloak.lab.csharpkit.com/admin/master/console/` 提示 realm 不存在，属预期。

### 封印凭证（PR 2）

在能访问集群的机器上（默认 `~/.kube/config` 指向本集群，或者直接 SSH 到节点用 `k3s kubectl`）：

```bash
export K3S_CMD="k3s kubectl"

# Postgres 凭证
PG_ADMIN=$(openssl rand -base64 24)
PG_KC=$(openssl rand -base64 24)
unset HISTFILE
$K3S_CMD create secret generic postgres-credentials -n database \
  --from-literal=admin-password="$PG_ADMIN" \
  --from-literal=keycloak-password="$PG_KC" \
  --dry-run=client -o yaml | kubeseal --controller-namespace kube-system --format yaml \
  > apps/postgres/sealed-credentials.yaml
unset PG_ADMIN PG_KC

# Realm 凭证（5 个 key）
KC_ADMIN=$(openssl rand -base64 24)
ARGOCD_SECRET=$(openssl rand -base64 32)
GRAFANA_SECRET=$(openssl rand -base64 32)
ROUTER_SECRET=$(openssl rand -base64 32)
SANDBOX_SECRET=$(openssl rand -base64 32)
unset HISTFILE
$K3S_CMD create secret generic homelab-secrets -n keycloak \
  --from-literal=admin-password="$KC_ADMIN" \
  --from-literal=argocd-client-secret="$ARGOCD_SECRET" \
  --from-literal=grafana-client-secret="$GRAFANA_SECRET" \
  --from-literal=9router-client-secret="$ROUTER_SECRET" \
  --from-literal=opensandbox-client-secret="$SANDBOX_SECRET" \
  --dry-run=client -o yaml | kubeseal --controller-namespace kube-system --format yaml \
  > apps/keycloak/sealed-secrets.yaml
unset KC_ADMIN ARGOCD_SECRET GRAFANA_SECRET ROUTER_SECRET SANDBOX_SECRET

git add apps/postgres/sealed-credentials.yaml apps/keycloak/sealed-secrets.yaml
git commit -m "feat(keycloak): seal bootstrap credentials"
git push
```

PR 2 合并后 ArgoCD 重新协调，Bitnami 检测到 `existingSecret` 变化滚动 PostgreSQL StatefulSet；Keycloak operator 检测到 SealedSecret 解密完成后导入 realm。

## 验证

```bash
export K3S_CMD="k3s kubectl"

$K3S_CMD -n keycloak get deploy keycloak-operator
$K3S_CMD get crd | grep keycloak
$K3S_CMD -n database get sts keycloak-postgres
$K3S_CMD -n keycloak get sts keycloak
$K3S_CMD -n keycloak wait --for=condition=Ready pod -l app=keycloak --timeout=300s
$K3S_CMD -n keycloak get keycloakrealmimport homelab
$K3S_CMD -n keycloak get certificate keycloak-tls

curl --fail https://keycloak.lab.csharpkit.com/realms/homelab/.well-known/openid-configuration
curl --fail -o /dev/null -w '%{http_code}\n' https://keycloak.lab.csharpkit.com/admin/master/console/
```

ArgoCD UI 中 `keycloak`、`keycloak-operator`、`platform-postgres` 三个 Application 全部 Healthy/Synced。

## 升级 Keycloak

1. `cd E:/GitHub/keycloak-k8s-resources && git fetch --tags && git checkout 26.x.y`（替换 26.x.y 为新关键版本）
2. 查看 release notes；重点关注 CRD 字段名变化与 operator API 调整
3. 在本仓库覆盖 `apps/keycloak-operator/operator.yaml`：
   ```bash
   helm template keycloak-operator kubernetes/charts/keycloak-operator \
     -n keycloak --include-crds -f values-homelab.yaml \
     > E:/GitHub/cloudhomelab/apps/keycloak-operator/operator.yaml
   ```
4. 推送，ArgoCD 应用；monitor `keycloak-operator` Deployment rollout

## 升级 PostgreSQL

编辑 `argocd/platform-postgres.yaml` 的 `targetRevision`，按 Bitnami release notes 检查 values 字段变化，必要时同步更新 `platform/postgres/values.yaml`。

## 故障排查

| 症状 | 排查 |
|------|------|
| Keycloak pod CrashLoopBackOff | `kubectl describe sts keycloak -n keycloak` 查看 Events；多半是 `homelab-secrets` SealedSecret 尚未封印，operator 等数据 |
| realm 未导入 | `kubectl logs -n keycloak -l app=keycloak --tail=200 \| grep -i 'realm'`；多半是 SealedSecret `encryptedData: {}` 未填 |
| PostgreSQL 未 Ready | `kubectl describe sts keycloak-postgres -n database`；若是 `existingSecret not found`，确认 `apps/postgres/sealed-credentials.yaml` 已 push |
| admin console 500 | 检查 `Keycloak.spec.hostname.strict` 是否为 false；false 时 Traefik 转发的 `X-Forwarded-Proto` 应为 https |

## 已知遗留项

- 单副本 Keycloak：滚动更新期间短暂不可用；多副本 + Infinispan 留作多节点扩展时
- master realm admin 未单独设置：当前所有 admin 操作走 `homelab` realm；多 realm 时再加
- 客户端 secret 静态：未来切到 federation（26.x 支持）可消除每个客户端 secret 的管理负担
```

- [ ] **Step 2：交叉链接检查**

```bash
cd e:/GitHub/cloudhomelab
grep -n 'ADR-008\|adding-keycloak' docs/operations/adding-keycloak.md
```

期望：开头一段引用 `ADR-008`，文件名一致。

- [ ] **Step 3：提交**

```bash
git add docs/operations/adding-keycloak.md
git commit -m "docs: add adding-keycloak.md runbook"
```

---

### Task 13：ADR-008

**文件：**
- 创建：`docs/adr/008-keycloak-platform.md`

**目的：** 把关键设计决策落到 ADR，参考 ADR-007 写法。

- [ ] **Step 1：写入 ADR**

```markdown
# ADR-008：引入 Keycloak 26.8 作为平台 OIDC 认证服务

**状态：** 已接受 · **日期：** 2026-10-06

## 背景

集群当前没有 OIDC：9Router 用 PVC 上的 API key、Grafana 用密封 Secret 的 admin 账号、ArgoCD `dex --replicas=0` 关闭 SSO、OpenSandbox 同 9Router。引入 Keycloak 把身份层从「每个应用一套」变为「一个 realm、统一用户库、各应用 OIDC 客户端」。详见 [设计文档](../superpowers/specs/2026-10-06-keycloak-platform-design.md)。

## 决策

### Keycloak Operator 模式

Keycloak 26.x 上游不发布官方 Helm chart。可选 codecentric/keycloakx（社区 Helm）、Bitnami chart（社区维护 Bitnami 镜像），均为社区产物。Keycloak 官方推荐路径是 Keycloak Operator + `Keycloak` / `KeycloakRealmImport` CR。本仓库选 Operator 模式，与 OpenSandbox 同步（渲染上游 chart 源、`ServerSideApply=true` 走 CRD）。

### 独立 PostgreSQL 18 平台组件

Keycloak 必须持久化用户/会话/客户端，而 PostgreSQL 是通用家庭基础设施扩展。选 Bitnami postgresql chart 16.x 作独立 platform-postgres Application，命名空间 `database`，凭证按命名空间分发。未来 OpenSandbox / 9Router / 监控栈需要数据库时直接共用同一集群。

### 同步波次

- **wave 0**：keycloak-operator（仅 CRD + controller，与 OpenSandbox 同款推理）
- **wave 1**：platform-postgres（Bitnami Helm chart）
- **wave 2**：keycloak（Keycloak CR + RealmImport + Ingress；严格依赖 wave 1 的 PostgreSQL Ready）

### 资源精简

| 组件 | requests | limits |
|------|----------|--------|
| keycloak-operator | 25m / 64Mi | 200m / 256Mi |
| keycloak StatefulSet | 200m / 384Mi | 500m / 768Mi |
| postgres Bitnami primary | 50m / 128Mi | 250m / 384Mi |

合计 275m / 576Mi，新增叠加后总请求约 776m / 1.78Gi（参见 [spec](../superpowers/specs/2026-10-06-keycloak-platform-design.md#资源2-vcpu--4-gb-节点预算)）。

### SealedSecret 单源

`database` 命名空间的 `postgres-credentials` 同时被 Bitnami chart 与 Keycloak CR 通过 `existingSecret` / `secretKeyRef` 读取；`keycloak` 命名空间的 `homelab-secrets` 收纳 admin + 4 client secret。轮换路径：重新生成 → 重新 `kubeseal` → 推送；Bitnami 检测 `existingSecret` 变化自动滚动；Keycloak 通过 `secretKeyRef` 自动取新值。

### 两段 commit 部署

PR 1 提交所有清单（SealedSecret 仅元数据）；PR 2 由用户在能访问集群的机器上 `k3s kubectl create secret --dry-run` + `kubeseal` 写回两个 SealedSecret。沿用 OpenSandbox `opensandbox-api-key` 模式。

### Traefik + cert-manager 复用

公网入口 `keycloak.lab.csharpkit.com` 与 9router / argo / grafana / sandbox 同 Traefik + cert-manager HTTP-01 体系，无需新增 ingress controller 或新 ClusterIssuer。Keycloak CR `hostname.strict=false` + `proxy.edgeHeaders=true` 让 Traefik 终止 TLS 后转发明文，Keycloak 信任 `X-Forwarded-*`。

## 后果

- **明文 secret 仅在内存**：所有 7 个 secret 在 PR 2 生成时只在 shell 变量中存在，`unset HISTFILE` + `unset <VAR>` 防泄漏；不写 `/tmp` 临时文件。
- **跨命名空间 secretKeyRef**：Keycloak operator 默认 ClusterRole 含 cluster-wide `secrets get`，可跨 ns 读 `postgres-credentials`；若 RBAC 受限，回退为在 `keycloak` 命名空间放一份 SealedSecret 副本。
- **v1 仅交付 Keycloak 平台**：ArgoCD / Grafana / 9Router / OpenSandbox 的 OIDC 接入各开独立 PR，本仓库 `apps/9router/deployment.yaml` 等文件不修改。
- **单副本 Keycloak**：滚动更新期间短暂不可用；多副本 + Infinispan 留作多节点扩展时。
- **依赖 Bitnami chart 维护活跃度**：Bitnami chart 维护暂停或 breaking change 时需切换其他 PG chart；operator 与 PG 解耦，切换代价可控。
- **本仓库绑定 Keycloak 26.x 升级路径**：升级到 26.x 大版本需重新 helm template，可能涉及 CRD 升级、operator API 变更。
```

- [ ] **Step 2：交叉引用**

```bash
cd e:/GitHub/cloudhomelab
ls docs/adr/008-keycloak-platform.md
ls docs/superpowers/specs/2026-10-06-keycloak-platform-design.md
```

期望：两文件均存在。

- [ ] **Step 3：提交**

```bash
git add docs/adr/008-keycloak-platform.md
git commit -m "docs: ADR-008 keycloak platform decision"
```

---

## 自审

- **Spec 覆盖**：spec 中所有决策（Operator 模式、独立 PG18、RealmImport CR、4 客户端、SealedSecret 单源、两段 commit、hostname/proxy、验证、ADR）均在某个任务中落地。无空白。
- **占位符扫描**：Task 5 Step 1 与 Task 6 Step 1 含 `TODO` 形式的 chart 版本待人工复核，标了明确触发条件（helm search 输出与字段定义不符时回退），属必要的人工检查而非「fill in later」。
- **类型一致性**：所有 `secretKeyRef.name` 引用对应 SealedSecret（`postgres-credentials` 在 `database` ns，`homelab-secrets` 在 `keycloak` ns）；Keycloak CR `spec.db.host` 与 Bitnami chart `releaseName: keycloak-postgres` + `namespace: database` 一致（service FQDN `keycloak-postgres.database.svc.cluster.local`）。
- **可独立测试**：每个任务结束后 ArgoCD 不会因为未完成文件报错（namespace 占位 SealedSecret 是 `encryptedData: {}`，operator 会等到 PR 2 加密数据落地才完成协调）。
```

实施计划已写到 `docs/superpowers/plans/2026-10-06-keycloak-platform.md`。

**两种执行方式：**

1. **Subagent-Driven（推荐）** —— 我每个任务派一个新 subagent，任务间我做把控，迭代快
2. **Inline Execution** —— 在当前会话执行，批量执行带 checkpoint 让我审

选哪种？