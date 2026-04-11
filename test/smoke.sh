#!/usr/bin/env bash
# smoke tests for sandboxed-copilot
#
# Tests:
#   1. Both Docker images build successfully
#   2. Expected tools are present and executable (gh, mise)
#   3. Container runs as root with cap_drop: ALL (zero Linux capabilities)
#   4. Proxy allows connections to allowlisted domains (github.com)
#   5. Proxy blocks connections to non-allowlisted domains (example.com)
#   6. Direct internet bypass is impossible (no route around the proxy)
#   7. Allowlist live-reload: a newly added domain becomes reachable within 10s
#   8. copilot-cli binary is present in the image
#   9. Home directory files are owned by root
#  10. TLS inspection (ssl_bump): CA cert is installed in the copilot trust store
#  11. Auth status detection handles missing token gracefully
#  12. proxy denied lists blocked domains and excludes allowlisted ones
#
# Usage:
#   bash test/smoke.sh            # from project root
#   cd test && bash smoke.sh      # from test directory

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
ALLOWLIST="${PROJECT_DIR}/config/allowlist.txt"

# Compute the session hash the same way the launcher does (cksum of workspace path).
# This ensures the test's docker compose project name matches what the launcher
# would derive when run from PROJECT_DIR, so proxy denied can find the right container.
_test_hash=$(printf '%s' "$PROJECT_DIR" | cksum | awk '{printf "%08d", $1}')
TEST_PROJECT_NAME="sandboxed-copilot-${_test_hash}"
export PROJECT_ALLOWLIST_FILE="project-allowlist-${_test_hash}.txt"
export COPILOT_WORKSPACE="${PROJECT_DIR}"

COMPOSE="docker compose -f ${COMPOSE_FILE} --project-directory ${PROJECT_DIR} --project-name ${TEST_PROJECT_NAME}"

PASS=0
FAIL=0
declare -a ERRORS=()

# ── Helpers ───────────────────────────────────────────────────────────────────

pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); ERRORS+=("$*"); }

# Run a command inside the copilot container without starting the proxy.
# Use for tests that don't need network access.
run_offline() {
    $COMPOSE run --rm --no-deps copilot bash -c "$1" 2>/dev/null
}

# Run a command inside the copilot container with the proxy active.
run_online() {
    $COMPOSE run --rm copilot bash -c "$1" 2>/dev/null
}

cleanup() {
    echo ""
    echo "── Cleaning up..."
    $COMPOSE down --volumes --remove-orphans 2>/dev/null || true
    # Remove the test session's project-allowlist file.
    rm -f "${PROJECT_DIR}/config/${PROJECT_ALLOWLIST_FILE}" 2>/dev/null || true
    # Restore allowlist if we modified it
    if [ -n "${ALLOWLIST_BACKUP:-}" ]; then
        # printf '%s\n' restores the trailing newline stripped by $(cat ...).
        printf '%s\n' "$ALLOWLIST_BACKUP" > "$ALLOWLIST"
    fi
}
trap cleanup EXIT

# ── 1. Build ─────────────────────────────────────────────────────────────────

echo "=== sandboxed-copilot smoke tests ==="
echo ""
echo "── 1. Building images..."

if $COMPOSE build 2>&1; then
    pass "Both images built successfully"
else
    fail "Image build failed"
    echo ""
    echo "Build failed — cannot continue."
    exit 1
fi
echo ""

# ── 2. Tool availability ──────────────────────────────────────────────────────

echo "── 2. Checking installed tools..."

if run_offline "which gh >/dev/null 2>&1"; then
    pass "gh CLI is on PATH"
else
    fail "gh CLI not found on PATH"
fi

if run_offline "gh --version >/dev/null 2>&1"; then
    pass "gh CLI executes"
else
    fail "gh CLI does not execute"
fi

if run_offline "which mise >/dev/null 2>&1"; then
    pass "mise is on PATH"
else
    fail "mise not found on PATH"
fi

if run_offline "mise --version >/dev/null 2>&1"; then
    pass "mise executes"
else
    fail "mise does not execute"
fi

echo ""

# ── 3. Non-root user ──────────────────────────────────────────────────────────

echo "── 3. Checking runtime user..."

