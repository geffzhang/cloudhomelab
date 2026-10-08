# OpenSandbox 独立网关域名实施计划

> **面向自动化执行者：** 按任务逐项执行本计划；每步使用复选框跟踪。

**目标：** 为 URI 路由沙箱流量添加专属 HTTPS 域名 `sandbox-gateway.lab.csharpkit.com`，并同步 server 发布地址。

**方案：** 新增独立 Ingress，将专属主机名转发到 `opensandbox-ingress-gateway:80` 并使用现有 HTTP-01 ClusterIssuer 签发 TLS。更新 server 内嵌 TOML 和运维指南；保留现有 API Ingress 及已经存在的 gateway URI 模式参数。

**技术栈：** Kubernetes Ingress YAML、TOML、Python 3、PyYAML。

## 全局约束

- 新网关主机名为 `sandbox-gateway.lab.csharpkit.com`。
- URI 模式下 `gateway.address` 使用普通主机名，不带协议或 `*.` 前缀。
- 网关 Ingress 后端为 `opensandbox-ingress-gateway` Service 的 80 端口。
- 证书由 `letsencrypt-prod` HTTP-01 签发到 `opensandbox-gateway-tls`。
- 保留 `sandbox.lab.csharpkit.com` 到 `opensandbox-server:80` 的既有 API Ingress。
- 不修改现有 gateway `--mode=uri` 的工作区改动。

---

### 任务 1：添加专属网关入口并同步 server 配置

**文件：**
- 创建：`apps/opensandbox/gateway-ingress.yaml`
- 修改：`apps/opensandbox/server.yaml` 内 `opensandbox-server-config` ConfigMap 的 `data.config.toml`
- 修改：`docs/operations/adding-opensandbox.md`
- 保持不变：`apps/opensandbox/ingress.yaml` 现有 API Ingress
- 保持不变：`apps/opensandbox/gateway.yaml` 当前 `--mode=uri` 参数

**输入：** DNS 已有 `*.lab.csharpkit.com` A 记录指向节点；现有 ClusterIssuer 为 HTTP-01 `letsencrypt-prod`；gateway Service 端口为 80。

**输出：** 新建专用 Ingress 与 TLS Secret，server 发布地址改为新主机名，运维指南记录 API 与 gateway 两个域名的用途。

- [ ] **步骤 1：验证当前基线并记录既有行为**

在仓库根目录运行：

```powershell
@'
import tomllib
from pathlib import Path
import yaml

def docs(path):
    return [doc for doc in yaml.safe_load_all(Path(path).read_text(encoding="utf-8")) if doc]

server = next(doc for doc in docs("apps/opensandbox/server.yaml")
              if doc.get("kind") == "ConfigMap" and doc["metadata"]["name"] == "opensandbox-server-config")
config = tomllib.loads(server["data"]["config.toml"])
assert config["ingress"]["gateway"]["address"] == "sandbox.lab.csharpkit.com"
assert config["ingress"]["gateway"]["route"]["mode"] == "uri"

api_ingress = next(doc for doc in docs("apps/opensandbox/ingress.yaml")
                   if doc.get("kind") == "Ingress" and doc["metadata"]["name"] == "opensandbox-server")
assert api_ingress["spec"]["rules"][0]["host"] == "sandbox.lab.csharpkit.com"
assert api_ingress["spec"]["rules"][0]["http"]["paths"][0]["backend"]["service"]["name"] == "opensandbox-server"

gateway = next(doc for doc in docs("apps/opensandbox/gateway.yaml")
               if doc.get("kind") == "Service" and doc["metadata"]["name"] == "opensandbox-ingress-gateway")
assert gateway["spec"]["ports"][0]["port"] == 80
'@ | python -
```

预期：断言通过，确认 server 和 gateway API Service 的当前路由信息。

- [ ] **步骤 2：添加独立 gateway Ingress**

创建 `apps/opensandbox/gateway-ingress.yaml`，内容如下：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opensandbox-gateway
  namespace: opensandbox-system
  annotations:
    argocd.argoproj.io/sync-wave: "5"
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: traefik
  rules:
    - host: sandbox-gateway.lab.csharpkit.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: opensandbox-ingress-gateway
                port:
                  number: 80
  tls:
    - hosts: [sandbox-gateway.lab.csharpkit.com]
      secretName: opensandbox-gateway-tls
```

- [ ] **步骤 3：同步 server 发布域名**

在 `apps/opensandbox/server.yaml` 的内嵌 TOML 中，只将 gateway address 改为：

```toml
gateway.address = "sandbox-gateway.lab.csharpkit.com"
```

保持 `ingress.mode = "gateway"` 和 `gateway.route.mode = "uri"` 不变。

- [ ] **步骤 4：更新 OpenSandbox 运维指南**

在 `docs/operations/adding-opensandbox.md` 更新网关路由说明，明确：

- `sandbox.lab.csharpkit.com` 用于 server API。
- `sandbox-gateway.lab.csharpkit.com` 用于 URI 路由的沙箱流量，指向 `opensandbox-ingress-gateway:80`。
- gateway address 使用不带 scheme 的具体主机名；该域名由现有 `*.lab.csharpkit.com` DNS A 记录解析，并由 `letsencrypt-prod` 按具体主机名签发 TLS。

- [ ] **步骤 5：验证所有清单和跨文件配置**

运行以下断言：

```powershell
@'
import tomllib
from pathlib import Path
import yaml

def docs(path):
    return [doc for doc in yaml.safe_load_all(Path(path).read_text(encoding="utf-8")) if doc]

server = next(doc for doc in docs("apps/opensandbox/server.yaml")
              if doc.get("kind") == "ConfigMap" and doc["metadata"]["name"] == "opensandbox-server-config")
config = tomllib.loads(server["data"]["config.toml"])
assert config["ingress"]["mode"] == "gateway"
assert config["ingress"]["gateway"]["address"] == "sandbox-gateway.lab.csharpkit.com"
assert config["ingress"]["gateway"]["route"]["mode"] == "uri"

gateway_ingress = docs("apps/opensandbox/gateway-ingress.yaml")[0]
assert gateway_ingress["spec"]["rules"][0]["host"] == config["ingress"]["gateway"]["address"]
backend = gateway_ingress["spec"]["rules"][0]["http"]["paths"][0]["backend"]["service"]
assert backend == {"name": "opensandbox-ingress-gateway", "port": {"number": 80}}
assert gateway_ingress["metadata"]["annotations"]["cert-manager.io/cluster-issuer"] == "letsencrypt-prod"
assert gateway_ingress["spec"]["tls"][0]["hosts"] == [config["ingress"]["gateway"]["address"]]
assert gateway_ingress["spec"]["tls"][0]["secretName"] == "opensandbox-gateway-tls"

api_ingress = next(doc for doc in docs("apps/opensandbox/ingress.yaml")
                   if doc.get("kind") == "Ingress" and doc["metadata"]["name"] == "opensandbox-server")
assert api_ingress["spec"]["rules"][0]["host"] == "sandbox.lab.csharpkit.com"
assert api_ingress["spec"]["rules"][0]["http"]["paths"][0]["backend"]["service"]["name"] == "opensandbox-server"

guide = Path("docs/operations/adding-opensandbox.md").read_text(encoding="utf-8")
assert "sandbox-gateway.lab.csharpkit.com" in guide
assert "sandbox.lab.csharpkit.com" in guide
'@ | python -
git diff --check
```

预期：Python 断言通过，`git diff --check` 无输出且退出码为 0。
