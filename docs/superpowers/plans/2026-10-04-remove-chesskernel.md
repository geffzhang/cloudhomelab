# Removing ChessKernel from the Active Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove ChessKernel from the active GitOps platform and update current inventory, dashboards, and operational documentation while preserving historical design records.

**Architecture:** Delete the ChessKernel Kubernetes manifests, Argo CD Application, and example secret. Remove its namespace and dashboard data, then update current documentation and generic app guidance. Do not directly delete live cluster data; preserve historical ADRs and design records.

**Tech Stack:** Kubernetes YAML, Argo CD, Grafana dashboard JSON embedded in YAML, Markdown.

## Global Constraints

- Remove `apps/chesskernel/`, its Argo CD Application manifest, and its example secret template.
- Remove ChessKernel from active platform inventory, dashboards, and current README, networking, architecture, and operational guidance.
- Update generic guidance that uses ChessKernel as an example so it refers to a remaining application or describes the pattern without a ChessKernel dependency.
- Preserve historical ADRs and design records as historical records.
- This change does not include an explicit database export, PVC deletion, or other direct data cleanup.
- Argo CD's root application has automated pruning enabled; back up required data and verify live resource state and deletion behavior before applying changes to a live cluster.

---

### Task 1: Remove ChessKernel GitOps resources

**Files:**
- Delete: `apps/chesskernel/` (all seven Kubernetes manifests)
- Delete: `argocd/app-chesskernel.yaml`
- Delete: `docs/examples/chesskernel-secrets.example.yaml`
- Modify: `platform/config/namespaces.yaml`

**Interfaces:**
- Consumes: Current Argo CD app-of-apps configuration at `bootstrap/root.yaml`.
- Produces: No ChessKernel application registration, workload manifests, namespace inventory entry, or plaintext example secret in the active source tree.

- [x] **Step 1: Remove the app registration and ChessKernel manifest directory**

Delete `argocd/app-chesskernel.yaml` and every manifest under `apps/chesskernel/`. Do not add an Argo CD resource finalizer and do not delete PVC/data from a live cluster.

- [x] **Step 2: Remove the ChessKernel namespace inventory entry**

Delete the `chesskernel` namespace record and its ChessKernel-specific description from `platform/config/namespaces.yaml`; preserve all other namespaces and descriptions.

- [x] **Step 3: Remove the ChessKernel example secret**

Delete `docs/examples/chesskernel-secrets.example.yaml`; do not copy any secret material elsewhere.

- [x] **Step 4: Check the GitOps removal**

Run: `git diff --check`
Expected: no whitespace errors.

Run: `rg -n -i "apps/chesskernel|app-chesskernel|namespace: chesskernel" argocd apps platform docs/examples`
Expected: no matches.

### Task 2: Remove ChessKernel from active platform inventory and observability

**Files:**
- Modify: `README.md`
- Modify: `platform/config/grafana-dashboard-homelab.yaml`
- Modify: `docs/architecture/overview.md`
- Modify: `docs/networking.md`
- Modify: `docs/security/security.md`
- Modify: `apps/pixelhub/server.yaml`

**Interfaces:**
- Consumes: Remaining app inventory and active Kubernetes resources after Task 1.
- Produces: README, diagrams, platform inventory, network guidance, security guidance, and Grafana dashboard that describe only the remaining active applications.

- [x] **Step 1: Update README inventory and diagrams**

Remove the ChessKernel row, topology node/edges, and monitoring references. Update all displayed application and dashboard counts to match the remaining deployed apps and dashboard sections. Keep unrelated ChessKernel references only in historical documents, not the README.

- [x] **Step 2: Remove ChessKernel dashboard panels**

Remove the ChessKernel dashboard section and its queries from the embedded Grafana dashboard JSON. Preserve all other dashboard sections and valid JSON/YAML structure.

- [x] **Step 3: Update active architecture, networking, and security docs**

Remove the ChessKernel namespace, domains, ingress routes, certificate examples, metrics, and workload descriptions from these current-state documents. Keep the wildcard DNS guidance and descriptions of remaining applications.

- [x] **Step 4: Remove the obsolete app comparison comment**

In `apps/pixelhub/server.yaml`, replace the ChessKernel-specific comparison with a generic explanation or remove it if it no longer adds useful information.

- [x] **Step 5: Validate dashboard and YAML syntax**

Parse `platform/config/grafana-dashboard-homelab.yaml` as YAML and parse its embedded dashboard JSON as JSON using the repository's available tooling.
Expected: both parsers succeed; no unrelated dashboard sections are removed.

### Task 3: Update active operational guidance and generic app examples

**Files:**
- Modify: `docs/RUNBOOK.md`
- Modify: `docs/operations/adding-an-app.md`
- Preserve: historical ADRs and design records under `docs/adr/`, `docs/specs/`, and existing `docs/superpowers/` records.

**Interfaces:**
- Consumes: The remaining application set and revised platform/network documentation from Task 2.
- Produces: Current operational instructions and add-an-app examples that no longer require ChessKernel.

- [x] **Step 1: Remove ChessKernel-only operational procedures**

Remove ChessKernel-specific secret sealing, COS backup retention, database restore, and docker-compose cutover instructions from `docs/RUNBOOK.md`. Keep general cluster bootstrap, app deployment, 9Router, and PixelHub LiveKit procedures. Ensure no step points to the deleted example secret or app directory.

- [x] **Step 2: Replace ChessKernel examples in the app guide**

Update `docs/operations/adding-an-app.md` to use a remaining app where its manifests match the example; otherwise describe the resource pattern generically. Do not leave links or copy commands pointing to deleted files.

- [x] **Step 3: Preserve historical records**

Do not rewrite historical ADRs, dated design specifications, or prior implementation plans. Their references are intentionally historical and are not active deployment instructions.

- [x] **Step 4: Search active files for stale references**

Run `rg -n -i "chesskernel" README.md argocd apps platform docs/RUNBOOK.md docs/networking.md docs/architecture/overview.md docs/security/security.md docs/operations/adding-an-app.md docs/examples`
Expected: no matches.

### Task 4: Verify the full change

**Files:**
- Verify: all files modified or deleted in Tasks 1–3.

**Interfaces:**
- Consumes: Completed Tasks 1–3.
- Produces: Evidence that active configuration is consistent and only historical records retain ChessKernel references.

- [x] **Step 1: Check patch formatting**

Run: `git diff --check`
Expected: no whitespace errors.

- [x] **Step 2: Check active deployment references**

Run: `rg -n -i "chesskernel" argocd apps platform README.md docs/RUNBOOK.md docs/networking.md docs/architecture/overview.md docs/security/security.md docs/operations/adding-an-app.md docs/examples`
Expected: no matches.

- [x] **Step 3: Check intentionally retained history**

Run: `rg -n -i "chesskernel" docs/adr docs/specs docs/superpowers`
Expected: matches are confined to historical records and the approved removal design/plan.

- [x] **Step 4: Validate changed YAML and dashboard data**

Parse each changed Kubernetes/platform YAML file and the Grafana JSON using tools already available in the repository or local environment.
Expected: all edited configuration parses successfully; no cluster-side deletion is performed during validation.