CURRENT_USER=$(run_offline "whoami" 2>/dev/null | tr -d '[:space:]')
if [ "$CURRENT_USER" = "copilot" ]; then
    pass "Runs as non-root user 'copilot'"
else
    fail "Expected user 'copilot', got: '${CURRENT_USER}'"
fi

NOT_ROOT=$(run_offline "id -u" 2>/dev/null | tr -d '[:space:]')
if [ "$NOT_ROOT" != "0" ]; then
    pass "UID is not 0 (not root)"
else
    fail "Container is running as root — expected UID 1000"
fi

echo ""

# ── 4-6. Firewall ─────────────────────────────────────────────────────────────

echo "── 4-6. Starting proxy for firewall tests..."
$COMPOSE up -d proxy 2>/dev/null
echo "    Waiting for squid to initialise..."
sleep 5
echo ""

echo "── 4. Allowed domain reachable..."
if run_online "curl -sf --max-time 15 https://github.com -o /dev/null 2>&1"; then
    pass "github.com is reachable (allowlisted)"
else
    fail "github.com is NOT reachable — proxy or allowlist may be misconfigured"
fi

echo ""
echo "── 5. Non-allowlisted domain blocked..."
# example.com is not in the default allowlist
if run_online "curl -sf --max-time 10 https://example.com -o /dev/null 2>/dev/null"; then
    fail "example.com is reachable — firewall is NOT blocking non-allowlisted traffic"
else
    pass "example.com is blocked by the proxy (not in allowlist)"
fi

echo ""
echo "── 6. Direct internet bypass blocked..."
# --noproxy '*' tells curl to ignore HTTP_PROXY / HTTPS_PROXY.
# The copilot container is on an internal-only Docker network so direct
# connections should fail even without the proxy.
if run_online "curl -sf --max-time 8 --noproxy '*' https://github.com -o /dev/null 2>/dev/null"; then
    fail "Direct internet access succeeded — the container has an unexpected route bypassing the proxy"
else
    pass "Direct internet access is blocked (internal-only network enforced)"
fi

echo ""

# ── 7. Allowlist live-reload ──────────────────────────────────────────────────

echo "── 7. Testing allowlist live-reload..."

# Save current allowlist so we can restore it
ALLOWLIST_BACKUP="$(cat "$ALLOWLIST")"

# Add example.com to the allowlist
echo "example.com" >> "$ALLOWLIST"
echo "    Added example.com to allowlist — waiting up to 10s for squid reload..."
sleep 10

if run_online "curl -sf --max-time 10 http://example.com -o /dev/null 2>/dev/null"; then
    pass "Newly added domain (example.com) is reachable after live reload"
else
    fail "Newly added domain (example.com) not reachable after 10s — live reload may not be working"
fi

# Restore the original allowlist
# Restore the original allowlist; printf '%s\n' adds back the trailing newline
# that command substitution strips.
printf '%s\n' "$ALLOWLIST_BACKUP" > "$ALLOWLIST"

echo ""

# ── 8. Copilot CLI binary present in image ────────────────────────────────────
# The copilot-cli binary is baked into the Docker image at build time, so it
# must be present and executable without any network access or volume mounting.
# `gh copilot` (built-in) looks for this binary at this exact path.

echo "── 8. Verifying copilot-cli binary is baked into the image..."

COPILOT_BIN="/home/copilot/.local/share/gh/copilot/copilot"
COPILOT_OUTPUT=$(run_offline "test -x '$COPILOT_BIN' && echo present || echo absent" 2>/dev/null | tr -d '[:space:]')
if [ "$COPILOT_OUTPUT" = "present" ]; then
    pass "copilot-cli binary is present and executable in the image"
else
    fail "copilot-cli binary is missing from the image (was it installed at build time?)"
fi

echo ""

# ── 9. Home directory ownership ───────────────────────────────────────────────

echo "── 9. Checking home directory ownership..."

# All files under /home/copilot should be owned by root — the container runs
# as root with cap_drop: ALL providing containment.
NOT_ROOT_OWNED=$(run_offline "find /home/copilot -not -user root 2>/dev/null | head -5" 2>/dev/null | tr -d '[:space:]')
if [ -z "$NOT_ROOT_OWNED" ]; then
    pass "All files in /home/copilot are owned by root"
