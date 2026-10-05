# ADR-001：选择 k3s，而非完整或托管 Kubernetes

**状态：** 已接受 · **日期：** 2026-07-23

## 背景

平台运行在一台腾讯云轻量服务器上，配置为 2 个 vCPU 和 4 GB 内存（114.132.200.41）。使用 Kubernetes 是本项目的明确目标：它既是学习和作品集展示的实践，也是一种部署机制。需要决定的是，哪种 Kubernetes 发行版适合如此小型的节点。

我们考虑了三种方案：

- **完整的上游 Kubernetes（kubeadm）。** 需要分别安装和维护 etcd、kube-apiserver、controller-manager、scheduler 以及 CNI。在运行任何工作负载之前，控制平面本身就需要超过 2 GB 内存和多个 CPU 核心。
- **托管 Kubernetes（EKS/GKE/AKS 或托管控制平面）。** 虽然免去了管理控制平面的负担，但会产生每月费用、使集群脱离我完全拥有的机器，也无法让我深入了解希望学习的内部机制。
- **k3s。** 这是由 CNCF 毕业、完全符合 Kubernetes 标准的发行版，并打包为单个二进制文件。它默认使用 SQLite 替代 etcd，在一个进程中运行控制平面和 kubelet，并内置 Traefik、CoreDNS、本地路径存储和服务负载均衡器。

## 决策

使用单节点 **k3s**，并采用其内置组件。

- 控制平面约占用 600 MB，因此在 4 GB 内存的节点上，仍有余量运行 ArgoCD、监控系统和两个应用。
- 其 API 与 Kubernetes API 相同，因此后续迁移到完整集群时，所有清单、ADR 和技能经验都可以沿用。
- 内置的 Traefik、CoreDNS 和本地路径存储省去了三个安装步骤，也减少了三项需要维护的组件。
- 由于数据存储使用 SQLite 而非 etcd，监控栈会禁用 `kubeEtcd` 抓取目标（参见 `platform/monitoring/values.yaml`）。

## 后果

- 单节点意味着无法实现高可用。我们接受这一点；按照定义，单台 VPS 无法实现高可用（关于节点丢失后如何保留数据，请参见 ADR-006）。
- 在只有一个网卡的 VPS 上，节点 IP 与公网 IP 相同，因此 kubelet（10250）和 API（6443）可从互联网访问。它们需要身份验证，但建议再通过云服务商级别的防火墙增加纵深防御（参见安全文档）。
- 控制平面组件在单个 k3s 进程中运行，不会提供独立的抓取端点，因此关闭 `kubeControllerManager`、`kubeScheduler` 和 `kubeProxy` 监控目标，以避免产生无用告警或指标噪声。
- 存储位于节点本地（local-path）。重建后的节点初始为空，需要通过 Git 和每晚备份恢复数据，而不是从复制卷恢复。
