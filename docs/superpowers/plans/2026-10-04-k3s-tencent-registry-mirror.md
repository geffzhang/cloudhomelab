# Configure the Tencent K3s Registry Mirror Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make bootstrap configure Tencent Cloud's Docker Hub mirror for K3s containerd on both fresh and already-installed nodes.

**Architecture:** Put the registry configuration logic in a small sourceable Bash helper so it can be tested without running host hardening or installing K3s. Bootstrap calls it before the K3s install/skip branch; the runbook explains the runtime mirror separately from the K3s installer mirror.

**Tech Stack:** Bash, systemd, K3s `registries.yaml`.

## Global Constraints

- Use `https://mirror.ccs.tencentyun.com` for the `docker.io` mirror.
- Create `/etc/rancher/k3s/registries.yaml` only when it does not exist.
- Preserve existing registry configuration; if it lacks the Tencent mirror, fail with an actionable manual-merge message.
- Write the file before a fresh K3s install; when adding it to an existing K3s installation, restart the installed service.
- Do not run the bootstrap installer during validation.

---

### Task 1: Add and test idempotent registry configuration

**Files:**
- Create: `bootstrap/k3s-registry.sh`
- Create: `tests/bootstrap/k3s-registry.sh`

**Interfaces:**
- Produces: `configure_k3s_registry_mirror <config-file> <k3s-installed>`; returns success after creating a missing config or recognizing an existing Tencent mirror. Returns nonzero without modifying an incompatible existing config or when service restart cannot be completed.

- [x] **Step 1: Write a failing shell test**

Create a test script that sources `bootstrap/k3s-registry.sh`, uses a temporary directory for configuration, and places a mock `systemctl` first in `PATH`. Cover:
  1. Missing file with `k3s-installed=false`: create the exact `docker.io` mirror YAML and do not call `systemctl`.
  2. Existing valid mirror with `k3s-installed=true`: leave file contents unchanged and do not restart.
  3. Existing config without the mirror: return nonzero and preserve file contents.
  4. Missing file with `k3s-installed=true`: create the config and restart `k3s` if its unit exists, otherwise `k3s-agent`.
  5. Existing K3s installation with neither unit: return nonzero with an error; do not create a configuration that cannot be activated.

- [x] **Step 2: Run the shell test and confirm it fails**

Run: `bash tests/bootstrap/k3s-registry.sh`

Expected: nonzero because `bootstrap/k3s-registry.sh` does not yet exist.

- [x] **Step 3: Implement the sourceable helper**

Implement `configure_k3s_registry_mirror <config-file> <k3s-installed>` with these rules:
  - Detect the expected endpoint under the `docker.io` mirror stanza in an existing file and return without modifying or restarting it.
  - If an existing file does not include that mirror, print the file path and a manual-merge instruction to standard error, then return nonzero.
  - When the file is missing and K3s is already installed, verify the `k3s.service` or `k3s-agent.service` unit exists before writing. Prefer `k3s.service`; use `k3s-agent.service` otherwise.
  - Create the parent directory with mode `0755` and write:

```yaml
mirrors:
  docker.io:
    endpoint:
      - "https://mirror.ccs.tencentyun.com"
```

  - If K3s is already installed, restart the selected service after writing. If restart fails, print the service name and a manual recovery command to standard error, then return nonzero.

- [x] **Step 4: Run the shell test and confirm it passes**

Run: `bash tests/bootstrap/k3s-registry.sh`

Expected: all five scenarios pass with exit code 0.

---

### Task 2: Wire the helper into bootstrap and document the behavior

**Files:**
- Modify: `bootstrap/install.sh`
- Modify: `docs/RUNBOOK.md`
- Test: `tests/bootstrap/k3s-registry.sh`

**Interfaces:**
- Consumes: `configure_k3s_registry_mirror <config-file> <k3s-installed>` from Task 1.
- Produces: Bootstrap configures the runtime image mirror before fresh install or before continuing with an existing K3s cluster; the runbook explains setup and restart behavior.

- [x] **Step 1: Source helper and ensure config before install check**

Source the helper relative to `bootstrap/install.sh`, determine whether `k3s` is installed once, and call:

```bash
configure_k3s_registry_mirror /etc/rancher/k3s/registries.yaml "$K3S_INSTALLED"
```

Do this before the installer/skip branch. Keep the existing Rancher China installer command and installed-K3s skip behavior unchanged.

- [x] **Step 2: Update the Chinese runbook**

After the bootstrap instructions in `docs/RUNBOOK.md`, explain that `INSTALL_K3S_MIRROR=cn` mirrors K3s installation artifacts, while `registries.yaml` directs Docker Hub image pulls through Tencent Cloud. Document that a newly created config restarts the installed K3s service, may briefly interrupt workloads, and that existing registry configuration is preserved and must be manually merged if it lacks the Tencent endpoint.

- [x] **Step 3: Run targeted validation**

Run:

```bash
bash -n bootstrap/install.sh
bash -n bootstrap/k3s-registry.sh
bash -n tests/bootstrap/k3s-registry.sh
bash tests/bootstrap/k3s-registry.sh
git diff --check
```

Expected: all commands exit 0; all five test scenarios pass. Do not run `bootstrap/install.sh`.

- [x] **Step 4: Commit the implementation**

```bash
git add bootstrap/install.sh bootstrap/k3s-registry.sh docs/RUNBOOK.md tests/bootstrap/k3s-registry.sh
git commit -m "fix: configure Tencent mirror for K3s images" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```
