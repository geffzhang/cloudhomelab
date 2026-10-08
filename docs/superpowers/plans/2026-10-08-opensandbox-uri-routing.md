# OpenSandbox URI 路由实施计划

> **面向自动化执行者：** 按任务逐项执行本计划；每步使用复选框跟踪。

**目标：** 将 OpenSandbox 网关路由模式设为 URI，并说明相关 Ingress 和域名配置。

**方案：** 只改动渲染后的 server ConfigMap 中的 TOML 路由模式，以及 OpenSandbox 运维指南。保留现有 gateway Ingress 模式和 `sandbox.lab.csharpkit.com` 域名，不改动 Gateway 工作负载或 RBAC。

**技术栈：** Kubernetes YAML、TOML、Python 3、PyYAML。

## 全局约束

- `gateway.route.mode` 必须为 `"uri"`。
- `ingress.mode` 必须保持 `"gateway"`。
- `gateway.address` 保持 `sandbox.lab.csharpkit.com`。
- 只修改 server 配置与 OpenSandbox 运维指南。

---

### 任务 1：切换 URI 路由并同步运维说明

**文件：**
- 修改：`apps/opensandbox/server.yaml` 中 ConfigMap 的 `data.config.toml`
- 修改：`docs/operations/adding-opensandbox.md`

**输入：** 当前配置包含 `ingress.mode = "gateway"`、域名 `sandbox.lab.csharpkit.com` 和 `gateway.route.mode = "header"`。

**输出：** 配置保留 gateway 模式及域名，路由模式为 `"uri"`；运维指南说明这些设置需配合使用，网关域名须与外部 Ingress 域名一致。

- [ ] **步骤 1：运行基线断言，确认当前路由值不符合目标**

在仓库根目录运行：

```powershell
@'
import tomllib
from pathlib import Path
import yaml

path = Path("apps/opensandbox/server.yaml")
docs = [doc for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")) if doc]
configmap = next(doc for doc in docs if doc.get("kind") == "ConfigMap" and doc["metadata"]["name"] == "opensandbox-server-config")
config = tomllib.loads(configmap["data"]["config.toml"])
assert config["ingress"]["mode"] == "gateway"
assert config["ingress"]["gateway"]["address"] == "sandbox.lab.csharpkit.com"
assert config["ingress"]["gateway"]["route"]["mode"] == "header"
'@ | python -
```

预期：断言通过，记录配置原值为 `header`。

- [ ] **步骤 2：将 server 配置中的路由模式改为 URI**

只将 `apps/opensandbox/server.yaml` 的内嵌 TOML 行改为：

```toml
gateway.route.mode = "uri"
```

保持同一配置段中的以下值不变：

```toml
mode = "gateway"
gateway.address = "sandbox.lab.csharpkit.com"
```

- [ ] **步骤 3：更新运维指南**

在 `docs/operations/adding-opensandbox.md` 增加一段路由配置说明，明确列出：

```toml
[ingress]
mode = "gateway"
gateway.address = "sandbox.lab.csharpkit.com"
gateway.route.mode = "uri"
```

同时说明 `gateway.address` 应与配置的 Ingress 域名匹配。

- [ ] **步骤 4：验证渲染清单和文档**

运行以下断言：

```powershell
@'
import tomllib
from pathlib import Path
import yaml

path = Path("apps/opensandbox/server.yaml")
docs = [doc for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")) if doc]
configmap = next(doc for doc in docs if doc.get("kind") == "ConfigMap" and doc["metadata"]["name"] == "opensandbox-server-config")
config = tomllib.loads(configmap["data"]["config.toml"])
assert config["ingress"]["mode"] == "gateway"
assert config["ingress"]["gateway"]["address"] == "sandbox.lab.csharpkit.com"
assert config["ingress"]["gateway"]["route"]["mode"] == "uri"

guide = Path("docs/operations/adding-opensandbox.md").read_text(encoding="utf-8")
assert 'gateway.route.mode = "uri"' in guide
assert "sandbox.lab.csharpkit.com" in guide
'@ | python -
git diff --check
```

预期：Python 断言通过，`git diff --check` 无输出且退出码为 0。
