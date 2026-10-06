# ADR-010：永久覆盖 k3s 内置 CoreDNS ConfigMap

**状态：** 已接受 · **日期：** 2026-10-06

## 背景

- [ADR-001](001-k3s-over-full-kubernetes.md) 决策采用 k3s 发行版，因为内置 Traefik / CoreDNS / local-path 存储降低维护负担。
- 现状：Pod DNS 偶发数秒级超时（首次解析 kubernetes.default / 跨网域查询时偶发 5–10s 卡顿）。
- 根因：k3s 默认 CoreDNS ConfigMap 包含 `forward . /etc/resolv.conf`，把所有上游解析递归到主机 ISP DNS（家庭实验室 VPS 出网走 ISP 分配，慢 + 偶发不可达）。
- 临时修复：直接 `kubectl edit cm coredns -n kube-system` 替换 `forward` 行为有效，但**k3s 重启或升级时其内置 chart 重新渲染 ConfigMap**，临时 patch 在重启后丢失。
- 长期目标：把 Corefile 替换+cache 调优通过 GitOps 永久化，使其在 k3s 重启与升级后仍生效。

## 决策

### 上游切到 DNSPod + cache TTL 调优

`apps/coredns/coredns-config.yaml` 渲染完整 Corefile，**仅替换两段**，其余 stanza 保留 k3s 上游 chart 模板逐字不动：

```corefile
forward . 119.29.29.29 119.28.28.28 {
  prefer_udp
  max_fails 3
  expire 10s
}
cache 30 {
  success 9984
  denial 9984
}
```

- `forward`：DNSPod 公共解析（119.29.29.29 / 119.28.28.28），UDP 优先；`max_fails 3` + `expire 10s` 让慢上游被快速短路，Pod DNS 不再因上游卡顿而 stall。
- `cache 30`：TTL 30s 适合家庭实验室较小的活跃查询集；`success 9984` + `denial 9984` 拉高 cache 命中率。
- 保留 errors / kubernetes / hosts / prometheus / ready / health / loop / reload / loadbalance：与 k3s 上游 chart 模板保持一致，避免 k3s 升级后 ArgoCD 误报 stanza 漂移。

### 同步波次 0（不是 -1）

`argocd/platform-coredns.yaml` 单 Application 同步波次为 **0**（与 `cert-manager` / `sealed-secrets` / `opensandbox` / `keycloak-operator` 同波），不是 -1：

1. k3s 启动顺序保证：k3s 安装时 CoreDNS Deployment 已经在运行；后续 ArgoCD 才安装。在任何 ArgoCD Application 同步之前，Pod DNS 已经可用。
2. wave -1 不能比 k3s 启动更早——只有 `bootstrap/install.sh` 可以在 k3s 启动后立刻 patch，但那不在 GitOps 范畴内。
3. wave 0 的代价：k3s 重启后到 ArgoCD 下一次 reconcile（默认 3 min）之间，Pod DNS 暂时回退到 ISP 上游。家庭实验室单节点、低 QPS 场景可接受；多节点高 QPS 不在本决策范围。

### ServerSideApply + ignoreDifferences 拆分所有权

- ArgoCD 通过 `ServerSideApply=true` 拥有 `data.Corefile`（field manager = `argocd-controller`）。
- k3s 保留对 Deployment、Service、labels、annotations、binaryData、`immutable` 的写入权；这些字段通过 `ignoreDifferences.jqPathExpressions` 在 Application spec 中忽略差异：

```yaml
ignoreDifferences:
  - group: ""
    kind: ConfigMap
    name: coredns
    jqPathExpressions:
      - .metadata.labels
      - .metadata.annotations
      - .binaryData
      - .immutable
```

- 效果：k3s 重启 → chart 重新渲染 ConfigMap → ArgoCD reconcile → SSA 字段竞争，ArgoCD 在 `data.Corefile` 上胜出（k3s 的 field manager 不在 ArgoCD 声明的字段集中）。
- CoreDNS 自带 fsnotify 监听挂载的 Corefile，ConfigMap 变更后自动 reload，无需 `rollout restart`。

### 为什么不用其它方案

- **k3s --disable=coredns` 后自管**：拒绝。增加一个独立 Helm chart 维护负担，与 ADR-001「内置优先」相悖。
- **在 `bootstrap/install.sh` 里 `kubectl patch` 永久化**：拒绝。绕过 GitOps 源真理，runbook 变更即漂移。
- **用 Reloader 监听 ConfigMap → 触发 Deployment rollout**：拒绝。Deployment 由 k3s 管，rollout 会触发 k3s 重渲染，与本决策目的相同且多一层。
- **`--config` k3s Helm values override**：可工作但配置在 VPS 文件系统上，不在 git。GitOps 失守。

## 后果

- **新增 `argocd/platform-coredns.yaml`**：单一 Application 管理 ConfigMap。任何后续需要调整 upstream / cache TTL 直接改 git 推送即可。
- **sync-wave 表新增行**：[ADR-002](002-argocd-app-of-apps-sync-waves.md) 的 wave 0 行追加 `platform-coredns` 条目。
- **`kube-system` 命名空间**：仍由 k3s 管理（k3s 是该命名空间的隐式 controller）。本 Application 只声明 `apps/coredns/coredns-config.yaml` 一个 ConfigMap；`prune: true` 不会删除 `kube-system` 中其它资源，因为 `platform/config/namespaces.yaml` 已经为该命名空间挂 `argocd.argoproj.io/sync-options: Prune=false` 防误删。
- **field-manager 拆分验证**：每次 k3s 升级后，确认 SSA 所有权未被破坏：
  ```bash
  k3s kubectl -n kube-system get cm coredns -o json \
    | jq '.metadata.managedFields[] | {manager, fieldsV1}'
  ```
  预期两条 entry——`argocd-controller` 仅负责 `data.Corefile`，k3s 负责 metadata/binaryData。**此为防回退机制的现场验证**。
- **k3s 升级验证**：每次 `k3s` 升级后运行「DNS 验证」步骤。CoreDNS chart 在新 k3s 中如有 Corefile 模板变化，需要同步本仓库的 Corefile body 才能避免 ArgoCD 报错。
- **恢复路径**：
  - 临时回退上游 DNS：直接 `kubectl edit cm coredns -n kube-system` 改 `forward` 段（field manager 竞争不影响手动 kubectl patch）。
  - 永久回退：revert PR + push。
- **本地验证**：本仓库 `github.com:443` 不可达，所有验证在本地仅做 YAML 解析；VPS 推送后 ArgoCD 同步验证。