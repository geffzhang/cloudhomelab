# ADR-006：每晚备份到 Tencent COS

**状态：** 已接受 · **日期：** 2026-07-23

## 背景

集群为单节点架构，使用节点本地存储（local-path）。由于没有复制卷，也没有高可用，节点丢失或重建时，磁盘上的所有数据都会丢失。应用数据（ChessKernel PostgreSQL 数据库）必须能够在节点丢失后保留下来，并可恢复到新集群中。备份目标的成本应尽可能低，并且能通过标准工具从集群内部访问。

可选方案包括：云服务商托管备份、S3 兼容对象存储，或将数据库转储复制到另一台主机。选择 Tencent COS 是因为其 S3 兼容 API 可通过标准的 `aws-cli` 使用，并且备份保存在所选的云账户中。

## 决策

运行一个**每晚执行的 `CronJob`，使用 `pg_dump` 导出 ChessKernel 数据库、通过 gzip 压缩，然后经由 S3 兼容 API 上传到 Tencent COS**，并保留最近 **14 天**的备份（`apps/chesskernel/backup-cronjob.yaml`）。

- 执行计划为 `0 3 * * *`（UTC 时间 03:00），并设置 `concurrencyPolicy: Forbid`，以避免任务重叠运行。
- 该任务运行 `postgres:16-alpine` 容器，安装 `aws-cli`，导出 `chesskernel` 数据库，并使用存储桶所在区域的终结点，将 gzip 压缩后的转储文件上传到 COS 对应的路径前缀下。
- 上传前会根据文件时效、对象数量和总大小上限清理旧备份，从而限制保留周期和存储用量。
- COS 凭据（Secret ID、Secret Key、区域和存储桶）来自 Sealed Secret `cos-backup-credentials`（参见 ADR-003）。

恢复操作是运维手册中记录的手动流程（`gunzip | kubectl exec ... psql`）。

## 后果

- 节点丢失后，数据仍可恢复：重建集群后，可通过 Git 恢复清单，并从 COS 获取最新数据库转储文件。这使得即使使用 local-path 存储，节点也可以被重建替换。
- 只有经过实际恢复验证的备份才值得信赖。运维手册要求每季度将备份恢复到临时数据库中进行演练；从未成功恢复过的转储文件不能算作有效备份。
- 通过按日期清理对象，备份保留期限为 14 天，不保留更早的历史记录。这对家庭实验室环境可以接受，也可通过调整截止日期延长保留时间。
- 集群中的 COS Secret ID 和 Secret Key 属于凭据，必须仅授予访问备份存储桶所需的最小权限。
- 仅备份 PostgreSQL。Redis 是可重新生成的缓存；Grafana/Prometheus 数据属于可观测性历史记录，而非应用数据，因此按设计不纳入备份。
