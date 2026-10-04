# Argo CD CRD Server-Side Apply Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent Argo CD CRDs from exceeding Kubernetes' client-side apply annotation limit during bootstrap.

**Architecture:** Apply the existing Argo CD stable installation manifest using Server-Side Apply with conflict takeover. Keep the current manifest source and upgrade flow, and document the retry procedure without deleting CRDs or custom resources.

**Tech Stack:** Bash, `kubectl`/K3s, Argo CD installation YAML, Markdown.

## Global Constraints

- Keep the current Argo CD namespace, `stable` manifest URL, and install/upgrade flow unchanged.
- Do not delete or recreate CRDs or their custom resources.
- Do not run the installer or modify a live cluster during repository validation.

---

### Task 1: Use Server-Side Apply for Argo CD installation

**Files:**
- Modify: `bootstrap/install.sh`
- Modify: `docs/RUNBOOK.md`

**Interfaces:**
- Consumes: The current Argo CD `install.yaml` apply command and bootstrap troubleshooting table.
- Produces: An idempotent Argo CD bootstrap/upgrade using `--server-side --force-conflicts`, plus instructions for retrying bootstrap after the annotation-limit error.

- [x] **Step 1: Verify the current apply command lacks Server-Side Apply**

Run: `rg -n --fixed-strings '$KUBECTL apply --server-side --force-conflicts' bootstrap/install.sh`
Expected before the change: no matches.

- [x] **Step 2: Update the Argo CD apply command**

Change the command to:

```bash
$KUBECTL apply --server-side --force-conflicts -n argocd -f \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
```

Add a concise comment explaining that the ApplicationSet CRD exceeds the client-side last-applied annotation limit. Preserve the namespace creation and versioned URL.

- [x] **Step 3: Document the recovery path**

Add a troubleshooting row in `docs/RUNBOOK.md` for `applicationsets.argoproj.io` with `metadata.annotations: Too long`. Explain that the Argo CD install now uses Server-Side Apply and rerunning `sudo bash bootstrap/install.sh` retries the idempotent installation; do not recommend deleting CRDs.

- [x] **Step 4: Verify the bootstrap command and syntax**

Run: `sh -n bootstrap/install.sh`
Expected: exit code 0 and no output.

Run: `rg -n --fixed-strings '$KUBECTL apply --server-side --force-conflicts' bootstrap/install.sh`
Expected: one match.

Run: `git diff --check`
Expected: no whitespace errors.

Do not execute `bootstrap/install.sh` during validation.
