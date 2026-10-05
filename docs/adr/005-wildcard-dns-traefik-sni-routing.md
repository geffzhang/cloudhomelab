# ADR-005：使用通配符 DNS 与 Traefik SNI 主机路由

**状态：** 已接受 · **日期：** 2026-07-23

## 背景

平台托管着多个服务（ArgoCD、Grafana、两个应用和 LiveKit 信令），未来还会增加更多服务。每个服务都需要一个公网 URL。目前只有一个节点和一个 IP。设计目标是添加项目时无需修改 DNS 或通过 SSH 登录：只需将清单推送到 Git 即可。

需要确定两件事：如何将多个主机名映射到同一个 IP，以及节点如何在共用 80 和 443 端口的情况下，将请求路由到不同主机名。

## 决策

采用**单条通配符 DNS 记录**，并使用 **Traefik 基于主机名（SNI）的路由**。

### 通配符 DNS

将 `*.lab.csharpkit.com` 这条记录指向节点 IP。`lab.csharpkit.com` 下的任何新子域名都能立即解析，无需进一步修改 DNS。ChessKernel 的根域名和 `www` 仍使用现有 DNS 记录指向同一节点。添加项目只需在 `apps/` 中创建目录，并在 `argocd/` 中添加一个 Application。

### Traefik SNI／主机路由

Traefik（随 k3s 一同提供）是唯一的 Ingress。每个服务都声明一个带有 `ingressClassName: traefik` 和 `host:` 规则的 `Ingress`。Traefik 负责终止 TLS、读取 SNI／`Host` 标头，并将请求路由到匹配的后端 Service。所有主机名共用节点上的 80 和 443 端口。

当前主机名映射如下：

| 主机名 | 后端 |
|------|---------|
| `csharpkit.com`、`www.csharpkit.com` | openclaw.net 客户端 |
| `csharpkit.lab.csharpkit.com` | openclaw.net 客户端 |
| `pixelhub.lab.csharpkit.com` | PixelHub 客户端 |
| `argo.lab.csharpkit.com` | ArgoCD 服务器 |
| `grafana.lab.csharpkit.com` | Grafana |
| `livekit.lab.csharpkit.com` | LiveKit 信令（wss） |

## 后果

- 新服务可以直接获得 URL：通配符 DNS 已能解析，Traefik 会按主机名路由，因此无需修改 DNS 或通过 SSH 登录。
- HTTP-01 仍会在首次收到请求时为每个主机名单独签发证书（参见 ADR-004）；通配符记录解决的是 DNS 解析，而非证书问题。
- Traefik 按主机名代理 HTTP、HTTPS 和 WebSocket（包括 `wss`）流量。它无法代理任意 UDP 流量，因此 LiveKit 的 WebRTC 媒体使用节点的 `hostPort`，而不经过 Ingress（参见网络文档）。这是“所有流量都通过 Traefik 按主机名路由”这一设计中唯一有记录的例外。
- TLS 只在 Traefik 处终止一次。ArgoCD 等后端在集群内部以不安全的纯 HTTP 模式运行（参见 ADR-002）；由于流量只能通过 Ingress 进入，这样做是安全的。
