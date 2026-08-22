#!/usr/bin/env bash
# Prove what the agent's GitHub credential can and cannot do.
#
#   ./scripts/verify-github-token.sh
#
# The counterpart to verify-rbac.sh. That one proves the agent cannot change
# the cluster; this proves what it can do to `main`.
#
# WHAT THIS MEASURED, AND WHY IT MATTERS
#
# Run against a fine-grained PAT scoped to this repository with only contents
# and pull-requests write, with branch protection ENABLED requiring one
# approving review, this script got:
#
#     !! ALLOWED direct commit to main (HTTP 201)
#
# The commit landed. The reason is that a PAT inherits the repository role of
# the human who minted it, and a repository admin bypasses branch protection
# when `enforce_admins` is false. Narrow scopes decide which repositories and
# which APIs a token may touch. They do not demote the actor behind it.
#
# So "no agent can merge its own pull request" is not made true by scoping a
# token. On the PAT path it is true only because Warden's code never calls the
# merge endpoint, which is a promise. The enforceable version is a GitHub App:
# an App holds no repository role, so protection applies to it with no bypass
# to inherit, and an App cannot approve a pull request.
#
# Reads the credential from ../warden/.env. Nothing is printed but the verdict.

set -uo pipefail
cd "$(dirname "$0")/.."

REPO="${GITOPS_REPO_FULL:-mazzyy/estate-gitops}"
ENV_FILE="../warden/.env"
GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

envval() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"' '; }

TOKEN="${GITHUB_TOKEN:-}"
[[ -n "$TOKEN" ]] || TOKEN=$(envval GITHUB_TOKEN)
APP_ID=$(envval GITHUB_APP_ID)
INSTALL_ID=$(envval GITHUB_APP_INSTALLATION_ID)
KEY_PATH=$(envval GITHUB_APP_PRIVATE_KEY_PATH)

IDENTITY="personal access token"
ENFORCED=0
if [[ -n "$APP_ID" && -n "$INSTALL_ID" && -f "${KEY_PATH/#\~/$HOME}" ]]; then
  TOKEN=$(python3 - "$APP_ID" "$INSTALL_ID" "${KEY_PATH/#\~/$HOME}" <<'PY' 2>/dev/null
import sys
from github import Auth
app_id, install_id, key_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
auth = Auth.AppAuth(app_id, open(key_path).read()).get_installation_auth(
    install_id, token_permissions={"contents": "write", "pull_requests": "write", "metadata": "read"}
)
print(auth.token)
PY
  )
  if [[ -n "$TOKEN" ]]; then
    IDENTITY="GitHub App $APP_ID · installation $INSTALL_ID"
    ENFORCED=1
  else
    echo "${YELLOW}GITHUB_APP_* is set but minting an installation token failed;"
    echo "falling back to the PAT. Run in the warden venv so PyGithub is importable.${RESET}"
    TOKEN=$(envval GITHUB_TOKEN)
  fi
fi
[[ -n "$TOKEN" ]] || { echo "${RED}no GitHub credential in env or $ENV_FILE${RESET}"; exit 2; }

api() {
  curl -sS -o /tmp/warden-gh-body -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "$@"
}

echo
echo "${BOLD}Warden's GitHub credential — what it can and cannot do${RESET}"
echo "${DIM}repository: $REPO${RESET}"
echo "${DIM}identity:   $IDENTITY${RESET}"
echo

fail=0

echo "${BOLD}Must work${RESET}"
code=$(api "https://api.github.com/repos/$REPO/contents/apps/checkout-svc/deployment.yaml")
if [[ "$code" == "200" ]]; then
  echo "  ${GREEN}✓ allowed${RESET}  read repository contents"
else
  echo "  ${RED}✗ BROKEN${RESET}   read contents returned $code — the remediator cannot work"
  fail=1
fi

echo
echo "${BOLD}Must be refused${RESET}"

