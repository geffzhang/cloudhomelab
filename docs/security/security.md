# 安全

这是一个运行在公网 VPS 上的单节点家庭实验室环境（1 个 vCPU / 4 GB，179.197.71.43），并使用公开的 Git 仓库。安全模型由这两个事实决定：密钥必须能够安全地提交到仓库，边缘入口处的流量必须加密，内部服务不得暴露到公网。本文介绍安全模型、已实施的主机加固措施，以及单节点运行所带来的实际权衡。

## 密钥：Sealed Secrets 模型

所有密钥都以 `SealedSecret` 自定义资源的形式存放在 Git 中，并经过加密，因此可以安全地保存在公开仓库中。选择此方案的原因请参见 [ADR-003](../adr/003-sealed-secrets-for-public-repo.md)。

### 控制器密钥

Sealed Secrets 控制器（位于 `kube-system` 的 `sealed-secrets-controller`）持有一对非对称密钥。公钥用于加密（由本地计算机上的 `kubeseal` 使用），私钥用于解密（仅在集群内使用）。`SealedSecret` 只能由持有匹配私钥的控制器解密，因此将其提交到仓库不会泄露密钥内容。

### 密钥加密操作

```bash
cp docs/examples/<app>-secrets.example.yaml /tmp/secrets.yaml
# 在 /tmp/secrets.yaml 中填入真实值
kubeseal --controller-namespace kube-system --format yaml \
  < /tmp/secrets.yaml > apps/<app>/sealed-secrets.yaml
shred -u /tmp/secrets.yaml
```

绝不能提交明文密钥。只有加密后的结果可以放入 Git；明文必须立即安全删除。

### 密钥备份

加密后的密钥与控制器密钥绑定。重建集群时会生成新密钥，除非恢复旧密钥，否则无法解密现有的 `SealedSecret`。应在仓库之外备份该密钥，并将其保存在密码管理器中，绝不能存入 Git：

```bash
kubectl -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealing-key-backup.yaml   # 存放在 Git 仓库之外
```

加密密钥已从 VPS 复制到外部存储；确认完成异地备份后，主机上的副本已安全删除。

### 轮换

轮换加密密钥时，让控制器生成新密钥（控制器会定期生成，也可手动触发），然后使用新的公钥重新加密所有密钥并提交结果。轮换单个应用密钥时，在明文模板中修改其值，重新加密并提交。新密钥应用后，旧的加密值即失效。

## 全面使用 TLS

所有公网主机均通过 HTTPS 提供服务，TLS 证书由 cert-manager 使用 HTTP-01 自动签发和续期（参见 [ADR-004](../adr/004-cert-manager-http01-vs-dns01.md)）。TLS 仅在 Traefik 处终止一次；后端在集群内使用普通 HTTP，因为外部流量只能通过 Ingress 进入，所以这种方式是安全的。WebSocket 和 `wss` 流量也使用相同的 TLS 通道。80 端口仅用于 ACME 挑战和将 HTTP 重定向到 HTTPS。

## 公网与集群内部服务

只有配置了带 `host:` 规则的 `Ingress` 的服务才能从互联网访问。其他所有服务都仅在集群内部，通过 Pod 网络访问。

- **应用的 `/metrics` 端点**通过集群内部的 Service 端口提供，并由 Prometheus 通过 `ServiceMonitor` 抓取。它们经过有意配置，不会暴露到公网 Ingress。

## 命名空间隔离与 `Prune=false`

每个工作负载都位于独立命名空间（`9router`、`monitoring`、`cert-manager`、`argocd`），以限制安全事件的影响范围并划分 RBAC 权限。每个受管理的命名空间都带有 `argocd.argoproj.io/sync-options: Prune=false`（`platform/config/namespaces.yaml`），因此即使命名空间声明被移除，ArgoCD 的自动清理也不会删除正在使用的命名空间及其全部资源。这是为了防止一行配置变更造成破坏而设置的防护措施（参见 [ADR-002](../adr/002-argocd-app-of-apps-sync-waves.md)）。

## 已实施的主机加固措施

以下措施已于 2026-07-23 直接在 VPS 上实施：

- **SSH 仅允许密钥认证。** 由于曾启用密码认证，且 root 密码已泄露，现已在 `/etc/ssh/sshd_config.d/00-security-hardening.conf` 中设置 `PasswordAuthentication no`、`PermitRootLogin prohibit-password` 和 `KbdInteractiveAuthentication no`。已确认密钥认证仍正常工作，并确认密码认证已禁用。（原风险：高。已修复。）
- **node-exporter（9100）已通过防火墙限制为仅 Pod 网络可访问。** 此前该服务未经身份验证便暴露在公网，会泄露主机 CPU、内存、磁盘和网络指标。现已配置针对性 iptables 规则，仅 ACCEPT 来自 `10.42.0.0/16`（Pod 网络）和 `127.0.0.0/8` 的流量，并 DROP 其他所有流量；规则通过 netfilter-persistent 持久化。已验证外部访问受阻，且 Prometheus 抓取仍正常（`up{job="node-exporter"} = 1`）。（原风险：中。已修复。）
- **已安装 fail2ban**，并配置 sshd jail（允许重试 4 次，封禁 1 小时），作为纵深防御措施。

## 待处理事项

- **轮换旧的 VPS root 密码。** SSH 切换为仅允许密钥认证之前，该密码曾经泄露。即使现在已禁用密码登录，也仍需轮换该密码。

## 已接受的单节点权衡

在仅有一个网卡的 VPS 上，节点 IP 就是公网 IP，因此 kubelet（10250）和 k3s API（6443）可从互联网访问。两者都需要身份验证，未提供凭据时会返回 `401`，因此这是低风险暴露，并非可以直接访问。直接在主机层面阻断这些端口存在风险，因为控制平面流量也经过同一网卡；配置错误可能导致集群无法访问。

建议通过**云服务商级别的防火墙**（云控制台）实施纵深防御：将 6443 和 10250 限制为仅允许已知管理员 IP 访问，同时保持 80 和 443 端口开放。这是目前剩下的一项有实际意义且不会危及控制平面的加固措施，也是选择在单台公网节点而非私有控制平面上运行 Kubernetes 所必须接受的现实代价。该环境没有高可用能力，除命名空间隔离外也没有网络策略引擎；对于仅有 1 个 vCPU 的家庭实验室环境，这是经过权衡后接受的取舍。
