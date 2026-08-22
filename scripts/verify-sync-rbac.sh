#!/usr/bin/env bash
# Prove the CI applier can patch `demo` and nothing else.
#
#   ./scripts/verify-sync-rbac.sh
#
# The third proof in the set. verify-rbac.sh covers the agent's read path,
# verify-github-token.sh covers the agent's write path, and this covers the one
# identity in the whole system that can actually change the cluster.
#
# It matters most, and it was the one nobody had checked. `.github/workflows/
# sync.yml` claimed to be "the only thing in the system holding a credential
# that can change the estate" while holding no credential at all — the workflow
# had never run. Its original design asked for a Contributor service principal
# on the resource group, which could delete the cluster in order to patch one
# Deployment.
#
# Same trap as verify-rbac.sh: `--kubeconfig=/dev/null` forces the token to be
# the only credential, because an AKS admin kubeconfig authenticates with
# client certificates that silently override any --token you pass.

set -uo pipefail
cd "$(dirname "$0")/.."

NS="${ESTATE_NAMESPACE:-demo}"
GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

if ! kubectl -n "$NS" get secret warden-sync-token >/dev/null 2>&1; then
  echo "${RED}secret warden-sync-token not found in $NS${RESET}"
  echo "${DIM}kubectl apply -f rbac/warden-sync.yaml${RESET}"
  exit 2
fi

TOKEN=$(kubectl -n "$NS" get secret warden-sync-token -o jsonpath='{.data.token}' | base64 -d)
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

AS=(kubectl --kubeconfig=/dev/null --token="$TOKEN" --server="$APISERVER"
    --insecure-skip-tls-verify)

echo
echo "${BOLD}Warden sync token — the only credential that can change the estate${RESET}"
echo "${DIM}authenticating with the token ONLY (no kubeconfig, no client certs)${RESET}"
echo

fail=0

# `kubectl auth can-i` asks the API server's authorizer directly. Unlike a real
# mutation it changes nothing, so this script is safe to run against a live
# cluster mid-incident — and safe to run on camera.
can() {
  "${AS[@]}" auth can-i "$1" "$2" ${3:+-n "$3"} 2>/dev/null | tr -d '[:space:]'
}

allow() {
  local verb="$1" res="$2" ns="$3" label="$4"
  if [[ "$(can "$verb" "$res" "$ns")" == "yes" ]]; then
    echo "  ${GREEN}✓ allowed${RESET}  $label"
  else
    echo "  ${RED}✗ BROKEN${RESET}   $label — the sync workflow cannot do its job"
    fail=1
  fi
}

deny() {
  local verb="$1" res="$2" ns="$3" label="$4"
  if [[ "$(can "$verb" "$res" "$ns")" == "yes" ]]; then
    echo "  ${RED}!! ALLOWED${RESET} $label"
    fail=1
  else
    echo "  ${RED}✗ denied${RESET}   $label"
  fi
}

echo "${BOLD}Must work — this is the applier${RESET}"
allow patch  deployments "$NS" "patch deployments in $NS"
allow get    deployments "$NS" "read deployment status in $NS"
allow list   replicasets "$NS" "watch a rollout in $NS"
allow get    pods/log    "$NS" "read pod logs in $NS"

echo
echo "${BOLD}Must be refused — the blast radius${RESET}"
deny delete deployments "$NS"         "delete a deployment in $NS"
deny patch  deployments kube-system   "patch deployments in kube-system"
deny get    secrets     "$NS"         "read secrets in $NS"
deny create clusterrolebindings ""    "grant itself cluster-admin"
deny patch  nodes ""                  "touch a node"
deny delete namespaces ""             "delete a namespace"

echo
echo "${BOLD}And it is a different identity from the agents${RESET}"
WHO=$("${AS[@]}" auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null || echo unknown)
echo "  ${DIM}applier:  ${WHO}${RESET}"
echo "  ${DIM}agents:   system:serviceaccount:${NS}:warden-reader (read-only)${RESET}"

echo
if [[ $fail -eq 0 ]]; then
  echo "  ${GREEN}${BOLD}The applier can roll out a merged change to ${NS} and nothing else.${RESET}"
  echo "  ${DIM}It cannot delete a workload, cross a namespace, read a secret, or${RESET}"
  echo "  ${DIM}widen its own permissions. Safe to record.${RESET}"
else
  echo "  ${RED}${BOLD}The applier is not scoped the way the design claims.${RESET}"
  echo "  ${DIM}Fix rbac/warden-sync.yaml before wiring this into CI.${RESET}"
fi
echo
exit $fail
