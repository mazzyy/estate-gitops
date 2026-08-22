#!/usr/bin/env bash
# Pull the three things Warden needs to read the cluster safely.
#
#   ./scripts/extract-reader-credentials.sh
#
# Prints the lines to paste into warden/.env, and writes the cluster CA to
# ~/.warden/cluster-ca.crt.
#
# WHY THE CA MATTERS AS MUCH AS THE TOKEN
#
# Warden ran for days with TLS verification disabled, on the reasoning that a
# read-only token made it an acceptable trade-off. That reasoning does not
# survive contact with what this system actually does.
#
# Skipping verification does not weaken writes — the agent has no write scope
# to weaken. It weakens knowing who you are talking to. An intercepted
# connection is handed the bearer token on every call, and that token can read
# pod logs across the namespace. Worse, the Diagnostician's entire output is
# derived from those logs: forge them and it will faithfully open a pull
# request fixing a bug that never existed, with a confident evidence chain
# pointing at the forgery.
#
# The CA sits in the same Secret as the token. There was never a reason to
# take one and not the other.
#
# This script only reads. It writes nothing to the cluster.

set -euo pipefail

NS="${WARDEN_NAMESPACE:-demo}"
SECRET="${WARDEN_READER_SECRET:-warden-reader-token}"
OUT_DIR="${WARDEN_HOME:-$HOME/.warden}"
CA_FILE="$OUT_DIR/cluster-ca.crt"
GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

command -v kubectl >/dev/null || { echo "${RED}kubectl not found${RESET}"; exit 2; }

if ! kubectl get secret "$SECRET" -n "$NS" >/dev/null 2>&1; then
  echo "${RED}secret $SECRET not found in namespace $NS${RESET}"
  echo "${DIM}apply it first:  kubectl apply -f rbac/warden-reader.yaml${RESET}"
  exit 2
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

TOKEN=$(kubectl get secret "$SECRET" -n "$NS" -o jsonpath='{.data.token}' | base64 -d)
kubectl get secret "$SECRET" -n "$NS" -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA_FILE"
chmod 600 "$CA_FILE"

# The in-cluster API server address, not the one in your admin kubeconfig —
# same endpoint, but read from the cluster so this works from anywhere.
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

if [[ ! -s "$CA_FILE" ]]; then
  echo "${RED}the secret contains no ca.crt — cannot verify the API server${RESET}"
  exit 1
fi

# Prove the CA actually validates this endpoint before telling anyone to trust
# it. A CA that does not verify is worse than none: it fails at the worst
# moment, mid-incident, looking like the cluster went down.
echo
echo "${BOLD}Checking the CA actually verifies the API server${RESET}"
if curl -sS --cacert "$CA_FILE" -o /dev/null -w '' \
     -H "Authorization: Bearer $TOKEN" "$APISERVER/version" 2>/dev/null; then
  echo "  ${GREEN}✓${RESET} TLS handshake verified against $CA_FILE"
else
  echo "  ${RED}✗${RESET} the CA did not verify $APISERVER"
  echo "  ${DIM}not writing config lines — fix this first${RESET}"
  exit 1
fi

echo
echo "${BOLD}Paste into warden/.env${RESET}"
echo
echo "ESTATE_ADAPTER=aks"
echo "AKS_APISERVER=$APISERVER"
echo "AKS_READER_TOKEN=$TOKEN"
echo "AKS_CA_CERT_PATH=$CA_FILE"
echo
echo "${DIM}The CA is a public certificate, not a secret — it is safe on screen.${RESET}"
echo "${DIM}The token above is NOT. Do not record this terminal.${RESET}"
echo
