#!/usr/bin/env bash
# uninstall.sh — remove sandboxed-copilot from this machine.
#
# Stops all running sandboxed-copilot containers (any session/project),
# removes Docker images and volumes, deletes the install directory,
# and removes the launcher binary.
#
# Run this script directly from the install directory:
#   ~/.sandboxed-copilot/uninstall.sh
# or from the repository:
#   ./uninstall.sh
#
# Set SANDBOXED_COPILOT_DIR to override the install location.

set -euo pipefail

INSTALL_DIR="${SANDBOXED_COPILOT_DIR:-${HOME}/.sandboxed-copilot}"
BIN_DIR="${HOME}/.local/bin"

ok()   { printf '  \033[32m✓\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m  %s\n' "$1"; }
info() { printf '      %s\n' "$1"; }

echo ""
echo "Uninstalling sandboxed-copilot …"
echo ""

# ---------------------------------------------------------------------------
# 1. Stop all running sandboxed-copilot containers (all sessions/projects)
# ---------------------------------------------------------------------------
echo "Stopping containers …"
# Collect containers from all known image names (all variants + proxy + legacy name).
ALL_IDS=$(
    for _img in sandboxed-copilot-minimal sandboxed-copilot-standard sandboxed-copilot-full \
                sandboxed-copilot-copilot sandboxed-copilot-proxy; do
        docker ps -q --filter "ancestor=${_img}" 2>/dev/null || true
    done | sort -u
)
if [ -n "$ALL_IDS" ]; then
    # shellcheck disable=SC2086
    docker stop $ALL_IDS > /dev/null 2>&1 || true
    ok "Stopped running containers"
else
    info "No running containers found"
fi

# Remove all stopped sandboxed-copilot containers (any project name prefix).
ALL_CONTAINER_IDS=$(
    for _img in sandboxed-copilot-minimal sandboxed-copilot-standard sandboxed-copilot-full \
                sandboxed-copilot-copilot sandboxed-copilot-proxy; do
        docker ps -aq --filter "ancestor=${_img}" 2>/dev/null || true
    done | sort -u
)
if [ -n "$ALL_CONTAINER_IDS" ]; then
    # shellcheck disable=SC2086
    docker rm -f $ALL_CONTAINER_IDS > /dev/null 2>&1 || true
    ok "Removed stopped containers"
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Remove Docker images
# ---------------------------------------------------------------------------
echo "Removing Docker images …"
REMOVED_ANY=false
for img in sandboxed-copilot-minimal sandboxed-copilot-standard sandboxed-copilot-full \
           sandboxed-copilot-copilot sandboxed-copilot-proxy; do
    if docker image inspect "$img" > /dev/null 2>&1; then
        if docker rmi "$img" > /dev/null 2>&1; then
            ok "Removed image: $img"
            REMOVED_ANY=true
        else
            fail "Could not remove image: $img (a container may still be using it)"
        fi
    else
        info "Image not found (already removed): $img"
    fi
done
# Remove any custom project images (tagged sandboxed-copilot-custom-*)
CUSTOM_IMAGES=$(docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep '^sandboxed-copilot-custom-' || true)
for img in $CUSTOM_IMAGES; do
    if docker rmi "$img" > /dev/null 2>&1; then
        ok "Removed custom image: $img"
        REMOVED_ANY=true
    else
        fail "Could not remove custom image: $img"
    fi
done
$REMOVED_ANY || info "No images were removed"
echo ""

# ---------------------------------------------------------------------------
# 3. Remove named Docker volumes
# ---------------------------------------------------------------------------
echo "Removing Docker volumes …"
REMOVED_ANY=false

# Remove per-session shell-history volumes (pattern: sandboxed-copilot-*_shell-history).
SESSION_VOLS=$(docker volume ls --format '{{.Name}}' \
    | grep -E '^sandboxed-copilot-[0-9]+_shell-history$' || true)
for vol in $SESSION_VOLS; do
    if docker volume rm "$vol" > /dev/null 2>&1; then
        ok "Removed volume: $vol"
        REMOVED_ANY=true
    else
        fail "Could not remove volume: $vol"
    fi
done

# Remove ssl_db volumes used by the proxy for dynamic cert caching.
# These may have a session-hash prefix (sandboxed-copilot-NNNNNNNN_ssl-db)
# when created via the launcher, or no prefix when created via install.sh.
# Must be removed on uninstall so a new CA cert isn't undermined by stale
# cached leaf certs that were signed with the old CA key.
SSL_DB_VOLS=$(docker volume ls --format '{{.Name}}' \
    | grep -E '^sandboxed-copilot(-[0-9]+)?_ssl-db$' || true)
for vol in $SSL_DB_VOLS; do
    if docker volume rm "$vol" > /dev/null 2>&1; then
        ok "Removed volume: $vol"
        REMOVED_ANY=true
    else
        fail "Could not remove volume: $vol"
    fi
done

$REMOVED_ANY || info "No volumes were removed"
echo ""

# ---------------------------------------------------------------------------
# 4. Remove the install directory
# ---------------------------------------------------------------------------
echo "Removing install directory …"
if [ -d "$INSTALL_DIR" ]; then
    if rm -rf "$INSTALL_DIR"; then
        ok "Removed ${INSTALL_DIR}"
    else
        fail "Could not remove ${INSTALL_DIR}"
    fi
else
    info "Install directory not found: ${INSTALL_DIR}"
fi
echo ""

# ---------------------------------------------------------------------------
# 5. Remove the launcher binary
# ---------------------------------------------------------------------------
echo "Removing launcher binary …"
LAUNCHER="${BIN_DIR}/sandboxed-copilot"
if [ -f "$LAUNCHER" ]; then
    if rm -f "$LAUNCHER"; then
        ok "Removed ${LAUNCHER}"
    else
        fail "Could not remove ${LAUNCHER}"
    fi
else
    info "Launcher not found: ${LAUNCHER}"
fi
echo ""

echo "✓ sandboxed-copilot has been uninstalled."
echo ""
echo "To reinstall, clone the repository and run install.sh."
echo ""
