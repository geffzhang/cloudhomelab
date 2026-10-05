# ADR-004：cert-manager 采用 HTTP-01 而非 DNS-01

**状态：** 已接受 · **日期：** 2026-07-23

## 背景

每个公网主机名都需要有效的 TLS 证书，并且应自动签发和续期，且不产生费用。使用 cert-manager 配合 Let's Encrypt 是显而易见的选择。需要决定的是用于验证域名控制权的 ACME 挑战类型：HTTP-01 还是 DNS-01。

- **HTTP-01** 通过在 `http://<host>/.well-known/acme-challenge/...` 提供令牌来验证控制权。它要求主机名已解析到集群且 80 端口可访问，但不需要访问 DNS 服务商的 API。
- **DNS-01** 通过创建 `_acme-challenge` TXT 记录来验证控制权。它支持通配符证书，也不要求入站 80 端口，但需要 DNS 服务商的 API 令牌，这会增加一项需要存储、限制权限并轮换的密钥。

## 决策

采用 **cert-manager，并配置单个 `ClusterIssuer`（`letsencrypt-prod`），通过 Traefik 使用 HTTP-01 验证**（`platform/config/cluster-issuer.yaml`）。

```yaml
solvers:
  - http01:
      ingress:
        class: traefik
```

- 无需 DNS 服务商令牌，因此集群中少一项密钥，也少一项需要轮换的凭据。
- 它适用于任何 DNS 服务商，因为唯一要求是配置指向该节点的 A 记录。
- 每个主机名单独签发一张证书。通配符 DNS 记录（参见 ADR-005）用于路由流量，并不意味着必须使用通配符证书。

## 后果

- 由于 HTTP-01 通过实际访问主机进行验证，因此签发证书前，主机名必须已解析到该节点。这也是 ChessKernel 使用两个独立 Ingress 对象的原因：生产域名（`chesskernel.com`）可以立即签发证书，而实验环境主机（`chesskernel.lab.csharpkit.com`）则需等待通配符 DNS 记录生效。如果 Ingress 引用的任何密钥缺失，Traefik 就会忽略该 Ingress 的全部 TLS 配置；将二者分开可避免生产证书等待实验环境证书。
- 证书按主机名签发，而非使用通配符证书。每个新的子域名首次被请求时都会自动触发证书签发，无需手动操作。
- 为完成挑战和 HTTP 到 HTTPS 的重定向，必须保持 80 端口可访问。如果将来 HTTP-01 不再满足需求（例如需要通配符证书），则迁移方式是添加带有服务商令牌的 DNS-01 求解器；只需修改 `ClusterIssuer` 这一个对象。
- cert-manager 是 wave-0 依赖项，因为在任何 Ingress 请求证书之前，其 CRD 和 `ClusterIssuer` 都必须已存在（参见 ADR-002）。
