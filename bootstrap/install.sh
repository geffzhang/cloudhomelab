#!/usr/bin/env bash
# homelab bootstrap: turns a fresh Ubuntu/Debian VPS into the full platform.
# Idempotent: safe to re-run. Requires: root (or sudo), curl.
#
# Usage: sudo bash install.sh
set -euo pipefail

REPO_URL="https://github.com/geffzhang/cloudhomelab"
# "stable" tracks the latest stable release; older pins hit diff-schema bugs
# against current Kubernetes (e.g. .status.terminatingReplicas on 2.12).
ARGOCD_VERSION="stable"
BOOTSTRAP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$BOOTSTRAP_DIR/k3s-registry.sh"
source "$BOOTSTRAP_DIR/argocd-cmp-install.sh"

log() { echo -e "\033[1;32m[homelab]\033[0m $*"; }

# ── 0. Host hardening (swap, firewall, fail2ban, SSH). Idempotent. ──────────
harden_host() {
  export DEBIAN_FRONTEND=noninteractive

  # 2 GB swap. Prometheus and image builds spike memory; without swap the node
  # OOM-locked once. Low swappiness so it only engages under real pressure.
  if ! swapon --show | grep -q swapfile; then
    log "Adding 2 GB swap..."
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10 >/dev/null
    grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
  fi

  # fail2ban plus persistent iptables tooling.
  if ! command -v fail2ban-client >/dev/null 2>&1 || ! command -v netfilter-persistent >/dev/null 2>&1; then
    log "Installing fail2ban and iptables-persistent..."
    echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections
    echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections
    apt-get update -qq && apt-get install -y -qq netfilter-persistent iptables-persistent fail2ban
  fi
  install -d /etc/fail2ban/jail.d
  cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
port = 22
maxretry = 4
bantime = 1h
findtime = 10m
EOF
  systemctl enable --now fail2ban >/dev/null 2>&1 || true

  # node-exporter (:9100) serves unauthenticated host metrics. Restrict it to
  # the pod network, loopback, and the node itself; drop the public internet.
  # Traffic to the node's own IP routes via lo, which is what the kubelet
  # liveness probe uses, so -i lo must be allowed or node-exporter crashloops.
  allow9100() { iptables -C INPUT $1 -p tcp --dport 9100 -j ACCEPT 2>/dev/null || iptables -I INPUT $1 -p tcp --dport 9100 -j ACCEPT; }
  iptables -C INPUT -p tcp --dport 9100 -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport 9100 -j DROP
  allow9100 "-i lo"
  allow9100 "-s 127.0.0.0/8"
  allow9100 "-s 10.42.0.0/16"   # k3s default pod CIDR
  netfilter-persistent save >/dev/null 2>&1 || true

  # SSH key-only, but only once a key is present, never lock out a fresh box.
  if [ -s /root/.ssh/authorized_keys ] || [ -s "${HOME}/.ssh/authorized_keys" ]; then
    if [ ! -f /etc/ssh/sshd_config.d/00-security-hardening.conf ]; then
      log "Enabling SSH key-only auth (authorized_keys present)..."
      cat > /etc/ssh/sshd_config.d/00-security-hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
EOF
      sshd -t && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true; }
    fi
  else
    log "SSH still allows passwords: no authorized_keys yet. Add your key, then re-run to lock it down."
  fi
}

log "Hardening host..."
harden_host

# ── 1. k3s (includes Traefik ingress, CoreDNS, local-path storage) ──────────
if command -v k3s >/dev/null 2>&1; then
  K3S_INSTALLED=true
else
  K3S_INSTALLED=false
fi
configure_k3s_registry_mirror /etc/rancher/k3s/registries.yaml "$K3S_INSTALLED"

if [[ "$K3S_INSTALLED" == false ]]; then
  log "Installing k3s..."
  curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | INSTALL_K3S_MIRROR=cn sh -
else
  log "k3s already installed, skipping."
fi
export KUBECTL="k3s kubectl"

log "Waiting for node to be Ready..."
until $KUBECTL wait --for=condition=Ready node --all --timeout=300s >/dev/null 2>&1; do sleep 5; done

