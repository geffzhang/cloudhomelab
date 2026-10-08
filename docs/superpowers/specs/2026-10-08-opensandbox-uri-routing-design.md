# OpenSandbox URI 路由设计

## 目标

将 OpenSandbox 沙箱 URL 路由切换为 URI 模式，同时继续使用 gateway ingress
模式及已配置的网关域名。

## 范围

- 将渲染后的 OpenSandbox server 配置中的 `gateway.route.mode` 设为 `"uri"`。
- 保持 `ingress.mode = "gateway"` 和现有 `gateway.address` 域名不变。
- 更新 OpenSandbox 运维指南，说明这些配置需配合使用，且网关域名应与
  Ingress 域名一致。
- 不修改 gateway 部署资源、路由权限或其他运行时配置。

## 验证

- 确认渲染后的 `server.yaml` 仍是有效 YAML，内嵌 `config.toml` 使用 URI
  路由模式、gateway ingress 模式及已配置的域名。
- 确认运维指南描述与配置一致。
