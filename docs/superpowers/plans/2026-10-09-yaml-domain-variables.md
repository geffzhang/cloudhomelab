# YAML 域名变量化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将集群服务域名集中到仓库根目录的一个配置文件，并由 Argo CD 在同步前严格渲染。

**Architecture:** 新增 Argo CD Config Management Plugin（CMP）sidecar 处理 Git 路径型应用，只替换 `${CLUSTER_DOMAIN}`。外部 Helm chart 继续由原生 Helm 渲染；Grafana Ingress 迁出 Helm values，改由 CMP 渲染。

**Tech Stack:** Bash、Argo CD CMP sidecar、Kubernetes YAML、现有 shell 测试。

## Global Constraints

- 默认域名保持 `lab.csharpkit.com`。
- `${CLUSTER_DOMAIN}` 表示完整的集群主机后缀，不含协议、通配符、尾随句点或服务子域。
- 插件只展开显式指定的 `${CLUSTER_DOMAIN}`；Keycloak 中其他 `${...}` 占位符必须原样保留。
- 配置缺失、变量缺失、格式错误或域名格式不合法时必须让渲染失败，不得静默回退或输出空值。
- 不变量化 `homelab.csharpkit.com/...` Kubernetes 标签键、Secret 名称、Service 名称或其他非域名配置。
- 外部 Helm chart 仍由 Argo CD 原生 Helm 渲染；Grafana Ingress 改由 CMP 管理。
- CMP sidecar 必须与 repo-server 版本一致，使用非 root 用户，并将独立 `/tmp` 挂载给 sidecar。
- Bootstrap 重复运行必须保留既有 Argo CD 安装和 GitOps 行为。

---

## 文件结构

- `config/domains.env`：唯一的集群域名配置，格式为 `CLUSTER_DOMAIN=...`。
- `bootstrap/argocd-cmp/plugin.yaml`：CMP 插件发现规则与 manifest generation 命令。
- `bootstrap/argocd-cmp/render.sh`：验证配置并在当前 Argo CD 应用目录渲染 YAML。
- `bootstrap/argocd-cmp-install.sh`：安装 CMP ConfigMap、patch repo-server sidecar 并等待 rollout。
- `bootstrap/install.sh`：在应用 root app-of-apps 之前安装 CMP。
- `tests/argocd-cmp/render.sh`：离线验证配置解析、渲染及错误路径。
- `tests/bootstrap/argocd-cmp.sh`：使用 mock kubectl 验证 bootstrap CMP 安装流程。
- `argocd/app-9router.yaml`、`argocd/platform-config.yaml`、`argocd/platform-keycloak.yaml`、`argocd/platform-opensandbox.yaml`：将对应 Git 路径型应用切换为 CMP source。
- `apps/9router/ingress.yaml`、`apps/keycloak/ingress.yaml`、`apps/keycloak/keycloak-cr.yaml`、`apps/keycloak/realm-import.yaml`、`apps/opensandbox/ingress.yaml`、`apps/opensandbox/gateway-ingress.yaml`、`apps/opensandbox/registry.yaml`、`apps/opensandbox/server.yaml`、`platform/config/argocd-ingress.yaml`、`platform/config/namespaces.yaml`：用 `${CLUSTER_DOMAIN}` 替换服务域名及解释域名的文字。
- `platform/config/grafana-ingress.yaml`：新增由 CMP 管理的 Grafana Ingress。
- `platform/monitoring/values.yaml`：关闭 chart 自带 Grafana Ingress。
- `docs/networking.md`、`docs/RUNBOOK.md`：说明域名配置来源及 DNS 操作。

### Task 1: 实现域名渲染器及离线测试

**Files:**
- Create: `config/domains.env`
- Create: `bootstrap/argocd-cmp/render.sh`
- Test: `tests/argocd-cmp/render.sh`

**Interfaces:**
- Consumes: 从当前应用目录向仓库根目录读取 `config/domains.env`；CMP 在应用源目录执行 `render.sh`。
- Produces: `render.sh` 将当前应用目录中的 `.yaml` / `.yml` 逐个写成 stdout 上的 Kubernetes YAML stream；失败时写 stderr 并返回非零。

- [ ] **Step 1: 先写渲染器测试**

测试创建临时仓库结构 `repo/config/domains.env` 和 `repo/apps/demo/ingress.yaml`，用当前测试文件的相对路径找到 renderer，并断言域名被替换、其它占位符保留：

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RENDERER="$(cd -- "$SCRIPT_DIR/../../bootstrap/argocd-cmp" && pwd)/render.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/repo/config" "$TEST_ROOT/repo/apps/demo"
printf 'CLUSTER_DOMAIN=lab.example.net\n' > "$TEST_ROOT/repo/config/domains.env"
cat > "$TEST_ROOT/repo/apps/demo/ingress.yaml" <<'YAML'
host: argo.${CLUSTER_DOMAIN}
callback: https://argo.${CLUSTER_DOMAIN}/auth/callback
secret: ${ADMIN_PASSWORD}
YAML

