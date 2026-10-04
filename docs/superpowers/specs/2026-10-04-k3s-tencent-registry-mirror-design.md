# Configure the Tencent Docker Hub Mirror for K3s

## Goal

Configure K3s containerd to pull Docker Hub images through Tencent Cloud's
`mirror.ccs.tencentyun.com`, including the `rancher/mirrored-pause` image used
to create pod sandboxes.

## Design

Bootstrap will ensure `/etc/rancher/k3s/registries.yaml` is handled before the
K3s install check:

- If the file does not exist, create it with a `docker.io` mirror endpoint at
  `https://mirror.ccs.tencentyun.com`.
- If the existing file already configures that endpoint for `docker.io`, leave
  it unchanged.
- If the file exists but does not contain the required mirror, do not overwrite
  it. Stop with an actionable message asking the operator to merge the mirror
  into the existing YAML. This protects private-registry credentials and other
  custom configuration.
- For a fresh K3s install, create the file before invoking the installer so
  containerd starts with the mirror configuration.
- If K3s is already installed and the bootstrap creates the file, restart
  `k3s` when its systemd unit exists, or otherwise restart `k3s-agent`. If
  neither unit exists, fail with an actionable error rather than silently
  leaving the new configuration unapplied. A restart can briefly interrupt
  workloads on a single-node cluster. Do not restart when the file already
  contains the mirror.

Update the Chinese runbook to explain that the Rancher installer mirror and
the Tencent runtime image mirror are separate settings, and document the
existing-file and restart behavior.

## Alternatives

- **Recommended:** Create only when absent, preserve a compatible existing
  configuration, and fail explicitly if manual merging is needed. This avoids
  silently discarding registry credentials or other endpoints.
- Back up and replace an existing `registries.yaml`. This is simpler but can
  break private registry access by discarding its configuration.
- Configure only on first install. This avoids restarting existing nodes but
  does not fix the current running cluster when bootstrap is rerun.

## Validation

- Check shell syntax without running the bootstrap installer.
- Verify missing-file creation, existing-compatible no-op, existing-conflict
  failure, and service selection/restart behavior using isolated shell tests or
  a focused test script.
- Check the runbook and patch for formatting errors.