# ── 2. ArgoCD ───────────────────────────────────────────────────────────────
log "Installing/upgrading ArgoCD (${ARGOCD_VERSION})..."
$KUBECTL get ns argocd >/dev/null 2>&1 || $KUBECTL create namespace argocd
# Server-side apply avoids the ApplicationSet CRD's client-side annotation limit.
# Force conflicts to migrate fields owned by earlier client-side applies.
$KUBECTL apply --server-side --force-conflicts -n argocd -f \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Trim for 1 vCPU / 4GB: no dex (no SSO needed), no notifications controller.
$KUBECTL -n argocd scale deployment argocd-dex-server --replicas=0 || true
$KUBECTL -n argocd scale deployment argocd-notifications-controller --replicas=0 || true

# Serve the UI behind Traefik (TLS terminates at the ingress).
$KUBECTL -n argocd patch configmap argocd-cmd-params-cm \
  --type merge -p '{"data":{"server.insecure":"true"}}'
$KUBECTL -n argocd rollout restart deployment argocd-server

log "Waiting for ArgoCD server..."
$KUBECTL -n argocd rollout status deployment argocd-server --timeout=300s

# ── 2b. Cap ArgoCD workload resource usage for the 1 vCPU / 4GB VPS ─────────
# upstream install.yaml ships no limits, so a runaway controller or repo server
# could starve everything else. Sized so total requests stay well under the
# platform budget while still leaving headroom for spikes:
#   requests: 275m CPU, 640Mi memory (sum of all 5 workloads)
#   limits:   1.5  CPU, 1.66Gi memory (allows bursts, still capped)
# Patches are idempotent (strategic merge on container name); safe to re-run.
log "Patching ArgoCD workload resources..."
patch_argocd_resources() {
  local kind=$1 name=$2 cname=$3 cpu_req=$4 mem_req=$5 cpu_lim=$6 mem_lim=$7
  $KUBECTL -n argocd patch "${kind}/${name}" --type=strategic -p "$(cat <<EOF
{
  "spec":{"template":{"spec":{"containers":[{
    "name":"${cname}",
    "resources":{
      "requests":{"cpu":"${cpu_req}","memory":"${mem_req}"},
      "limits":{"cpu":"${cpu_lim}","memory":"${mem_lim}"}
    }
  }]}}}
}
EOF
)"
}
patch_argocd_resources statefulset argocd-application-controller    argocd-application-controller 100m 256Mi 500m 512Mi
patch_argocd_resources deployment  argocd-repo-server                 argocd-repo-server                  50m 128Mi 300m 384Mi
patch_argocd_resources deployment  argocd-server                      argocd-server                       50m 128Mi 300m 384Mi
patch_argocd_resources deployment  argocd-redis                       redis                               50m  64Mi 200m 128Mi
patch_argocd_resources deployment  argocd-applicationset-controller   argocd-applicationset-controller    25m  64Mi 200m 256Mi

log "Waiting for ArgoCD workloads to settle..."
$KUBECTL -n argocd rollout status statefulset argocd-application-controller --timeout=300s
$KUBECTL -n argocd rollout status deployment argocd-repo-server --timeout=300s
$KUBECTL -n argocd rollout status deployment argocd-redis --timeout=300s
$KUBECTL -n argocd rollout status deployment argocd-applicationset-controller --timeout=300s
log "Installing the domain Config Management Plugin..."
configure_argocd_domain_cmp "$BOOTSTRAP_DIR/argocd-cmp"

# ── 3. Root app-of-apps, from here on, git is the source of truth ──────────
log "Applying root application (GitOps takes over)..."
$KUBECTL apply -f "$(dirname "$0")/root.yaml"

log "Done. Next steps:"
log "  1. Point *.lab.csharpkit.com (A record) at this machine's IP."
log "  2. Initial admin password:"
log "     k3s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
log "  3. Seal your secrets (see docs/RUNBOOK.md § Secrets)."
log "  4. Watch everything come up at https://argo.lab.csharpkit.com"
