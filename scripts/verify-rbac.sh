#!/usr/bin/env bash
# Prove the reader token cannot mutate the cluster — correctly.
#
#   ./scripts/verify-rbac.sh
#
# THE TRAP THIS SCRIPT EXISTS TO AVOID
#
# The obvious way to test this is wrong:
#
#     kubectl --token=$TOKEN --server=$APISERVER -n demo delete deploy checkout-svc
#
# That appears to work — and it deletes the deployment. Not because RBAC failed,
# but because an AKS admin kubeconfig authenticates with CLIENT CERTIFICATES,
# and Kubernetes authenticates a valid client cert regardless of any bearer
# token you also pass. The `--token` flag is silently ignored and the command
# runs as cluster-admin.
#
# So the "proof" proves nothing, and if you record it, you are showing a
# governance guarantee that was never tested. `--kubeconfig=/dev/null` is what
# forces the token to be the only credential in play.

set -uo pipefail
cd "$(dirname "$0")/.."

NS="${ESTATE_NAMESPACE:-demo}"
GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

TOKEN=$(kubectl -n "$NS" get secret warden-reader-token -o jsonpath='{.data.token}' | base64 -d)
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

# /dev/null as kubeconfig = no context, no client certs, token is the only
# credential. This is the whole point of the script.
RO=(kubectl --kubeconfig=/dev/null --token="$TOKEN" --server="$APISERVER"
    --insecure-skip-tls-verify -n "$NS")

echo
echo "${BOLD}Warden reader token — what it can and cannot do${RESET}"
echo "${DIM}authenticating with the token ONLY (no kubeconfig, no client certs)${RESET}"
echo

fail=0

check_allowed() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ${GREEN}✓ allowed${RESET}  $label"
  else
    echo "  ${RED}✗ BROKEN${RESET}   $label — the reader cannot do its job"
    fail=1
  fi
}

check_denied() {
  local label="$1"; shift
  local out
  out=$("$@" 2>&1)
  if [[ "$out" == *"orbidden"* || "$out" == *"cannot "* ]]; then
    echo "  ${RED}✗ denied${RESET}   $label"
    echo "      ${DIM}${out:0:150}${RESET}"
  else
    echo "  ${GREEN}!! ALLOWED${RESET} $label"
    echo "      ${RED}SECURITY REGRESSION — the reader token can mutate the cluster.${RESET}"
    fail=1
  fi
}

echo "${BOLD}Reads — these must work${RESET}"
check_allowed "get pods"        "${RO[@]}" get pods
check_allowed "get deployments" "${RO[@]}" get deployments
check_allowed "get events"      "${RO[@]}" get events

echo
echo "${BOLD}Writes — these must all fail${RESET}"
check_denied "delete deployment" "${RO[@]}" delete deploy checkout-svc --dry-run=server
check_denied "scale deployment"  "${RO[@]}" scale deploy checkout-svc --replicas=0
check_denied "delete namespace"  "${RO[@]}" delete namespace "$NS" --dry-run=server
check_denied "create configmap"  "${RO[@]}" create configmap pwned --from-literal=a=b --dry-run=server

echo
if [[ $fail -eq 0 ]]; then
  echo "  ${GREEN}${BOLD}The token can read the estate and change nothing.${RESET}"
  echo "  ${DIM}This is the terminal output that belongs in the demo video.${RESET}"
else
  echo "  ${RED}${BOLD}RBAC is not what it claims to be. Do not record this.${RESET}"
fi
echo
exit $fail
