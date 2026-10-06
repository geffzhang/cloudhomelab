# ADR-008：引入 PostgreSQL 作为平台共享数据库组件

**状态：** 已接受 · **日期：** 2026-10-06

## 背景

家庭实验室当前为单租户自托管平台：9Router（AI 网关）、OpenSandbox（沙箱控制平面）、ArgoCD（GitOps）、Grafana（监控）、sandbox API。持久化现状：

- 9Router：本地 PVC 存 API key + OAuth token
- OpenSandbox：registry PVC 存 OCI 镜像快照
- Grafana：admin 账号，密封 Secret 静态
- ArgoCD：未持久化任何业务数据
- OpenSandbox：无业务数据库

所有持久化均为应用专有本地存储，没有任何**共享数据库**层。引入 Keycloak 26.8 作为 OIDC 服务（参见 [ADR-009](009-keycloak-platform.md)）是首个真正需要关系型数据库的应用，未来 OpenSandbox 状态持久化、9Router 多用户化、监控栈长期指标存储（Thanos / Cortex / Loki）等场景都需要数据库。

为避免「每个需要 DB 的应用都自带 PG」的运维扩散，需要在 wave 1 引入**独立平台 PostgreSQL 组件**，由 ArgoCD 多源 Helm 模式管理，凭证按命名空间分发。

## 决策

### 独立平台组件而非 Keycloak 附属

PostgreSQL 与 Keycloak 26.8 解耦：

- `database` 命名空间跑 PostgreSQL，由 `platform-postgres` Application 管理（wave 1）
- `keycloak` 命名空间跑 Keycloak 26.8，由 `platform-keycloak` Application 管理（wave 2）
- Keycloak CR 通过跨命名空间 `secretKeyRef` 引用 `postgres-credentials` SealedSecret

理由：

1. **未来扩展**：OpenSandbox 状态持久化、9Router 用户库、监控栈长期存储都可共用
2. **运维清晰**：PG 升级、备份、调参与 Keycloak 解耦
3. **资源隔离**：PG 与 Keycloak 独立 `requests/limits`，便于 `kubectl top` / Grafana 面板分项监控

### PostgreSQL 主版本

- Keycloak 26.5+ 已放弃 PG 13（2025-11 EOL），需 PG 14+
- **目标：PG 18**（当前最新稳定主版本）；**v1 实际落地：PG 17.6.0**（见下方"备选方案"Bitnami chart OCI 不可达）

PG 版本钉在 Keycloak 26.x 的兼容窗口内（PG 14+）；主版本 14 / 15 / 16 / 17 / 18 都满足 Keycloak 26.x 要求，**当前部署选 17.6.0 是工程妥协**——计划升级到 18 时主要工作是 Bitnami chart 升 17→18（PG 17 → 18 大版本升级需要 `pg_upgrade`，详见 Bitnami chart README）。

### Bitnami Helm chart + 多源 ArgoCD Application

模式与 `platform-monitoring.yaml`、`platform-logging.yaml` 完全一致：

```yaml
sources:
  - repoURL: https://charts.bitnami.com/bitnami
    chart: postgresql
    targetRevision: 17.1.2  # Bitnami chart 17.1.2 ships PG 17.6.0
    helm:
      releaseName: keycloak-postgres
      valueFiles: [$values/platform/postgres/values.yaml]
  - repoURL: https://github.com/geffzhang/cloudhomelab
    targetRevision: main
    ref: values
```

理由：

1. **与现有 chart 风格统一**：cert-manager、monitoring、logging 均为外部 Helm chart
2. **多源解耦**：chart 版本由 Bitnami 发布周期决定；values 演进与本仓库 release 独立
3. **`releaseName: keycloak-postgres`**：固定 release 名 → Service FQDN 稳定（`keycloak-postgres.database.svc.cluster.local`），Keycloak CR `db.host` 引用此 FQDN

### SealedSecret 单源

`database` 命名空间下 `postgres-credentials` SealedSecret 收纳两个 key：

