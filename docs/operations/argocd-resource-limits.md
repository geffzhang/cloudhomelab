# 限制 ArgoCD 组件资源

上游 ArgoCD `install.yaml` 默认不为任何组件设置 `resources.requests`/`limits`。在 2 vCPU / 4 GB 内存的节点上，一个失控的 `argocd-application-controller` 或 `argocd-repo-server` 就会把集群资源全部挤占。

`bootstrap/install.sh` 在新装时会自动打补丁（`── 2b` 段落）。若集群已经跑着 ArgoCD，需要一次性应用补丁。

## 一次性应用

一次性补丁：根据 Pod 列表运行 `kubectl patch`。使用 strategic merge 按容器名匹配，幂等。

```bash
patch_argocd_resources() {
  local kind=$1 name=$2 cname=$3 cpu_req=$4 mem_req=$5 cpu_lim=$6 mem_lim=$7
  kubectl -n argocd patch "${kind}/${name}" --type=strategic -p "$(cat <<EOF
{
  "spec":{"template":{"spec":{"containers":[{
    "name":"${cname}",
    "resources":{
      "requests":{"cpu":"${cpu_req}","memory":"${mem_req}"},
      "limits":{"cpu":"${cpu_lim}","memory":"${mem_lim}"}
    }
  }]}}}
}
EOF
)"
}
patch_argocd_resources statefulset argocd-application-controller    argocd-application-controller 100m 256Mi 500m 512Mi
patch_argocd_resources deployment  argocd-repo-server                 argocd-repo-server                  50m 128Mi 300m 384Mi
patch_argocd_resources deployment  argocd-server                      argocd-server                       50m 128Mi 300m 384Mi
patch_argocd_resources deployment  argocd-redis                       redis                               50m  64Mi 200m 128Mi
patch_argocd_resources deployment  argocd-applicationset-controller   argocd-applicationset-controller    25m  64Mi 200m 256Mi
```

应用后等待滚动完成：

```bash
kubectl -n argocd rollout status statefulset argocd-application-controller --timeout=300s
kubectl -n argocd rollout status deployment argocd-repo-server --timeout=300s
kubectl -n argocd rollout status deployment argocd-server --timeout=300s
kubectl -n argocd rollout status deployment argocd-redis --timeout=300s
kubectl -n argocd rollout status deployment argocd-applicationset-controller --timeout=300s
```

## 验证

- `kubectl describe statefulset argocd-application-controller -n argocd | grep -A6 Requests` 应当看到 CPU/内存 requests 与 limits。
- `kubectl get pods -n argocd -o custom-columns=NAME:.metadata.name,REQ-CPU:.spec.containers[0].resources.requests.cpu,REQ-MEM:.spec.containers[0].resources.requests.memory` 显示 5 个 Pod 全部有 requests/limits。

## 配置依据

| Workload | Kind | Container | 请求 CPU | 请求内存 | 限制 CPU | 限制内存 |
|---|---|---|---|---|---|---|
| `argocd-application-controller` | StatefulSet | `argocd-application-controller` | 100m | 256Mi | 500m | 512Mi |
| `argocd-repo-server` | Deployment | `argocd-repo-server` | 50m | 128Mi | 300m | 384Mi |
| `argocd-server` | Deployment | `argocd-server` | 50m | 128Mi | 300m | 384Mi |
| `argocd-redis` | Deployment | `redis` | 50m | 64Mi | 200m | 128Mi |
| `argocd-applicationset-controller` | Deployment | `argocd-applicationset-controller` | 25m | 64Mi | 200m | 256Mi |
| 合计 | | | 275m | 640Mi | 1.5 | 1.66Gi |

合计请求 275m / 640Mi，在 1 vCPU / 4 GB 节点预算内仍有空间给控制平面和业务应用。

## 为什么不用 GitOps 管控 ArgoCD 自身

见 [ADR-002](../adr/002-argocd-app-of-apps-sync-waves.md)：ArgoCD 配置（包括资源限制）通过 `bootstrap/install.sh` 在运行时打补丁，不写入清单。后续重装会复用脚本中的补丁段，保持幂等。