OUTPUT="$(cd "$TEST_ROOT/repo/apps/demo" && "$RENDERER")"
grep -Fq 'host: argo.lab.example.net' <<< "$OUTPUT"
grep -Fq 'callback: https://argo.lab.example.net/auth/callback' <<< "$OUTPUT"
grep -Fq 'secret: ${ADMIN_PASSWORD}' <<< "$OUTPUT"
! grep -Fq '${CLUSTER_DOMAIN}' <<< "$OUTPUT"
echo 'PASS: domain rendering'
```

- [ ] **Step 2: 运行测试并确认初始失败**

Run: `bash tests/argocd-cmp/render.sh`

Expected: FAIL，因为 renderer 尚不存在。

- [ ] **Step 3: 实现配置解析、格式校验和只替换指定变量**

`config/domains.env` 初始内容：

```dotenv
CLUSTER_DOMAIN=lab.csharpkit.com
```

`render.sh` 必须：

1. 从当前源目录向上定位仓库根目录中的 `config/domains.env`，限制查找深度，找不到时报错。
2. 逐行解析配置，不使用 `source` 或 `eval`；拒绝未知键、重复键、空值及非 DNS 域名格式。
3. 用安全的 Bash 正则校验小写 DNS 标签：每个标签 1–63 字符，只允许字母、数字和中间连字符，禁止空标签、开头/结尾连字符；域名必须至少包含一个点。
4. 对当前源目录下按稳定顺序找到的 `.yaml` / `.yml` 文件执行定向替换 `\${CLUSTER_DOMAIN}`，替换值已限制为字母、数字、点和连字符；其它内容逐字保留。多文件输出之间插入 `---` 文档分隔符，确保无尾换行的输入文件不会与后续 YAML 文档粘连。
5. 任一文件读取或替换失败时返回非零，不得将失败吞掉。

不要使用无参数的 `envsubst`，以免清空 `${ADMIN_PASSWORD}` 等现有占位符。

- [ ] **Step 4: 覆盖配置失败分支并运行测试**

在测试脚本追加以下场景：缺少 `domains.env`、缺少 `CLUSTER_DOMAIN`、重复声明变量、出现未知键、空值、`https://example.net`、`*.example.net`、`bad..example.net` 和包含路径/空白的值都必须非零退出；每个用例单独创建 fixture 并检查 stderr 有明确错误。

Run: `bash tests/argocd-cmp/render.sh`

Expected: `PASS: domain rendering` 及每个无效输入断言通过。

- [ ] **Step 5: 提交 renderer**

```bash
git add config/domains.env bootstrap/argocd-cmp/render.sh tests/argocd-cmp/render.sh
git commit -m "feat: add strict cluster domain renderer" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

### Task 2: 将 CMP 安装接入可重复运行的 bootstrap

**Files:**
- Create: `bootstrap/argocd-cmp/plugin.yaml`
- Create: `bootstrap/argocd-cmp-install.sh`
- Modify: `bootstrap/install.sh`
- Create: `tests/bootstrap/argocd-cmp.sh`

**Interfaces:**
- Consumes: `bootstrap/argocd-cmp/plugin.yaml`、`bootstrap/argocd-cmp/render.sh`、已就绪的 Argo CD repo-server。
- Produces: `configure_argocd_domain_cmp` 函数；成功返回时 repo-server 有唯一名为 `homelab-domain` 的 CMP sidecar 且 rollout 就绪。

- [ ] **Step 1: 为 CMP 安装 helper 写 mock-kubectl 测试**

测试沿用 `tests/bootstrap/k3s-registry.sh` 的 mock-bin 模式。mock `kubectl` 记录调用并返回 repo-server 主容器 image；断言 helper：

- 用两个文件创建/更新 ConfigMap `homelab-domain-cmp`；
- 用 repo-server 当前 image 作为 sidecar image，避免版本漂移；
- 通过 strategic merge patch 添加一个 sidecar（不会重复增加容器）、配置和独立 `cmp-tmp` emptyDir；
- 以 UID 999 非 root 运行 sidecar，command 为 `/var/run/argocd/argocd-cmp-server`；
- 调用 repo-server rollout status，mock 非零时 helper 也非零。

- [ ] **Step 2: 运行 bootstrap 测试并确认初始失败**

Run: `bash tests/bootstrap/argocd-cmp.sh`

Expected: FAIL，因为 helper 尚不存在。

- [ ] **Step 3: 新增插件配置**

`bootstrap/argocd-cmp/plugin.yaml` 的契约：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ConfigManagementPlugin
metadata:
  name: homelab-domain
spec:
  discover:
    fileName: "*.yaml"
  generate:
    command:
      - /bin/bash
      - /home/argocd/cmp-server/config/render.sh
```

