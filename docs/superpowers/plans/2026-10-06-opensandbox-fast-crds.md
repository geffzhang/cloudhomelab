# OpenSandbox Fast CRDs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add all four upstream `sandbox.fast.io` CRDs to the OpenSandbox manifests and accurately document the installed CRDs.

**Architecture:** Render only the upstream base Chart CRD template from OpenSandbox `release-1.1.0` and append its four `sandbox.fast.io` documents to the existing rendered manifest. Normalize the upstream CRD bundle's CRLF line endings in a temporary Chart copy before rendering because its template splits on LF-only separators; leave the upstream checkout untouched. Update the runbook's CRD inventory and verification command.

**Tech Stack:** Helm 3, Kubernetes `CustomResourceDefinition` v1, Python 3 with the already-installed PyYAML package, PowerShell.

## Global Constraints

- Upstream source version is OpenSandbox `release-1.1.0`.
- Add all four `sandbox.fast.io` CRDs: `sandboxes`, `sandboxtemplates`, `sandboxesnapshots`, and `sandboxpools`.
- Preserve the complete upstream `v1alpha2` schemas and rendered CRD metadata.
- Do not modify the Argo CD Application, existing RBAC, controller, services, workloads, or the upstream OpenSandbox checkout.
- Do not add dependencies or permanent test tooling.

---

### Task 1: Add and verify the upstream fast-sandbox CRDs

**Files:**
- Modify: `apps/opensandbox/base.yaml`
- Modify: `docs/operations/adding-opensandbox.md`
- Do not modify: `argocd/platform-opensandbox.yaml`
- Source only: `E:\GitHub\OpenSandbox\manifests\charts\base\`

**Interfaces:**
- Consumes: OpenSandbox base Chart `release-1.1.0`, including `templates/crds.yaml`, `values.yaml`, and `files/fast-sandbox-crds.yaml`.
- Produces: Seven CRDs in `apps/opensandbox/base.yaml`, with exactly four in API group `sandbox.fast.io`; updated operational inventory and CRD check command.

- [ ] **Step 1: Run the expected-set assertion before changing the manifest**

Run from the repository root in PowerShell:

```powershell
@'
from pathlib import Path
import yaml

path = Path(r"apps\opensandbox\base.yaml")
documents = [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]
actual = {
    d["metadata"]["name"]
    for d in documents
    if d.get("kind") == "CustomResourceDefinition"
    and d["spec"]["group"] == "sandbox.fast.io"
}
expected = {
    "sandboxes.sandbox.fast.io",
    "sandboxtemplates.sandbox.fast.io",
    "sandboxesnapshots.sandbox.fast.io",
    "sandboxpools.sandbox.fast.io",
}
missing = expected - actual
assert not missing, f"Missing sandbox.fast.io CRDs: {sorted(missing)}"
'@ | python -
```

Expected before implementation: FAIL with all four CRD names listed as missing.

- [ ] **Step 2: Verify the pinned source and render its CRD template without touching the upstream checkout**

First verify that the Chart inputs used for this change match the pinned release:

```powershell
$files = @(
  'manifests/charts/base/files/fast-sandbox-crds.yaml',
  'manifests/charts/base/templates/crds.yaml',
  'manifests/charts/base/values.yaml',
  'manifests/charts/base/Chart.yaml'
)
git -C E:\GitHub\OpenSandbox diff --exit-code release-1.1.0 -- $files
```

Expected: exit code 0. The upstream checkout has an unrelated change to `files/crds.yaml`; leave it untouched and do not include its output in this task.

The fast-sandbox bundle is checked out with CRLF line endings while the Chart template splits on LF-only `\n---\n`. Render from a temporary copy with only that bundle normalized; do not change the upstream checkout:

```powershell
@'
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import yaml

