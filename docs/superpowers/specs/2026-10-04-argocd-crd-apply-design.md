# Apply Argo CD Installation Manifests Server-Side

## Goal

Make the Argo CD bootstrap command succeed when a CRD exceeds the Kubernetes
client-side apply annotation limit.

## Design

- In `bootstrap/install.sh`, apply the existing Argo CD `install.yaml` with
  `--server-side --force-conflicts`.
- Keep the current Argo CD namespace, `stable` manifest URL, and
  install/upgrade flow unchanged.
- Add a concise comment explaining that the ApplicationSet CRD exceeds the
  client-side `last-applied-configuration` annotation limit.
- Add a troubleshooting note to the runbook describing why the bootstrap uses
  server-side apply.

Server-Side Apply stores field ownership in managed fields rather than the
oversized client-side annotation. `--force-conflicts` allows the bootstrap
manifest to take ownership of fields it declares when upgrading resources
previously applied client-side. Do not delete or recreate CRDs or their custom
resources.

## Validation

- Run `sh -n bootstrap/install.sh`.
- Confirm the Argo CD install command still uses the configured versioned
  manifest URL and now includes both server-side options.
- Do not run the installer or modify a live cluster during repository
  validation.
