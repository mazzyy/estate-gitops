#!/usr/bin/env bash
# Mint the three repository secrets the sync workflow needs.
#
#   ./scripts/ci-credentials.sh            # print them
#   ./scripts/ci-credentials.sh --set      # set them with gh, printing nothing
#
# `--set` is the one to use. The token is a live cluster credential and the
# printing path exists only for someone without gh installed — anything on a
# terminal is one screen-share away from being public, and this project has a
# recording in its future.

set -euo pipefail
cd "$(dirname "$0")/.."

NS="${ESTATE_NAMESPACE:-demo}"
REPO="${GITOPS_REPO_FULL:-mazzyy/estate-gitops}"
GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

if ! kubectl -n "$NS" get secret warden-sync-token >/dev/null 2>&1; then
  echo "${RED}secret warden-sync-token not found in $NS${RESET}"
  echo "${DIM}kubectl apply -f rbac/warden-sync.yaml${RESET}"
  exit 2
fi

TOKEN=$(kubectl -n "$NS" get secret warden-sync-token -o jsonpath='{.data.token}' | base64 -d)
CA=$(kubectl -n "$NS" get secret warden-sync-token -o jsonpath='{.data.ca\.crt}' | base64 -d)
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

[[ -n "$TOKEN" && -n "$CA" && -n "$APISERVER" ]] || {
  echo "${RED}could not read all three values${RESET}"; exit 1;
}

# Never hand CI a credential without checking what it can do. This is the same
# check the workflow repeats at run time, done once here so a mis-scoped token
# never reaches GitHub in the first place.
AS=(kubectl --kubeconfig=/dev/null --token="$TOKEN" --server="$APISERVER" --insecure-skip-tls-verify -n "$NS")
for pair in "delete/deployments" "get/secrets" "create/clusterrolebindings"; do
  verb="${pair%%/*}"; res="${pair##*/}"
  if [[ "$("${AS[@]}" auth can-i "$verb" "$res" 2>/dev/null | tr -d '[:space:]')" == "yes" ]]; then
    echo "${RED}this token can $verb $res — refusing to publish it to CI${RESET}"
    echo "${DIM}check rbac/warden-sync.yaml, then ./scripts/verify-sync-rbac.sh${RESET}"
    exit 1
  fi
done
echo "${GREEN}✓${RESET} token is scoped to $NS and cannot delete, read secrets, or escalate"

if [[ "${1:-}" == "--set" ]]; then
  command -v gh >/dev/null || { echo "${RED}gh not installed${RESET}"; exit 2; }
  # No --body flag and no --body-file: `gh secret set` reads the value from
  # stdin when neither is given. --body-file does not exist in every gh
  # version, and passing the value as --body would put a live cluster token
  # into the shell history.
  printf '%s' "$APISERVER" | gh secret set KUBE_APISERVER --repo "$REPO"
  printf '%s' "$TOKEN"     | gh secret set KUBE_TOKEN     --repo "$REPO"
  printf '%s' "$CA"        | gh secret set KUBE_CA        --repo "$REPO"
  echo "${GREEN}✓${RESET} KUBE_APISERVER, KUBE_TOKEN, KUBE_CA set on $REPO"
  echo "${DIM}nothing was printed — the token never touched your scrollback${RESET}"
  exit 0
fi

echo
echo "${YELLOW}${BOLD}The token below is a live cluster credential. Do not record this.${RESET}"
echo "${DIM}Prefer: ./scripts/ci-credentials.sh --set${RESET}"
echo
echo "${BOLD}KUBE_APISERVER${RESET}"; echo "$APISERVER"
echo
echo "${BOLD}KUBE_TOKEN${RESET}";     echo "$TOKEN"
echo
echo "${BOLD}KUBE_CA${RESET}";        echo "$CA"
echo
