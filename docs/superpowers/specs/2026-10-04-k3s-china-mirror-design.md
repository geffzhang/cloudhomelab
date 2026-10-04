# Use the China Mirror for K3s Bootstrap

## Goal

Use the Rancher China mirror when the bootstrap script installs K3s on a fresh
server.

## Design

- In `bootstrap/install.sh`, change only the fresh-install branch to fetch
  `https://rancher-mirror.rancher.cn/k3s/k3s-install.sh` and run it with
  `INSTALL_K3S_MIRROR=cn`.
- Keep the existing `k3s`-already-installed skip behavior unchanged.
- Update the runbook to state that bootstrap uses the Rancher China mirror.
- Do not change the source or update behavior for an already-installed K3s
  cluster, and do not configure mirrors for application container images.

The mirrored installer uses the China mirror for K3s channel metadata,
checksums, and release artifacts. The install script and artifact mirror URL
were verified to be reachable during design.

## Validation

- Run `bash -n bootstrap/install.sh` to verify shell syntax.
- Confirm the fresh-install branch contains the mirror installer URL and
  `INSTALL_K3S_MIRROR=cn`, while the installed-K3s branch still skips
  installation.
- Do not execute the installer during repository validation.
