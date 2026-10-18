#!/usr/bin/env bash
# install.sh — install sandbox on this machine.
#
# Copies Docker assets to ~/.sandbox/ and installs the
# sandbox launcher script to ~/.local/bin/.
#
# Run with:  bash install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SANDBOX_DIR:-${HOME}/.sandbox}"
BIN_DIR="${HOME}/.local/bin"
LEGACY_INSTALL_DIR="${HOME}/.sandboxed-copilot"

echo "Installing sandbox..."
echo ""

mkdir -p "$INSTALL_DIR" "$BIN_DIR"

# ---------------------------------------------------------------------------
# Migration from sandboxed-copilot (the pre-rename install layout).
# Carries over configuration and session state on a first install only, so a
# re-run never overwrites the current install with stale legacy files.
#
# Deliberately not migrated: config/ca.crt and ca.key. A fresh per-install CA is
# generated below, and the proxy detects the fingerprint change and clears its
# stale leaf-certificate cache automatically.
# ---------------------------------------------------------------------------
if [ -d "$LEGACY_INSTALL_DIR" ] && [ ! -f "${INSTALL_DIR}/VERSION" ]; then
    echo "Found a sandboxed-copilot install at ${LEGACY_INSTALL_DIR}"
    echo "Migrating your configuration..."
    mkdir -p "${INSTALL_DIR}/config"

    for _f in allowlist.txt package-cooldown .mode allow-github-releases; do
        if [ -e "${LEGACY_INSTALL_DIR}/config/${_f}" ]; then
            cp -R "${LEGACY_INSTALL_DIR}/config/${_f}" "${INSTALL_DIR}/config/${_f}"
            echo "  Migrated config/${_f}"
        fi
    done

    # Session state moved from sessions/<hash>/ to sessions/<hash>/copilot/ when
    # Claude Code was added, since each agent now gets its own subdirectory.
    if [ -d "${LEGACY_INSTALL_DIR}/sessions" ]; then
        for _sdir in "${LEGACY_INSTALL_DIR}/sessions"/*; do
            [ -d "$_sdir" ] || continue
            _hash=$(basename "$_sdir")
            mkdir -p "${INSTALL_DIR}/sessions/${_hash}/copilot"
            # Copy contents, including dotfiles, without failing on an empty dir.
            find "$_sdir" -mindepth 1 -maxdepth 1 \
                -exec cp -R {} "${INSTALL_DIR}/sessions/${_hash}/copilot/" \; 2>/dev/null || true
        done
        echo "  Migrated Copilot session state to sessions/<hash>/copilot/"
    fi

    echo ""
    echo "  The old install is left untouched. Once you're happy with the new one:"
    echo "    bash ${LEGACY_INSTALL_DIR}/uninstall.sh"
    echo ""
fi

# The launcher was renamed, so remove the old one to stop it shadowing `sandbox`
# with a script that points at the previous install directory.
if [ -f "${BIN_DIR}/sandboxed-copilot" ]; then
    rm -f "${BIN_DIR}/sandboxed-copilot"
    echo "  Removed the old launcher ${BIN_DIR}/sandboxed-copilot"
fi

# Copy Docker build assets
cp "${SCRIPT_DIR}/Dockerfile"     "${INSTALL_DIR}/Dockerfile"
cp "${SCRIPT_DIR}/entrypoint.sh"  "${INSTALL_DIR}/entrypoint.sh"
cp "${SCRIPT_DIR}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"

# Sync the proxy directory
rm -rf "${INSTALL_DIR}/proxy"
cp -r "${SCRIPT_DIR}/proxy" "${INSTALL_DIR}/proxy"

# Copy the uninstall script so it's available after the repo is removed.
cp "${SCRIPT_DIR}/uninstall.sh" "${INSTALL_DIR}/uninstall.sh"
chmod +x "${INSTALL_DIR}/uninstall.sh"

# Save the source directory so 'sandbox update' can re-sync files.
printf '%s\n' "$SCRIPT_DIR" > "${INSTALL_DIR}/source_dir"

# Copy the VERSION file.
cp "${SCRIPT_DIR}/VERSION" "${INSTALL_DIR}/VERSION"
echo "  Version  $(cat "${SCRIPT_DIR}/VERSION")"

# Write the default allowlist on first install.
# On re-installs, write allowlist.txt.new alongside the existing file so the
# user can diff and merge any upstream changes without losing their customisations.
mkdir -p "${INSTALL_DIR}/config"
if [ ! -f "${INSTALL_DIR}/config/allowlist.txt" ]; then
    cp "${SCRIPT_DIR}/config/allowlist.txt" "${INSTALL_DIR}/config/allowlist.txt"
    echo "  Created  ${INSTALL_DIR}/config/allowlist.txt"
else
    cp "${SCRIPT_DIR}/config/allowlist.txt" "${INSTALL_DIR}/config/allowlist.txt.new"
    echo "  Preserved ${INSTALL_DIR}/config/allowlist.txt (your configuration)"
    echo "  Written   ${INSTALL_DIR}/config/allowlist.txt.new (updated defaults — diff and merge as needed)"
fi

# The project-level allowlist is created per-session by the launcher with a
# name unique to the workspace path. No default file is needed here.

# Copy the seccomp profile used by docker-compose.yml for the agent container.
cp "${SCRIPT_DIR}/config/seccomp.json" "${INSTALL_DIR}/config/seccomp.json"

# Write package dependency cooldown config (default: 7 days) on first install.
# On re-install, preserve the existing value so user customisation is not lost.
_cooldown_file="${INSTALL_DIR}/config/package-cooldown"
if [ ! -f "$_cooldown_file" ]; then
    cp "${SCRIPT_DIR}/config/package-cooldown" "$_cooldown_file"
    echo "  Created  ${_cooldown_file} (7 day cooldown — sandbox cooldown N to change)"
else
    _current_days=$(tr -d '[:space:]' < "$_cooldown_file")
    echo "  Preserved ${_cooldown_file} (current: ${_current_days} day(s))"
fi

# Create custom-image-hashes file (tracks Dockerfile content hashes for auto-rebuild).
_hash_file="${INSTALL_DIR}/config/custom-image-hashes"
if [ ! -f "$_hash_file" ]; then
    touch "$_hash_file"
    echo "  Created  ${_hash_file}"
fi

# ---------------------------------------------------------------------------
# Generate a per-install CA certificate for TLS inspection (ssl_bump).
# The proxy uses this CA to dynamically sign certificates for each upstream
# host it intercepts. Both files are mounted read-only into the proxy;
# only ca.crt is mounted into the agent container (the agent never sees
# the private key).
#
# ca.key  — private key (chmod 600). Stays on the host filesystem only.
# ca.crt  — self-signed CA cert. Mounted :ro into the proxy and agent containers.
#
# Both files are preserved on re-install. Delete them, clear the ssl-db
# Docker volume, and re-run install.sh to rotate the CA cleanly.
# ---------------------------------------------------------------------------
CA_KEY="${INSTALL_DIR}/config/ca.key"
CA_CERT="${INSTALL_DIR}/config/ca.crt"

if [ ! -f "$CA_KEY" ] || [ ! -f "$CA_CERT" ]; then
    echo "  Generating per-install CA certificate for TLS inspection..."
    openssl req -new -newkey rsa:4096 -days 1825 -nodes -x509 \
        -subj "/CN=sandbox CA/O=sandbox" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -keyout "$CA_KEY" \
        -out "$CA_CERT" \
        2>/dev/null
    chmod 600 "$CA_KEY"
    echo "  Created  ${CA_CERT}"
    echo "  Created  ${CA_KEY} (private key — stays on host only)"
else
    echo "  Preserved ${CA_CERT} (existing CA — delete + re-run install.sh to rotate)"
fi

# Install the launcher script
cp "${SCRIPT_DIR}/sandbox" "${BIN_DIR}/sandbox"
chmod +x "${BIN_DIR}/sandbox"
echo "  Installed ${BIN_DIR}/sandbox"

echo ""
echo "Building Docker images (this may take several minutes)..."
echo "  Building proxy..."
# Build the proxy image via docker compose (handles its own build context)
docker compose \
    -f "${INSTALL_DIR}/docker-compose.yml" \
    --project-directory "${INSTALL_DIR}" \
    --project-name sandbox \
    build proxy

# Build all three variant images.
# The 'full' variant includes Google Chrome (~350MB download) which adds a few minutes.
for _v in minimal standard full; do
    echo "  Building sandbox-${_v} ..."
    docker build --target "$_v" -t "sandbox-${_v}" "$INSTALL_DIR"
done

echo ""
echo "✓ Installation complete!"
echo ""
echo "Usage:"
echo "  cd /your/project"
echo "  sandbox            # open an interactive shell (standard variant)"
echo "  sandbox claude     # launch Claude Code"
echo "  sandbox copilot    # launch GitHub Copilot CLI"
echo "  sandbox minimal    # minimal variant (mise only)"
echo "  sandbox full       # full variant (+ Google Chrome)"
echo ""
echo "Claude Code signs in inside the sandbox — run 'sandbox claude', then /login."
echo "The login is stored under ${INSTALL_DIR}/agents/claude and shared by all projects."
echo ""
echo "To update to the latest version:"
echo "  sandbox update"
echo ""
echo "To add domains to the outbound allowlist:"
echo "  \$EDITOR ${INSTALL_DIR}/config/allowlist.txt"
echo "  (the proxy reloads automatically within 5 seconds)"
echo ""

# ---------------------------------------------------------------------------
# Shell completion setup
# ---------------------------------------------------------------------------
_detected_shell=$(basename "${SHELL:-}")
_offered_completion=false

setup_completion_bash() {
    local rc_file="$1"
    if grep -qF 'sandbox completion bash' "$rc_file" 2>/dev/null; then
        echo "  Shell completion already configured in ${rc_file}"
    else
        echo "" >> "$rc_file"
        echo "# sandbox shell completion" >> "$rc_file"
        echo 'source <(sandbox completion bash)' >> "$rc_file"
        echo "  ✓ Added bash completion to ${rc_file}"
        echo "    Run: source ${rc_file}  (or open a new terminal)"
    fi
}

setup_completion_zsh() {
    local rc_file="$1"
    if grep -qF 'sandbox completion zsh' "$rc_file" 2>/dev/null; then
        echo "  Shell completion already configured in ${rc_file}"
    else
        echo "" >> "$rc_file"
        echo "# sandbox shell completion" >> "$rc_file"
        echo 'source <(sandbox completion zsh)' >> "$rc_file"
        echo "  ✓ Added zsh completion to ${rc_file}"
        echo "    Run: source ${rc_file}  (or open a new terminal)"
    fi
}

setup_completion_fish() {
    local comp_dir="${HOME}/.config/fish/completions"
    local comp_file="${comp_dir}/sandbox.fish"
    mkdir -p "$comp_dir"
    "${BIN_DIR}/sandbox" completion fish > "$comp_file"
    echo "  ✓ Wrote fish completions to ${comp_file}"
}

case "$_detected_shell" in
    bash)
        _offered_completion=true
        echo "Shell completion is available for bash."
        printf "  Add to ~/.bashrc? [Y/n] "
        read -r _answer </dev/tty
        case "${_answer:-Y}" in
            [Yy]*|"")
                setup_completion_bash "${HOME}/.bashrc"
                ;;
            *)
                echo "  Skipped. To enable manually:"
                echo "    echo 'source <(sandbox completion bash)' >> ~/.bashrc"
                ;;
        esac
        echo ""
        ;;
    zsh)
        _offered_completion=true
        echo "Shell completion is available for zsh."
        printf "  Add to ~/.zshrc? [Y/n] "
        read -r _answer </dev/tty
        case "${_answer:-Y}" in
            [Yy]*|"")
                setup_completion_zsh "${HOME}/.zshrc"
                ;;
            *)
                echo "  Skipped. To enable manually:"
                echo "    echo 'source <(sandbox completion zsh)' >> ~/.zshrc"
                ;;
        esac
        echo ""
        ;;
    fish)
        _offered_completion=true
        echo "Shell completion is available for fish."
        printf "  Install fish completions? [Y/n] "
        read -r _answer </dev/tty
        case "${_answer:-Y}" in
            [Yy]*|"")
                setup_completion_fish
                ;;
            *)
                echo "  Skipped. To enable manually:"
                echo "    sandbox completion fish > ~/.config/fish/completions/sandbox.fish"
                ;;
        esac
        echo ""
        ;;
esac

if [ "$_offered_completion" = false ]; then
    echo "Shell completion is available. Enable it with:"
    echo "  source <(sandbox completion bash)   # bash → add to ~/.bashrc"
    echo "  source <(sandbox completion zsh)    # zsh  → add to ~/.zshrc"
    echo "  sandbox completion fish > ~/.config/fish/completions/sandbox.fish"
    echo ""
fi

# Warn if ~/.local/bin is not in PATH
if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
    echo "⚠️  ${BIN_DIR} is not in your PATH. Add it with:"
    echo "   echo 'export PATH=\"\${HOME}/.local/bin:\${PATH}\"' >> ~/.zshrc"
    echo "   echo 'export PATH=\"\${HOME}/.local/bin:\${PATH}\"' >> ~/.bashrc"
    echo ""
fi
