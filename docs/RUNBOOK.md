# 运维手册

本文介绍常用运维操作。以下步骤均假设你可以通过 SSH 登录 VPS，并且将
`kubectl` 视为 `k3s kubectl`（可设置别名：`alias kubectl='k3s kubectl'`）。

## 初始化新服务器或迁移集群

1. **DNS**：将通配符 A 记录 `*.lab.csharpkit.com` 指向新 VPS 的 IP。
2. **初始化**：
   ```bash
  git clone https://github.com/geffzhang/cloudhomelab && cd cloudhomelab
   sudo bash bootstrap/install.sh
   ```
  首次安装 k3s 时，脚本会使用 Rancher 中国镜像获取安装脚本、版本信息和安装文件；
  如果服务器已安装 k3s，则保持原有逻辑并跳过安装。
  这与容器镜像加速是两项独立配置：bootstrap 会在安装 k3s 前创建
  `/etc/rancher/k3s/registries.yaml`，将 Docker Hub（`docker.io`）镜像请求转发到
  腾讯云 `https://mirror.ccs.tencentyun.com`，以便拉取 `rancher/mirrored-pause` 等镜像。
  如果现有配置文件已包含该地址则保持不变；若文件存在但未配置该地址，脚本会停止并提示
  手动合并，不会覆盖现有仓库配置或凭据。对于已安装 k3s 的服务器，首次创建此配置后会
  自动重启对应的 `k3s` 或 `k3s-agent` 服务，Pod 可能短暂中断；首次安装则会在 k3s 启动
  前完成配置。
  初始化脚本还会自动加固主机，且可安全重复运行：配置 2 GB 交换空间、
   fail2ban、限制 node-exporter（9100 端口）的防火墙规则，以及仅允许 SSH
   密钥登录（只有在 `authorized_keys` 中存在公钥时才会启用，避免新服务器
   被锁在外面；添加密钥后重新运行脚本即可启用）。
3. **密钥**（仅在新集群首次启动时需要；Sealed Secrets 与集群密钥绑定）：
   重新密封密钥并提交，参见下文“密钥”一节。
4. **等待集群同步完成**：访问 `https://argo.lab.csharpkit.com`，确认所有应用
   均已就绪（绿色）。初始管理员密码请查看 install.sh 的输出。

目标：从头到尾在 30 分钟内完成。

## 密钥（Sealed Secrets）