# THE test. Everything else on this page is configuration; this one is an
# attempt. A credential that can commit straight to main can bypass review
# by definition, whatever the branch settings say.
code=$(api -X PUT "https://api.github.com/repos/$REPO/contents/.warden-probe" \
  -d '{"message":"probe: verify-github-token.sh","content":"cHJvYmU=","branch":"main"}')
if [[ "$code" == "40"* ]]; then
  echo "  ${RED}✗ denied${RESET}   direct commit to main ${DIM}(HTTP $code)${RESET}"
  echo "      ${DIM}no bypass inherited — the same refusal covers merging unapproved work${RESET}"
else
  echo "  ${YELLOW}!! ALLOWED${RESET} direct commit to main ${DIM}(HTTP $code)${RESET}"
  fail=1
  sha=$(python3 -c "import json;print(json.load(open('/tmp/warden-gh-body'))['content']['sha'])" 2>/dev/null || true)
  if [[ -n "${sha:-}" ]]; then
    api -X DELETE "https://api.github.com/repos/$REPO/contents/.warden-probe" \
      -d "{\"message\":\"probe cleanup\",\"sha\":\"$sha\",\"branch\":\"main\"}" >/dev/null
    echo "      ${DIM}(probe file removed from main)${RESET}"
  fi
  if [[ $ENFORCED -eq 0 ]]; then
    echo "      ${RED}This is a PAT, and it inherits your repository role. Branch${RESET}"
    echo "      ${RED}protection does not apply to a repo admin unless enforce_admins${RESET}"
    echo "      ${RED}is true. Scoping the token cannot fix this — see docs/IDENTITY.md.${RESET}"
  else
    echo "      ${RED}An App got through. Check the installation's repository access.${RESET}"
  fi
fi

# A credential that can read the protection rule can usually edit it. The
# agent should not be able to see the rule that governs it at all.
code=$(api "https://api.github.com/repos/$REPO/branches/main/protection")
if [[ "$code" == "403" || "$code" == "404" ]]; then
  echo "  ${RED}✗ denied${RESET}   read branch protection ${DIM}(HTTP $code — no administration scope)${RESET}"
elif [[ "$code" == "200" ]]; then
  echo "  ${YELLOW}!! ALLOWED${RESET} read branch protection — the agent can inspect its own guardrail"
  echo "      ${DIM}drop 'administration' from the credential's permissions${RESET}"
  fail=1
else
  echo "  ${DIM}?  inconclusive${RESET} read branch protection (HTTP $code)"
fi

rm -f /tmp/warden-gh-body

# Informational, and deliberately separate: this uses YOUR credentials, not the
# agent's, because the agent must not be able to answer this question itself.
echo
echo "${BOLD}The rule itself${RESET} ${DIM}(read with your credentials, not the agent's)${RESET}"
if command -v gh >/dev/null 2>&1; then
  rule=$(gh api "repos/$REPO/branches/main/protection" 2>/dev/null || true)
  if [[ -n "$rule" ]]; then
    python3 - <<PY
import json
d = json.loads('''$rule''')
r = d.get("required_pull_request_reviews") or {}
print("  approvals required : %s" % r.get("required_approving_review_count", 0))
print("  applies to admins  : %s" % d.get("enforce_admins", {}).get("enabled", False))
print("  force pushes       : %s" % d.get("allow_force_pushes", {}).get("enabled", False))
PY
  else
    echo "  ${YELLOW}main has no branch protection${RESET}"
  fi
else
  echo "  ${DIM}gh not installed — skipped${RESET}"
fi

echo
if [[ $fail -eq 0 ]]; then
  echo "  ${GREEN}${BOLD}The agent can propose changes and cannot land them.${RESET}"
  echo "  ${DIM}Refused a direct write to main, and cannot see the rule that stops it.${RESET}"
else
  echo "  ${RED}${BOLD}The write path is not what it claims to be.${RESET}"
  echo "  ${DIM}Warden will say so on every pull request it opens, and the demo${RESET}"
  echo "  ${DIM}header will show 'boundary: NOT enforced'. Nothing is hidden — but${RESET}"
  echo "  ${DIM}do not narrate this as a governed write path.${RESET}"
fi
echo
exit $fail