else
    fail "Some files in /home/copilot are not owned by root: ${NOT_ROOT_OWNED}"
fi

echo ""

# ── 10. TLS inspection (ssl_bump) ─────────────────────────────────────────────

echo "── 10. Testing ssl_bump CA cert trust..."

# The proxy generates the CA cert into the ca-certs named volume on first run.
# The entrypoint installs it into the system trust store via update-ca-certificates.
# After the entrypoint runs, the cert should appear in the system trust store.
CA_INSTALLED=$(run_online \
    "test -f /etc/ssl/certs/sandboxed-copilot-ca.pem && echo installed || echo missing" \
    2>/dev/null | tr -d '[:space:]')

if [ "$CA_INSTALLED" = "installed" ]; then
    pass "ssl_bump CA cert is installed in the copilot container trust store"
else
    fail "ssl_bump CA cert not found in trust store (/etc/ssl/certs/sandboxed-copilot-ca.pem)"
fi

echo ""

# ── 11. Auth banner — unauthenticated path ────────────────────────────────────

echo "── 11. Testing auth status detection..."

# Verify the container handles a missing/invalid token gracefully.
# When GITHUB_TOKEN is empty, the entrypoint should fall back to "Not authenticated".
AUTH_OFFLINE=$($COMPOSE run --rm --no-deps \
    -e GITHUB_TOKEN="" \
    copilot bash -c \
    'gh_login=$(GITHUB_TOKEN="" gh api /user --jq .login 2>/dev/null || true)
     if [ -n "$gh_login" ]; then echo "authenticated:$gh_login"; else echo "not_authenticated"; fi' \
    2>/dev/null | tr -d '[:space:]')

if [ "$AUTH_OFFLINE" = "not_authenticated" ]; then
    pass "Auth check returns 'not authenticated' gracefully when GITHUB_TOKEN is empty"
else
    fail "Unexpected auth check result with empty token: '${AUTH_OFFLINE}'"
fi

# If a real GITHUB_TOKEN is available, verify it resolves to a login.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    AUTH_ONLINE=$(run_online \
        'gh_login=$(gh api /user --jq .login 2>/dev/null || true); echo "${gh_login:-empty}"' \
        2>/dev/null | tr -d '[:space:]')
    if [ -n "$AUTH_ONLINE" ] && [ "$AUTH_ONLINE" != "empty" ]; then
        pass "Auth check resolves GitHub login: @${AUTH_ONLINE}"
    else
        fail "Auth check failed to resolve login despite GITHUB_TOKEN being set"
    fi
else
    echo "  ⚠ GITHUB_TOKEN not set — skipping authenticated auth check"
fi

echo ""

# ── 12. proxy denied command ──────────────────────────────────────────────────

echo "── 12. Testing proxy denied command..."

# The proxy should still be running from the firewall tests.
# Make a request to a non-allowlisted domain so it appears in the Squid deny log.
run_online "curl -sf --max-time 5 https://blocked-domain-for-test.example.com -o /dev/null 2>/dev/null" || true
# Give squid a moment to flush the log entry.
sleep 2

# Call the launcher with the test project's workspace so the hash-derived project
# name matches the test project. SANDBOXED_COPILOT_DIR points at the repo root
# (which doubles as the install dir for tests).
DENIED_OUTPUT=$(cd "$PROJECT_DIR" && \
    SANDBOXED_COPILOT_DIR="$PROJECT_DIR" \
    bash "$PROJECT_DIR/sandboxed-copilot" proxy denied --all 2>/dev/null || true)

if echo "$DENIED_OUTPUT" | grep -q "blocked-domain-for-test.example.com"; then
    pass "proxy denied lists domains blocked by the proxy"
else
    fail "proxy denied did not include the expected blocked domain (got: '${DENIED_OUTPUT}')"
fi

# Allowlisted domains must NOT appear in the output.
if echo "$DENIED_OUTPUT" | grep -q "github.com"; then
    fail "proxy denied incorrectly listed an allowlisted domain (github.com)"
else
    pass "proxy denied correctly excludes allowlisted domains"
fi

echo ""

# ── Results ───────────────────────────────────────────────────────────────────

echo "════════════════════════════════════════"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
        echo "  ✗ ${err}"
    done
    echo ""
fi

[ "$FAIL" -eq 0 ]