在本地电脑上安装一次 kubeseal 命令行工具：`brew install kubeseal`，或从
[发布页](https://github.com/bitnami-labs/sealed-secrets/releases) 下载。

```bash
# 在 /tmp/secrets.yaml 中准备 Secret，填入真实值并设置应用对应的 name 和 namespace
kubeseal --controller-namespace kube-system --format yaml \
  < /tmp/secrets.yaml > apps/<app>/sealed-secrets.yaml
git add apps/<app>/sealed-secrets.yaml && git commit -m "chore: seal secrets" && git push
shred -u /tmp/secrets.yaml
```

**备份密封密钥**（重建集群后可用它复用现有 Sealed Secrets）：

```bash
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealing-key-backup.yaml   # 存放在 Git 仓库之外（例如密码管理器）
```

> 当前仓库未配置自动数据库备份任务。9Router 的持久化数据需另行制定备份方案。

## 部署应用新版本

自有应用的 CI 会在变更合并到 main 后将 `:latest` 镜像推送到 GHCR。只重启受影响
命名空间中实际存在的 Deployment：

```bash
kubectl -n <app> rollout restart deploy/<deployment>
```

9Router 使用第三方镜像 `decolua/9router:latest`，而不是 GHCR。通过
argocd-image-updater 自动更新镜像属于后续工作。

## 添加新项目

1. 在 `apps/<name>/` 下创建该项目所需的 Deployment、Service、Ingress、存储配置和
   Sealed Secrets。参考结构最接近的现有应用；不要默认每个应用都需要将客户端和服务端
   拆分为独立 Deployment。
2. 添加 `argocd/app-<name>.yaml`，以现有应用清单为模板，修改应用名称、路径和命名空间。
3. 推送变更。ArgoCD 会自动发现并部署；cert-manager 会为子域名签发 TLS 证书。
   通配符 DNS 已覆盖该子域名，因此无需修改 DNS，也无需 SSH 登录服务器。

## 9Router 推理可靠性

Claude Code 使用 `https://9router.lab.csharpkit.com/v1`。请求流经以下路径：

```text
Claude Code
-> 公网 DNS
-> Traefik TLS 入口
-> 9Router Service
-> 9Router pod
-> 所选模型服务提供方
```

9Router 固定使用经过审核的镜像摘要。`apps/9router/streaming.yaml` 为其 Traefik
后端配置了较长的响应头和空闲连接超时时间。Deployment 中也为上游连接、首个数据块
以及数据流停滞配置了足够长的超时时间，以支持耗时较长的推理请求。

检查当前状态：

```bash
kubectl -n 9router get pod,svc,ingress
kubectl -n 9router rollout status deploy/9router
curl -fsS https://9router.lab.csharpkit.com/api/health
curl -fsS https://9router.lab.csharpkit.com/api/version
kubectl -n 9router logs deploy/9router --since=1h | \
  grep -Ei '499|429|502|503|504|ECONNRESET|ResponseAborted|timeout|fetch failed'
```

根据故障发生的环节判断原因：

- 出现带有 `all accounts locked` 的 `429` 错误，表示模型服务提供方的配额问题，
  与 Traefik 无关。
- 出现带有 `invalid_grant` 的 `TOKEN_REFRESH` 错误，表示需要在 9Router 中重新连接
  服务提供方的 OAuth 授权。
- 9Router 日志中的 `ECONNRESET` 或 `ResponseAborted` 表示服务提供方或客户端的数据流
  已断开。
- 若 Traefik 有错误，但 9Router 没有对应请求日志，通常表示入口或网络故障。
- 部署中断后，只有在 rollout、外部健康检查、流式推理和测试后的日志检查全部通过时，
  才能认为部署成功。

升级或恢复前，备份 Deployment、Ingress 和 `/data/db/data.sqlite*`。如需回滚，可使用
保存的 YAML 恢复镜像或清单，然后执行相同的健康检查和数据流检查。切勿将凭据或数据库
副本写入 Git。

## 常见问题速查

| 现象 | 检查方法 |
|---|---|
| ArgoCD 中应用显示异常 | 执行 `kubectl -n <ns> describe pod ...`；常见原因是缺少 Sealed Secret |
| `applicationsets.argoproj.io` 报 `metadata.annotations: Too long` | 拉取包含修复的代码后重新运行 `sudo bash bootstrap/install.sh`；脚本使用 Server-Side Apply。不要删除或重建 CRD |
| 未签发 TLS 证书 | 执行 `kubectl describe certificate -A`；使用 HTTP-01 验证时，DNS 必须已解析到服务器 |
| 节点资源压力过高 | 在 Grafana 的 Homelab Overview 仪表板查看 VPS 区域；CPU 限流会优先在此处显示 |
| ArgoCD 界面响应较慢 | 所有服务共用 1 vCPU，同步期间变慢属于正常现象 |

## PixelHub 语音（LiveKit）

- **密钥**：按上文“密钥”一节的 kubeseal 流程，将
  `docs/examples/pixelhub-secrets.example.yaml` 密封为
  `apps/pixelhub/sealed-secrets.yaml`。`livekit-keys` 项的值应为 LIVEKIT_KEYS
  所需的 `"key: secret"` 组合字符串。
- **网络**：信令通过 Traefik 使用 `livekit.lab.csharpkit.com` 上的 WSS；WebRTC
  媒体流通过 hostPort 绕过入口：`7882/udp`（复用模式）和 `7881/tcp`（回退模式）。
  新服务器必须在安全组中放行这些端口。
- **验证**：执行 `curl -s https://livekit.lab.csharpkit.com` 应返回 LiveKit 的 OK 页面；
  LiveKit Pod 日志应显示 `"starting LiveKit server"`；在应用中开启语音的两个浏览器，
  当各自头像靠近时应能听到对方。
