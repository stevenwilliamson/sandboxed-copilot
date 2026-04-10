#!/usr/bin/env bash
set -e

# Install the gh-copilot extension if not already present in the volume.
# Uses the GitHub releases API directly so no gh authentication is required.
# GITHUB_TOKEN is used when set for better API rate limits.
install_copilot_extension() {
    local ext_dir="$HOME/.local/share/gh/extensions/gh-copilot"
    local arch
    arch=$(uname -m)
    local arch_pattern
    case "$arch" in
        x86_64)  arch_pattern="amd64" ;;
        aarch64) arch_pattern="arm64" ;;
        *) echo "[sandboxed-copilot] Warning: Unsupported architecture: $arch" >&2; return 1 ;;
    esac

    local api_url="https://api.github.com/repos/github/gh-copilot/releases/latest"
    local -a curl_args=(-sf --max-time 30)
    [ -n "${GITHUB_TOKEN:-}" ] && curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")

    # Fetch release metadata and find the asset URL for this architecture.
    # Try several naming patterns used by different gh extension releases.
    local release_data download_url=""
    release_data=$(curl "${curl_args[@]}" "$api_url" 2>/dev/null) || return 1

    for pattern in "linux.*${arch_pattern}" "${arch_pattern}.*linux" "linux_${arch_pattern}"; do
        download_url=$(printf '%s' "$release_data" | \
            jq -r ".assets[]? | select(.name | test(\"${pattern}\"; \"i\")) | .browser_download_url" \
            2>/dev/null | head -1)
        [ -n "$download_url" ] && break
    done

    if [ -z "$download_url" ]; then
        echo "[sandboxed-copilot] Warning: No release asset found for linux/${arch_pattern}." >&2
        return 1
    fi

    mkdir -p "$ext_dir"
    curl -sfL --max-time 120 "$download_url" -o "$ext_dir/gh-copilot" \
        && chmod +x "$ext_dir/gh-copilot"
}

if [ ! -f "$HOME/.local/share/gh/extensions/gh-copilot/gh-copilot" ]; then
    echo "[sandboxed-copilot] Installing gh-copilot extension..." >&2
    if install_copilot_extension; then
        echo "[sandboxed-copilot] gh-copilot extension installed." >&2
    else
        echo "[sandboxed-copilot] Warning: Could not install gh-copilot extension." >&2
        echo "[sandboxed-copilot] Set GITHUB_TOKEN for authenticated access, or run:" >&2
        echo "[sandboxed-copilot]   gh extension install github/gh-copilot" >&2
    fi
fi

# Persist shell history across sessions via the shell-history named volume.
export PROMPT_COMMAND='history -a'
mkdir -p "$(dirname "${HISTFILE:-$HOME/.bash_history}")"

# Fix git credential helper for cross-platform use.
#
# The host ~/.gitconfig may contain a credential.helper pointing to a macOS
# binary (e.g. /opt/homebrew/bin/gh) that does not exist inside the container.
# We create a wrapper gitconfig that:
#   1. Includes the host config (preserving name, email, aliases, etc.)
#   2. Resets credential.helper to an empty string (clears the macOS value)
#   3. Sets credential.helper to the container's gh CLI
#
# GIT_CONFIG_GLOBAL overrides the default ~/.gitconfig path so git (and all
# tools it spawns) pick up the wrapper automatically.
if [ -f "${HOME}/.gitconfig" ]; then
    # Find gh so the credential helper works regardless of PATH ordering.
    GH_BIN=$(command -v gh 2>/dev/null || echo "/usr/bin/gh")
    cat > "${HOME}/.gitconfig.container" <<EOF
[include]
    path = ${HOME}/.gitconfig
[credential]
    helper =
    helper = !${GH_BIN} auth git-credential
EOF
    export GIT_CONFIG_GLOBAL="${HOME}/.gitconfig.container"
fi

# Welcome banner — only shown for interactive sessions, not for non-interactive
# commands like `sandboxed-copilot gh copilot suggest "..."`.
if [ -t 0 ] && [ -t 1 ]; then
    ruby_ver=$(ruby --version 2>/dev/null | cut -d' ' -f2 || echo "n/a")
    python_ver=$(python --version 2>/dev/null | cut -d' ' -f2 || echo "n/a")
    node_ver=$(node --version 2>/dev/null | cut -c2- 2>/dev/null || echo "n/a")
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        gh_login=$(gh api /user --jq .login 2>/dev/null || true)
    fi
    if [ -n "${gh_login:-}" ]; then
        auth_line="✓ Authenticated as @${gh_login}"
    else
        auth_line="⚠  Not authenticated — set GITHUB_TOKEN on the host"
    fi
    echo ""
    echo "  --- sandboxed-copilot --------------------------------------------------"
    echo "  Workspace  $PWD"
    printf "  Tools      ruby %-10s python %-10s node %-10s mise\n" \
        "$ruby_ver" "$python_ver" "$node_ver"
    echo "  Auth       ${auth_line}"
    echo "  Proxy      active  (from host: sandboxed-copilot proxy status)"
    echo "  ------------------------------------------------------------------------"
    echo "  Type 'exit' or Ctrl-D to return to your host shell."
    echo ""
    # Hint if the project has mise config that might need runtime installation.
    if [ -f /workspace/.mise.toml ] || [ -f /workspace/.tool-versions ]; then
        echo "  ℹ  Project has mise config — run 'mise install' to set up runtimes."
        echo ""
    fi
fi

exec "$@"
