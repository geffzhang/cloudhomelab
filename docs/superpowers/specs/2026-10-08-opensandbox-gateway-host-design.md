# OpenSandbox 独立网关域名设计

## 目标

为 URI 路由的沙箱访问新增独立 HTTPS 域名
`sandbox-gateway.lab.csharpkit.com`，并将 OpenSandbox server 发布的网关地址
同步到该域名。

## 设计

- 新增独立的 gateway Ingress，使用精确主机名
  `sandbox-gateway.lab.csharpkit.com`，将 HTTP 流量转发到
  `opensandbox-ingress-gateway` Service 的 80 端口。
- 使用现有 `letsencrypt-prod` HTTP-01 ClusterIssuer，为该主机名签发独立
  TLS 证书并保存到 `opensandbox-gateway-tls` Secret。现有 `*.lab.csharpkit.com`
  DNS A 记录已覆盖此主机名；HTTP-01 按具体主机签证，不需要 DNS-01
  通配符证书。
- 将 server 的 `gateway.address` 改为
  `sandbox-gateway.lab.csharpkit.com`，不带协议或 `*.` 前缀；保持 URI 路由模式。
- 保留现有 `sandbox.lab.csharpkit.com` 到 server API 的 Ingress，不改变其后端。
- 更新 OpenSandbox 运维指南，区分 API 域名和沙箱 gateway 域名。

## 范围

- 修改 OpenSandbox server 配置和运维指南。
- 新增独立 gateway Ingress 清单。
- 不修改 gateway Deployment、Service、RBAC、API Ingress 或集群级 DNS/TLS 签发机制。

## 验证

- 所有 OpenSandbox YAML 文档均可解析。
- server 内嵌 TOML 的 `ingress.mode` 为 `"gateway"`，`gateway.address` 为新域名，
  `gateway.route.mode` 为 `"uri"`。
- 新 Ingress 的主机名、TLS Secret、issuer、Service 名及 80 端口均与设计一致。
- 现有 API Ingress 仍使用 `sandbox.lab.csharpkit.com` 并指向
  `opensandbox-server:80`。