ConfigMap 同时挂载 `plugin.yaml` 和 `render.sh` 到 CMP sidecar 的
`/home/argocd/cmp-server/config/`。确认插件发现规则只命中有 YAML 的 Git 路径应用，不会接管外部 Helm chart。

- [ ] **Step 4: 实现 bootstrap helper 并接入安装顺序**

helper 从 repo-server Deployment 读取主容器 image，创建或更新 CMP ConfigMap，再以 strategic merge patch 添加 sidecar。将插件配置与脚本的 SHA-256 写入 Pod template annotation，配置变化时才触发新 rollout。sidecar 使用 `var-files` 和 `plugins` 共享卷、专属 `cmp-tmp` 卷、ConfigMap 配置挂载，以及受限资源 requests/limits。等待 repo-server rollout 成功后才返回。

在 `bootstrap/install.sh` 中 source helper，并在 repo-server 已安装且 ready 后、应用 root app-of-apps 之前调用：

```bash
source "$BOOTSTRAP_DIR/argocd-cmp-install.sh"
configure_argocd_domain_cmp "$BOOTSTRAP_DIR/argocd-cmp"
```

若 ConfigMap 应用、patch 或 rollout 失败，bootstrap 必须在应用 root app 之前以非零退出。

- [ ] **Step 5: 运行测试、语法检查并提交**

Run: `bash tests/bootstrap/argocd-cmp.sh`

Expected: PASS，mock rollout 失败场景返回非零，sidecar patch 中只有一个 CMP 容器。

Run: `bash -n bootstrap/install.sh bootstrap/argocd-cmp-install.sh bootstrap/argocd-cmp/render.sh tests/bootstrap/argocd-cmp.sh`

Expected: 无语法错误。

```bash
git add bootstrap/argocd-cmp/plugin.yaml bootstrap/argocd-cmp-install.sh bootstrap/install.sh tests/bootstrap/argocd-cmp.sh
git commit -m "feat: install domain CMP with Argo CD" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

### Task 3: 接入 Argo CD 应用并变量化服务域名

**Files:**
- Modify: `argocd/app-9router.yaml`
- Modify: `argocd/platform-config.yaml`
- Modify: `argocd/platform-keycloak.yaml`
- Modify: `argocd/platform-opensandbox.yaml`
- Modify: `apps/9router/ingress.yaml`
- Modify: `apps/keycloak/ingress.yaml`
- Modify: `apps/keycloak/keycloak-cr.yaml`
- Modify: `apps/keycloak/realm-import.yaml`
- Modify: `apps/opensandbox/ingress.yaml`
- Modify: `apps/opensandbox/gateway-ingress.yaml`
- Modify: `apps/opensandbox/server.yaml`
- Modify: `apps/opensandbox/registry.yaml`
- Modify: `platform/config/argocd-ingress.yaml`
- Modify: `platform/config/namespaces.yaml`
- Create: `platform/config/grafana-ingress.yaml`
- Modify: `platform/monitoring/values.yaml`
- Test: `tests/argocd-cmp/render.sh`

**Interfaces:**
- Consumes: Task 1 renderer、Task 2 插件名 `homelab-domain`。
- Produces: 所有服务 Ingress/URL 从同一中心后缀渲染；Helm chart 不再拥有 Grafana Ingress。

- [ ] **Step 1: 先扩展 renderer 测试到仓库中的受影响应用**

用当前默认配置渲染 `apps/9router`、`apps/keycloak`、`apps/opensandbox` 和 `platform/config`。断言输出不含 `${CLUSTER_DOMAIN}`，含对应服务主机，并且 Keycloak 输出仍含 `${ADMIN_PASSWORD}`、`${ARGOCD_CLIENT_SECRET}`。

Run: `bash tests/argocd-cmp/render.sh`

Expected: 对应断言因现有清单尚未变量化而失败。

- [ ] **Step 2: 将受影响应用切换到 CMP 并变量化清单**

上述四个 Git 路径型 Application 的 `spec.source` 增加：

```yaml
plugin:
  name: homelab-domain
```

将 `9router`、`argo`、`keycloak`、`sandbox`、`sandbox-gateway` 和 `grafana` 主机以及 Keycloak 的 hostname、realm root URL、redirect URI、web origin、OpenSandbox TOML gateway 地址、`platform/config/namespaces.yaml` 中展示的服务 URL、`apps/opensandbox/registry.yaml` 中解释 wildcard DNS 的注释统一改用 `${CLUSTER_DOMAIN}`。保留每项前面的服务名、`https://`、OAuth 路径、TLS Secret 和 Service 后端；不得替换 `homelab.csharpkit.com/description` 等 Kubernetes annotation/label 键。

