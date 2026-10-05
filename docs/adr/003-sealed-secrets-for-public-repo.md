# ADR-003：使用 Sealed Secrets 安全地在公共仓库中管理密钥

**状态：** 已接受 · **日期：** 2026-07-23

## 背景

本仓库是公开的，这也是我们的目标：它既是作品集项目，也是一份供他人阅读的参考资料。GitOps 还要求集群所需的一切都存放在 Git 中，包括密钥（数据库密码、JWT 签名密钥、Redis 密码、LiveKit API 密钥以及腾讯云 COS 备份凭据）。普通 Kubernetes `Secret` 对象仅使用 Base64 编码，并未加密，因此将其提交到公开仓库会泄露密钥。

我们考虑了以下方案：使用外部密钥管理器（Vault、云 KMS、使用云密钥的 SOPS）；在仓库之外引导密钥（手动应用密钥，绝不提交）；以及使用 Sealed Secrets。

## 决策

采用 **Bitnami Sealed Secrets**。

- 集群中的控制器（位于 `kube-system` 的 `sealed-secrets-controller`）持有一对非对称密钥。公钥用于加密，私钥用于解密。
- `kubeseal` CLI 将普通 `Secret` 加密为 `SealedSecret` 自定义资源，只有本集群的控制器能够解密。加密后的资源可以安全地提交到公开仓库。
- ArgoCD 应用 `SealedSecret` 后，控制器会在集群内将其解密为普通 `Secret`，供 Pod 按常规方式挂载。
- 无需外部服务或云服务依赖，也没有月度费用。信任根是一把保存在集群中的密钥。

加密后的密钥存放在每个应用的 `apps/xxxx/sealed-secrets.yaml`  中。明文模板存放在 `docs/examples/`，其中仅包含占位值。

## 后果

- 加密后的密钥与控制器的密钥绑定。重建集群时会生成新密钥，因此除非恢复原密钥，否则无法解密已有的密钥资源。必须在仓库之外（例如密码管理器中）备份用于加密的密钥，绝不能提交到仓库。备份、恢复和轮换流程请参见安全文档。
- 加密是工作流中的手动步骤：在 `/tmp` 中编辑明文模板、运行 `kubeseal`、提交加密结果，然后彻底删除明文。绝不能提交明文密钥。
- COS 备份凭据（`cos-backup-credentials`）也采用相同方式加密；Secret ID 和 Secret Key 的权限必须限制为仅访问备份存储桶。
- 由于 Sealed Secrets 控制器是 wave-0 依赖项，挂载其解密结果的应用 Pod 会等到解密成功后才启动（参见 ADR-002）。
