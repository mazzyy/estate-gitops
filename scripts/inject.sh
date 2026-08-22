#!/usr/bin/env bash
# Break checkout-svc the way a human actually breaks things: by committing a bad
# change and rolling it out. Not by poking the cluster behind git's back.
#
# That asymmetry is the whole story — humans break things directly, the agent
# fixes them through review. It also gives the Diagnostician a real ReplicaSet
# history with a real change-cause to correlate against, which is what turns
# "the service is down" into "revision r42, four minutes ago, did this".
#
#   ./scripts/inject.sh bad-config     # malformed URL scheme -> CrashLoopBackOff
#   ./scripts/inject.sh oom            # limit below warm-up   -> OOMKilled
#   ./scripts/inject.sh restore        # back to known-good
#
# Run `restore` before every take, and rehearse the whole sequence three times
# before you record. The rules forbid editing around a failure.
#
#   PUSH=false ./scripts/inject.sh bad-config    # skip the git commit/push
#   DRY=true   ./scripts/inject.sh bad-config    # patch the file, touch nothing

set -euo pipefail
cd "$(dirname "$0")/.."

MANIFEST="apps/checkout-svc/deployment.yaml"
NS="${ESTATE_NAMESPACE:-demo}"
MODE="${1:-}"
PUSH="${PUSH:-true}"
DRY="${DRY:-false}"

case "$MODE" in
  bad-config) CAUSE="chore: tune payment endpoint and timeouts" ;;
  oom)        CAUSE="perf: trim checkout-svc memory footprint" ;;
  restore)    CAUSE="fix: restore checkout-svc to known-good configuration" ;;
  *) echo "usage: $0 {bad-config|oom|restore}" >&2; exit 2 ;;
esac

[[ -f "$MANIFEST" ]] || { echo "run this from the estate-gitops repo root" >&2; exit 1; }

python3 scripts/patch_manifest.py "$MODE"

# Stamp the change-cause so `kubectl rollout history` and the Diagnostician's
# recent_deploys tool both see a human-readable reason for the change.
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo local)"
python3 - "$MANIFEST" "$CAUSE" "$SHA" <<'PY'
import re, sys
path, cause, sha = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
text = re.sub(r'kubernetes\.io/change-cause: .*', f'kubernetes.io/change-cause: "{cause}"', text)
text = re.sub(r'git-sha: .*', f'git-sha: "{sha}"', text)
open(path, "w").write(text)
PY

if [[ "$DRY" == "true" ]]; then
  echo "  dry run — manifest patched, nothing committed or applied"
  git --no-pager diff --stat "$MANIFEST" 2>/dev/null || true
  exit 0
fi

if [[ "$PUSH" == "true" ]] && git rev-parse --git-dir >/dev/null 2>&1; then
  git add "$MANIFEST"
  git commit -q -m "$CAUSE" && echo "  committed: $CAUSE" || echo "  (nothing to commit)"
  git push -q origin HEAD 2>/dev/null && echo "  pushed" || echo "  (no remote configured; local only)"
fi

if command -v kubectl >/dev/null 2>&1; then
  echo "  applying to namespace ${NS}"
  kubectl apply -f "$MANIFEST" -n "$NS"
  kubectl annotate deployment/checkout-svc -n "$NS" \
    "kubernetes.io/change-cause=${CAUSE}" --overwrite >/dev/null
  echo
  echo "  watch it:  kubectl get pods -n ${NS} -w"
  echo "  inspect:   kubectl describe deploy/checkout-svc -n ${NS}"
else
  echo "  kubectl not found — manifest updated and committed, not applied"
fi
