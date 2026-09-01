#!/usr/bin/env bash
# .devcontainer/setup.sh
# Robust GitLab clone bootstrap for GitHub Codespaces.
# Fails fast with a clear message at whichever step is actually broken.

set -uo pipefail  # NOTE: not -e, so we can catch failures and report them cleanly

# ---- Configuration (edit these) ----
GITLAB_HOST="git.gccis.rit.edu"
GITLAB_URL="https://${GITLAB_HOST}"
REPO_PATH="sst1170/swen261gitlab"          # no .git suffix
CLONE_DIR="/workspaces/SWEN261GitLab"

log()  { echo "[setup] $*"; }
fail() { echo "[setup] ERROR: $*" >&2; exit 1; }

# ---- 0. Confirm the secret actually arrived ----
if [ -z "${GITLAB_PAT:-}" ]; then
  fail "GITLAB_PAT is not set in this Codespace. Add it under GitHub Settings > Codespaces > Secrets, grant it to this repo, then REBUILD the container (secrets only inject on creation/rebuild, not a simple restart)."
fi
log "GITLAB_PAT is present (length: ${#GITLAB_PAT} chars)."

# ---- 1. DNS resolution ----
log "Checking DNS resolution for ${GITLAB_HOST}..."
if ! getent hosts "${GITLAB_HOST}" > /dev/null 2>&1; then
  fail "Cannot resolve ${GITLAB_HOST} from inside the Codespace. Most common cause: this GitLab instance is only reachable over a corporate VPN/intranet, and Codespaces run in GitHub's cloud with no route to it. Confirm the server has a public DNS record and public network path."
fi
log "DNS resolves."

# ---- 2. HTTPS reachability (server up at all?) ----
log "Checking HTTPS reachability of ${GITLAB_URL}..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${GITLAB_URL}/users/sign_in" 2>/dev/null || echo "000")
case "${HTTP_STATUS}" in
  000) fail "No HTTP response at all from ${GITLAB_URL} (connection refused/timed out). Server may be down, behind a firewall, or blocking Codespaces' IP ranges. Try 'curl -v ${GITLAB_URL}' by hand for the raw error." ;;
  5*)  fail "GitLab responded with HTTP ${HTTP_STATUS} (server-side error). Check GitLab server/admin status directly." ;;
  *)   log "GitLab reachable (HTTP ${HTTP_STATUS})." ;;
esac

# ---- 3. Token validity against the API ----
log "Validating GITLAB_PAT against ${GITLAB_URL}/api/v4/user ..."
API_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 10 \
  --header "PRIVATE-TOKEN: ${GITLAB_PAT}" \
  "${GITLAB_URL}/api/v4/user" 2>/dev/null)
API_STATUS=$(echo "${API_RESPONSE}" | tail -n1)
API_BODY=$(echo "${API_RESPONSE}" | sed '$d')

case "${API_STATUS}" in
  200)
    GITLAB_USERNAME=$(echo "${API_BODY}" | grep -o '"username":"[^"]*"' | head -1 | cut -d'"' -f4)
    log "Token is valid. Authenticated as: ${GITLAB_USERNAME:-unknown}"
    ;;
  401) fail "Token rejected (401 Unauthorized). It's invalid, expired, or revoked. Generate a fresh one: GitLab > Edit profile > Access Tokens." ;;
  403) fail "Token rejected (403 Forbidden). It's likely missing scope. Recreate the PAT with the 'api' scope (or read_repository + write_repository)." ;;
  404) fail "Got 404 from the API endpoint — double check GITLAB_HOST is correct and the instance actually serves /api/v4." ;;
  *)   fail "Unexpected response validating token (HTTP ${API_STATUS}): ${API_BODY}" ;;
esac

# ---- 4. Configure git credentials from the same token ----
log "Configuring git credential storage..."
git config --global credential.helper store
echo "https://oauth2:${GITLAB_PAT}@${GITLAB_HOST}" > ~/.git-credentials
chmod 600 ~/.git-credentials

# ---- 5. Confirm git itself can reach the repo (no clone yet) ----
log "Testing git-level access to ${REPO_PATH} (ls-remote)..."
if ! git ls-remote "https://${GITLAB_HOST}/${REPO_PATH}.git" > /dev/null 2>&1; then
  fail "git ls-remote failed even though the API token works. Check: (1) REPO_PATH '${REPO_PATH}' is spelled correctly, (2) the token's user has at least Reporter access to that project."
fi
log "git access to repo confirmed."

# ---- 6. Clone, or pull if it's already there ----
if [ -d "${CLONE_DIR}/.git" ]; then
  log "Repo already present at ${CLONE_DIR}, pulling latest instead of cloning..."
  git -C "${CLONE_DIR}" pull || fail "git pull failed in ${CLONE_DIR}."
else
  log "Cloning ${REPO_PATH} into ${CLONE_DIR}..."
  git clone "https://${GITLAB_HOST}/${REPO_PATH}.git" "${CLONE_DIR}" || fail "git clone failed."
fi

log "Setup complete. Repo is at ${CLONE_DIR}."

# ---- 7. Replace the live Codespace workspace with the GitLab clone ----
# Codespaces checks out the GitHub template into /workspaces/<repo-name>.
# Since the folder name matches on both sides, we swap that directory's
# contents AND git history for the GitLab clone, keeping .devcontainer/
# intact so future rebuilds of this container still work.

WORKSPACE_DIR="/workspaces/$(basename "${REPO_PATH}")"
TMP_CLONE="/tmp/gitlab-clone-$$"

command -v rsync >/dev/null 2>&1 || fail "rsync is required but not installed. Add it via a devcontainer feature or 'apt-get install -y rsync' in postCreateCommand."

if [ ! -d "${WORKSPACE_DIR}/.devcontainer" ]; then
  fail "${WORKSPACE_DIR}/.devcontainer not found — refusing to swap; something's already wrong with the checkout."
fi

log "Cloning GitLab repo into a temp location..."
rm -rf "${TMP_CLONE}"
git clone "https://${GITLAB_HOST}/${REPO_PATH}.git" "${TMP_CLONE}" || fail "git clone into temp location failed."

log "Syncing GitLab content into ${WORKSPACE_DIR} (preserving .devcontainer/)..."
rsync -a --delete \
  --exclude='.devcontainer/' \
  "${TMP_CLONE}/" "${WORKSPACE_DIR}/" || fail "rsync from temp clone into workspace failed."

rm -rf "${TMP_CLONE}"

log "Verifying origin remote inside ${WORKSPACE_DIR}..."
cd "${WORKSPACE_DIR}"
ACTIVE_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
case "${ACTIVE_REMOTE}" in
  *"${GITLAB_HOST}"*) log "Confirmed: origin now points to GitLab (${ACTIVE_REMOTE})." ;;
  *) fail "origin is '${ACTIVE_REMOTE}', not GitLab — the swap didn't take. Check for a stray .git left over from the GitHub checkout." ;;
esac

log "Workspace swap complete. VS Code's Source Control panel should now show ${GITLAB_HOST}."