source = Path(r"E:\GitHub\OpenSandbox\manifests\charts\base")
with tempfile.TemporaryDirectory(prefix="opensandbox-base-") as directory:
    chart = Path(directory) / "base"
    shutil.copytree(source, chart)
    bundle = chart / "files" / "fast-sandbox-crds.yaml"
    bundle.write_text(
        bundle.read_text(encoding="utf-8").replace("\r\n", "\n"),
        encoding="utf-8",
        newline="\n",
    )
    result = subprocess.run(
        [
            "helm",
            "template",
            "base",
            str(chart),
            "--namespace",
            "opensandbox-system",
            "--show-only",
            "templates/crds.yaml",
        ],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    chunks = [
        part.strip()
        for part in re.split(r"(?m)^---\s*$", result.stdout)
        if part.strip()
    ]
    rendered = [(yaml.safe_load(part), part) for part in chunks]
    fast = [(d, part) for d, part in rendered if d["spec"]["group"] == "sandbox.fast.io"]
    assert len(fast) == 4
    assert all(d["spec"]["versions"][0]["name"] == "v1alpha2" for d, _ in fast)
    assert all(
        d["metadata"]["annotations"]["helm.sh/resource-policy"] == "keep"
        for d, _ in fast
    )
    output = Path(__import__("os").environ["TEMP"]) / "opensandbox-fast-crds-rendered.yaml"
    output.write_text(
        "\n---\n".join(part for _, part in fast) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print("Rendered four sandbox.fast.io/v1alpha2 CRDs")
'@ | python -
```

Expected: `Rendered four sandbox.fast.io/v1alpha2 CRDs`; the four rendered documents are saved to `%TEMP%\opensandbox-fast-crds-rendered.yaml`.

- [ ] **Step 3: Append the four rendered documents to `base.yaml`**

Append the temporary rendered file without reformatting the existing manifest:

```powershell
@'
from pathlib import Path
import os

target = Path(r"apps\opensandbox\base.yaml")
rendered = Path(os.environ["TEMP"]) / "opensandbox-fast-crds-rendered.yaml"
current = target.read_bytes()
newline = b"\r\n" if b"\r\n" in current else b"\n"
documents = rendered.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", newline)
prefix = b"" if current.endswith(b"\n") else newline
target.write_bytes(current + prefix + b"---" + newline + documents)
'@ | python -
```

Expected: only the four Chart-rendered CRD documents are appended; the original three CRDs remain byte-for-byte unchanged.

- [ ] **Step 4: Update the OpenSandbox operations guide**

In `docs/operations/adding-opensandbox.md`, change the `base.yaml` inventory row to state that it contains seven CRDs: the existing `BatchSandbox`, `Pool`, and OpenSandbox `SandboxSnapshot`, plus fast-sandbox `Sandbox`, `SandboxTemplate`, `SandboxSnapshot`, and `SandboxPool`.

Change the CRD verification command from:

```bash
kubectl get crd | grep opensandbox
```

to:

```bash
kubectl get crd | grep -E 'sandbox\.(opensandbox|fast)\.io'
```

- [ ] **Step 5: Compare the local manifest's fast CRDs with the rendered upstream objects**

Run this assertion from the repository root. It normalizes the upstream source only in a temporary copy, renders the Chart, and compares each full fast CRD object with the local manifest:

```powershell
@'
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import yaml

source = Path(r"E:\GitHub\OpenSandbox\manifests\charts\base")
target = Path(r"apps\opensandbox\base.yaml")
with tempfile.TemporaryDirectory(prefix="opensandbox-verify-") as directory:
    chart = Path(directory) / "base"
    shutil.copytree(source, chart)
    bundle = chart / "files" / "fast-sandbox-crds.yaml"
    bundle.write_text(
        bundle.read_text(encoding="utf-8").replace("\r\n", "\n"),
        encoding="utf-8",
        newline="\n",
    )
    result = subprocess.run(
        [
            "helm",
            "template",
            "base",
            str(chart),
            "--namespace",
            "opensandbox-system",
            "--show-only",
            "templates/crds.yaml",
        ],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    rendered = [
        yaml.safe_load(part)
        for part in re.split(r"(?m)^---\s*$", result.stdout)
        if part.strip()
    ]

local = [
    d for d in yaml.safe_load_all(target.read_text(encoding="utf-8"))
    if d and d.get("kind") == "CustomResourceDefinition"
]
expected = {
    d["metadata"]["name"]: d
    for d in rendered
    if d["spec"]["group"] == "sandbox.fast.io"
}
actual = {
    d["metadata"]["name"]: d
    for d in local
    if d["spec"]["group"] == "sandbox.fast.io"
}
names = {
    "sandboxes.sandbox.fast.io",
    "sandboxtemplates.sandbox.fast.io",
    "sandboxesnapshots.sandbox.fast.io",
    "sandboxpools.sandbox.fast.io",
}
assert len(local) == 7, f"Expected 7 CRDs, got {len(local)}"
assert set(expected) == names, f"Unexpected rendered names: {sorted(expected)}"
assert set(actual) == names, f"Unexpected local names: {sorted(actual)}"
assert actual == expected, "Local fast-sandbox CRDs differ from Helm-rendered upstream objects"
assert all(d["spec"]["versions"][0]["name"] == "v1alpha2" for d in actual.values())
print("PASS: seven CRDs total; four fast CRDs exactly match the upstream render")
'@ | python -
```

Expected: `PASS: seven CRDs total; four fast CRDs exactly match the upstream render`.

- [ ] **Step 6: Check whitespace and inspect only the scoped changes**

Run:

```powershell
git diff --check
git status --short
```

Expected: no whitespace errors; `apps/opensandbox/base.yaml` and `docs/operations/adding-opensandbox.md` are the only modified implementation files. The plan file remains untracked unless explicitly added to the implementation commit.

- [ ] **Step 7: Commit the implementation**

```powershell
git add apps/opensandbox/base.yaml docs/operations/adding-opensandbox.md
git commit -m "fix(opensandbox): add fast-sandbox CRDs" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```
