# Removing ChessKernel from the Active Platform

## Goal

Remove ChessKernel from the active GitOps-managed platform and keep current
repository documentation and observability aligned with the remaining
applications.

## Scope

- Remove `apps/chesskernel/`, its Argo CD Application manifest, and its example
  secret template.
- Remove ChessKernel from active platform inventory, dashboards, and current
  README, networking, architecture, and operational guidance.
- Update generic guidance that uses ChessKernel as an example so it refers to
  a remaining application or describes the pattern without a ChessKernel
  dependency.
- Preserve historical ADRs and design records as historical records.

## Data and Rollout Safety

This change removes the application's manifests from Git. It does not include
an explicit database export, PVC deletion, or other direct data cleanup.
Argo CD's root application has automated pruning enabled, so synchronization
may remove managed resources. The ChessKernel Application does not declare an
Argo CD resource finalizer; deletion of the Application itself therefore does
not guarantee cascading removal of its workloads or storage. Before applying
the change to a live cluster, back up any required data and verify the actual
resource state and deletion behavior.

## Validation

- Confirm there is no remaining ChessKernel deployment/Application
  configuration or current-state documentation.
- Confirm intentionally retained historical records are the only remaining
  explanatory references.
- Validate edited YAML and dashboard configuration with existing repository
  checks, if available.
