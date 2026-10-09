# YAML 域名变量化设计

## 背景与目标

服务域名散落在多个 Argo CD 管理的 YAML 文件中，包括 Ingress 主机、Keycloak
hostname 和 OAuth 回调地址、OpenSandbox gateway 地址，以及 Grafana Helm values。
更换集群域名时需要逐处修改，容易遗漏或造成路由、证书和 OAuth 配置不一致。

目标是提供一个仓库内的单一域名配置入口，让 Argo CD 在部署前渲染 YAML 中的域名
变量。默认域名保持现有行为：`lab.csharpkit.com`。

## 设计

### 唯一配置源与变量格式

- 在仓库根目录增加 `config/domains.env`，初始值为 `CLUSTER_DOMAIN=lab.csharpkit.com`。
- YAML 中的集群主机和 URL 使用 `${CLUSTER_DOMAIN}`，例如
  `argo.${CLUSTER_DOMAIN}`、`https://argo.${CLUSTER_DOMAIN}/auth/callback`。
- `CLUSTER_DOMAIN` 表示完整的集群主机后缀（例如 `lab.example.net`），不含协议、
  通配符、尾随句点或服务子域。服务子域仍由各应用配置指定。
- 只把服务端点域名变量化。`homelab.csharpkit.com/...` Kubernetes 标签键不变；
- namespace `description` 注解中展示的服务 URL 也使用同一变量，避免换域名后说明过期。
  注解键 `homelab.csharpkit.com/description`、Secret 名称、Service 名称及与域名无关的配置不变。

### Argo CD 渲染

- 在 Argo CD repo-server 部署一个 Config Management Plugin（CMP），负责 Git 路径型
  应用的清单生成。插件从当前仓库根目录读取 `config/domains.env`，并在应用清单中
  替换 `${CLUSTER_DOMAIN}`。
- 插件只展开显式指定的 `${CLUSTER_DOMAIN}`，不进行无差别的环境变量展开。Keycloak
  realm 导入中现有的 `${ADMIN_PASSWORD}`、`${ARGOCD_CLIENT_SECRET}` 等运行时占位符
  必须原样保留。
- 配置文件缺失、变量缺失、格式错误或域名不符合 DNS 名称格式时，插件以清晰错误
  终止渲染；禁止空值替换、使用默认值掩盖错误或生成成功形状的无效清单。
- 外部 Helm chart 仍由 Argo CD 原生 Helm 渲染。Grafana Ingress 从
  `platform/monitoring/values.yaml` 迁出为 CMP 管理的独立清单，同时关闭 chart
  内置 Ingress，确保 Grafana 主机名也只依赖中心配置。
- 所有包含 Git 仓库路径的受影响 Argo CD Application 均使用该插件；外部 chart
  source 不切换到插件。repo-server 插件配置通过仓库现有 bootstrap 流程安装和维护。
- 插件配置和渲染脚本的校验和记录在 repo-server Pod template 注解中；仅插件文件变化时触发
  sidecar rollout，内容未变时重复运行 bootstrap 不触发额外 rollout。

### 变量覆盖范围

集群服务主机后缀在下列 YAML 配置中统一取自 `CLUSTER_DOMAIN`：

- Argo CD、9Router、Keycloak、Grafana、OpenSandbox API 和 OpenSandbox gateway 的
  Ingress 主机及 TLS 主机。
- `platform/config/namespaces.yaml` 中面向运维人员展示的 Argo CD、9Router、Keycloak、
  Grafana 和 OpenSandbox 服务 URL。
- `apps/opensandbox/registry.yaml` 中解释集群 wildcard DNS 范围的注释。
- Keycloak CR 的公开与管理 hostname，以及 realm 导入中的各客户端 root URL、
  redirect URI 和 web origin。
- OpenSandbox server 内嵌 TOML 中的 gateway 地址。

服务名、协议、路径和应用间配置关系保持不变。文档保留当前默认域名作为部署实例
示例，并增加如何通过中心配置切换域名的说明。

## 错误处理与安全约束

- 配置解析不得将 `domains.env` 当作 shell 脚本执行。
- 域名须通过格式校验，拒绝 URL、端口、路径、通配符和空白字符。
- 渲染错误必须由 Argo CD 显示为生成失败，阻止无效资源同步。
- 变量展开限定在声明的域名占位符，不能覆盖其他字符串、Secret 内容或模板占位符。

## 验证

1. 插件单元测试验证有效域名展开、配置缺失/格式非法时报错，以及其他 `${...}`
   占位符保持不变。
2. 对受影响的 Argo CD Git 路径应用执行 manifest generation，确认其生成 YAML 可解析，
   所有受影响服务主机和 URL 使用中心配置的域名。
3. 确认渲染结果保留 Keycloak 运行时密钥占位符、TLS Secret 名称和既有 Service 后端。
4. 确认 Grafana chart 内置 Ingress 已关闭，CMP 管理的 Grafana Ingress 使用原后端
   Service、端口和 TLS Secret。
5. 验证 bootstrap 安装与重复运行后 repo-server CMP 正常就绪，现有 GitOps 应用仍可同步。

## 范围与非目标

- 本次仅集中配置服务域名，不抽取镜像、资源限制、端口或其他 YAML 值。
- 不更改 Kubernetes 标签键中的域名，也不重写所有应用为 Helm chart。
- 不更改 DNS 提供商、证书签发方式、服务子域命名和应用认证行为。
- 不替换仓库文档中的所有域名示例；文档用于描述当前默认部署，并说明唯一配置入口。
