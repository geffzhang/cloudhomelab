# K3s China Mirror Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install K3s from the Rancher China mirror during fresh-server bootstrap.

**Architecture:** In the existing fresh-install branch, download the mirror-hosted K3s install script and run it with `INSTALL_K3S_MIRROR=cn`. Preserve the already-installed skip branch and document the behavior in the Chinese runbook.

**Tech Stack:** Bash, K3s install script, Markdown.

## Global Constraints

- Change only the fresh-install branch in `bootstrap/install.sh`.
- Keep the existing `k3s`-already-installed skip behavior unchanged.
- Do not change the source or update behavior for an already-installed K3s cluster, and do not configure mirrors for application container images.
- Do not execute the installer during repository validation.

---

### Task 1: Use the Rancher China mirror in bootstrap

**Files:**
- Modify: `bootstrap/install.sh`
- Modify: `docs/RUNBOOK.md`

**Interfaces:**
- Consumes: The current `if ! command -v k3s` branch in the bootstrap script.
- Produces: Fresh K3s installs retrieve the installer from `https://rancher-mirror.rancher.cn/k3s/k3s-install.sh` and use its `cn` mirror setting; the runbook documents this behavior.

- [x] **Step 1: Change the installer command in the fresh-install branch**

Replace:

```bash
curl -sfL https://get.k3s.io | sh -
```

with:

```bash
curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | INSTALL_K3S_MIRROR=cn sh -
```

Leave the `else` branch and its “already installed, skipping” log unchanged.

- [x] **Step 2: Document mirror behavior in the runbook**

In `docs/RUNBOOK.md`, add a sentence after the bootstrap command explaining that a fresh K3s install uses the Rancher China mirror for channel metadata and K3s release files; existing installations are skipped by the script.

- [x] **Step 3: Validate shell syntax**

Run: `sh -n bootstrap/install.sh`
Expected: exit code 0 and no output. Do not run `bootstrap/install.sh`.

- [x] **Step 4: Verify the targeted command and whitespace**

Run: `rg -n "rancher-mirror\.rancher\.cn/k3s/k3s-install\.sh|INSTALL_K3S_MIRROR=cn" bootstrap/install.sh`
Expected: one match containing the mirror URL and environment setting.

Run: `git diff --check`
Expected: no whitespace errors.