- `admin-password`：postgres 超级用户（仅运维）
- `keycloak-password`：第一个应用用户（Keycloak 使用）

Bitnami chart 通过 `global.postgresql.auth.existingSecret: postgres-credentials` + `secretKeys.adminPasswordKey/userPasswordKey` 同时读两个 key。Keycloak CR 通过 `db.password.valueFrom.secretKeyRef` 跨命名空间读 `keycloak-password`。

未来加新应用：

```yaml
# 在 apps/<new-app>/ 下加 SealedSecret，包含该 app 的 user password
# 在 apps/<new-app>/ 的 ArgoCD Application 中加 auth section
# 或在 platform/postgres/values.yaml 中加 databases + passwords（不推荐，破坏分层）
```

### 单节点 + local-path 存储

- **单节点 k3s**：`primary.persistence.storageClass: local-path`（k3s 内置，单节点够用）
- **多节点扩展留作未来**：若集群从单节点迁到多节点，需迁移到分布式存储类（Longhorn / Rook-Ceph），PG StatefulSet 需重建

### 资源精简

| 组件 | requests | limits |
|------|----------|--------|
| postgres Bitnami primary | 50m / 128Mi | 250m / 384Mi |

`primary.resources` 显式覆盖 chart 默认（chart 默认值通常更高，不适合 2 vCPU / 4 GB 节点）。PVC 1Gi 默认；PG 数据目录膨胀（监控用户加、客户端多）后再扩容。

### 备选方案

- **PG 嵌在 Keycloak chart 子表**：codecentric/keycloakx chart 可选 bundled PG。拒绝：平台组件应独立，共享给多应用
- **外部托管 PG（COS PG / 腾讯云）**：增加成本与外部 token 管理（Crossplane Secret 同步）。拒绝：家庭实验室小规模，自托管更简单
- **每个应用自带 PG StatefulSet**：运维扩散，备份/升级分散。拒绝：与本决策相反
- **CNPG / Zalando Postgres Operator**：增加 CRD 层 + 更复杂部署。拒绝：单节点 + 单实例不需要
- **Bitnami chart 18.x（PG 18）**：原计划。`helm pull bitnami/postgresql --version 18.12.4` 在当前网络下返回 `dial tcp [2a03:2880:f131:83:face:b00c:0:25de]:443: i/o timeout`——chart 18.x 系列**仅以 OCI registry 形式分发**，而本环境对 `charts.bitnami.com` OCI endpoint IPv6 路由不可达。回退到 chart 17.1.2（PG 17.6.0）；PG 17 仍满足 Keycloak 26.x 兼容性（PG 14+），不影响功能。详见 [`docs/operations/adding-keycloak.md`](../operations/adding-keycloak.md#已知遗留项) 与 `apps/postgres/sealed-credentials.yaml`

## 后果

- **首个消费者是 Keycloak**：首个数据库 `keycloak` + 用户 `keycloak`，由 `keycloak-password` SealedSecret 收纳
- **凭证命名空间分发**：Bitnami chart 在 `database` 命名空间，Keycloak CR 跨命名空间 `secretKeyRef`；要求 Keycloak operator 默认 ClusterRole 含 cluster-wide `secrets get`（[Keycloak 26.x 默认满足](https://www.keycloak.org/2025/keycloak-2640-released)）；若 RBAC 受限，回退为在 `keycloak` 命名空间放一份 SealedSecret 副本
- **备份策略**：v1 不引入 PG 自动备份；夜间手动 `pg_dump` 通过本地 cron + 推送 COS 留作未来。也可考虑 [ADR-006 nightly backups to COS](../006-nightly-backups-to-tencent-cos.md) 模式扩展到 PG
- **多节点扩展**：local-path 不支持多节点；PG StatefulSet 需重建并迁数据
- **本仓库绑定 Bitnami chart 版本**：升级 chart 版本需对照 Bitnami release notes 检查 values 字段变化
- **共享资源的命名冲突**：未来多个应用共用同一 PG cluster，user/database 命名必须显式约定（推荐 `<app-name>` 前缀，如 `keycloak` 已遵守）