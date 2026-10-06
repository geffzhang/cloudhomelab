# OpenSandbox `sandbox.fast.io` CRD 补齐设计

## 背景

Argo CD Application `opensandbox` 已同步整个 `apps/opensandbox/` 目录。当前 `base.yaml` 只包含 `sandbox.opensandbox.io` 组的三个 CRD，但 `server.yaml` 已为 `sandbox.fast.io` 组的 `sandboxes`、`sandboxtemplates` 和 `sandboxesnapshots` 配置 RBAC。缺少 CRD 定义会导致这些 API 资源不能在集群中注册。

OpenSandbox 上游 `release-1.1.0` 的 `manifests/charts/base/files/fast-sandbox-crds.yaml` 提供了 `sandbox.fast.io` 组的完整 CRD bundle，共四项：`sandboxes`、`sandboxtemplates`、`sandboxesnapshots` 和 `sandboxpools`。本地 RBAC 目前只授予前三项所需权限；本次仅补 CRD，不扩大访问权限或启用 fast-sandbox 工作负载。

## 目标

- 在现有 OpenSandbox 基础清单中加入上游 `release-1.1.0` 的四个 `sandbox.fast.io` CRD。
- 保留上游 `v1alpha2` 的完整 OpenAPI schema，以及 Chart 渲染出的 CRD labels 和保留策略注解。
- 更新运维文档，使其准确说明安装的 CRD 数量及来源。
- 不修改 Argo CD Application、现有 RBAC、控制器、服务或工作负载。

## 方案

将上游 base Chart 的 CRD 模板对 `fast-sandbox-crds.yaml` 的渲染结果并入 `apps/opensandbox/base.yaml`。使用完整上游 bundle，而非手写 schema 或仅复制 RBAC 对应的三个资源，以避免字段遗漏并与固定的 OpenSandbox 1.1.0 来源保持一致。`sandboxpools` 作为上游 bundle 的第四项一并注册，但本次不为其添加 RBAC。

不修改 `argocd/platform-opensandbox.yaml`：其现有目录源已覆盖 `apps/opensandbox/`，无需单独注册清单文件或调整同步行为。

## 验收与验证

- `base.yaml` 中 `sandbox.fast.io` 组恰有四个 CRD：`sandboxes`、`sandboxtemplates`、`sandboxesnapshots`、`sandboxpools`。
- 四个 CRD 的 API 版本为 `v1alpha2`，并保留上游 OpenAPI schema。
- YAML 文档可解析，CRD 数量与资源名称断言通过，改动无空白错误。
- 运维文档准确描述更新后的 CRD 集合；Argo CD 路由、RBAC 和工作负载保持不变。