- [ ] **Step 3: 将 Grafana Ingress 从 Helm values 迁出**

在 `platform/monitoring/values.yaml` 中设 `grafana.ingress.enabled: false` 并移除其 hosts/tls 配置。新增 `platform/config/grafana-ingress.yaml`，以 CMP 变量化 Grafana host，保持 `cert-manager.io/cluster-issuer: letsencrypt-prod`、`grafana-tls` Secret，以及从原 Helm 渲染结果核对的 Grafana Service 和 HTTP 端口。Ingress 显式使用 `namespace: monitoring`。

- [ ] **Step 4: 渲染并检查所有受影响配置**

Run: `bash tests/argocd-cmp/render.sh`

Expected: 默认值和自定义 fixture 域名都出现在所有预期主机/URL 中；Keycloak 运行时占位符、TLS Secret、Service 后端原样保留；所有无效配置测试继续通过。

用 `rg -n 'csharpkit\\.com|\\$\\{CLUSTER_DOMAIN\\}' argocd apps platform/config platform/monitoring/values.yaml` 检查受影响部署 YAML：服务端点不得残留硬编码后缀或未渲染变量；`homelab.csharpkit.com/...` 标签键允许且应保留。

- [ ] **Step 5: 提交应用接入**

```bash
git add argocd/app-9router.yaml argocd/platform-config.yaml argocd/platform-keycloak.yaml argocd/platform-opensandbox.yaml apps/9router/ingress.yaml apps/keycloak/ingress.yaml apps/keycloak/keycloak-cr.yaml apps/keycloak/realm-import.yaml apps/opensandbox/ingress.yaml apps/opensandbox/gateway-ingress.yaml apps/opensandbox/registry.yaml apps/opensandbox/server.yaml platform/config/argocd-ingress.yaml platform/config/namespaces.yaml platform/config/grafana-ingress.yaml platform/monitoring/values.yaml bootstrap/argocd-cmp/render.sh bootstrap/argocd-cmp-install.sh tests/argocd-cmp/render.sh tests/bootstrap/argocd-cmp.sh docs/superpowers/specs/2026-10-09-yaml-domain-variables-design.md docs/superpowers/plans/2026-10-09-yaml-domain-variables.md
git commit -m "feat: centralize service domains in manifests" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

### Task 4: 更新运维说明并完成部署验证

**Files:**
- Modify: `docs/networking.md`
- Modify: `docs/RUNBOOK.md`
- Validate: 所有测试及 Argo CD 应用状态

**Interfaces:**
- Consumes: 仓库配置文件 `config/domains.env` 与运行中的 `homelab-domain` CMP。
- Produces: 运维人员知道如何设置域名/DNS，并确认现有应用仍正常同步。

- [ ] **Step 1: 更新网络与初始化文档**

在 `docs/networking.md` 说明服务域名后缀唯一来源是 `config/domains.env`，换域名时该值必须与 wildcard DNS、证书可达性及公开 OAuth URL 保持一致；在 `docs/RUNBOOK.md` 的初始化 DNS 步骤说明先读取配置中的域名，再创建对应 wildcard 记录。保留 `lab.csharpkit.com` 作为当前默认示例。

- [ ] **Step 2: 运行所有有针对性的离线测试**

Run:

```bash
bash tests/argocd-cmp/render.sh
bash tests/bootstrap/argocd-cmp.sh
bash tests/bootstrap/k3s-registry.sh
bash -n bootstrap/install.sh bootstrap/argocd-cmp-install.sh bootstrap/argocd-cmp/render.sh tests/argocd-cmp/render.sh tests/bootstrap/argocd-cmp.sh
```

Expected: 所有测试输出 `PASS`，Bash 语法检查无错误。

- [ ] **Step 3: 在 Argo CD 环境验证实际生成和同步**

bootstrap 后确认：

```bash
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-repo-server
```

用 `argocd app manifests` 分别检查 `9router`、`platform-config`、`keycloak`、`opensandbox` 的生成结果：输出不得残留 `${CLUSTER_DOMAIN}`；Keycloak `${...}` 密钥占位符必须保留；Grafana Ingress 应指向 chart 创建的原 Grafana Service。等待这四个应用和 `monitoring` 状态同步健康，并确认 Grafana chart 不再生成重复 Ingress。

- [ ] **Step 4: 提交运维文档**

```bash
git add docs/networking.md docs/RUNBOOK.md
git commit -m "docs: explain centralized domain configuration" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```
