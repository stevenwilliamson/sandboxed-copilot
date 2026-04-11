#!/usr/bin/env bash
# install.sh — install sandboxed-copilot on this machine.
#
# Copies Docker assets to ~/.sandboxed-copilot/ and installs the
# sandboxed-copilot launcher script to ~/.local/bin/.
#
# Run with:  bash install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SANDBOXED_COPILOT_DIR:-${HOME}/.sandboxed-copilot}"
BIN_DIR="${HOME}/.local/bin"

echo "Installing sandboxed-copilot..."
echo ""

mkdir -p "$INSTALL_DIR" "$BIN_DIR"

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

# Save the source directory so 'sandboxed-copilot update' can re-sync files.
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

# ---------------------------------------------------------------------------
# Generate a per-install CA certificate for TLS inspection (ssl_bump).
# The proxy uses this CA to dynamically sign certificates for each upstream
# host it intercepts. Both files are mounted read-only into the proxy;
# only ca.crt is mounted into the copilot container (the agent never sees
# the private key).
#
# ca.key  — private key (chmod 600). Stays on the host filesystem only.
# ca.crt  — self-signed CA cert. Mounted :ro into proxy and copilot containers.
#
# Both files are preserved on re-install. Delete them, clear the ssl-db
# Docker volume, and re-run install.sh to rotate the CA cleanly.
# ---------------------------------------------------------------------------
CA_KEY="${INSTALL_DIR}/config/ca.key"
CA_CERT="${INSTALL_DIR}/config/ca.crt"

if [ ! -f "$CA_KEY" ] || [ ! -f "$CA_CERT" ]; then
    echo "  Generating per-install CA certificate for TLS inspection..."
    openssl req -new -newkey rsa:4096 -days 1825 -nodes -x509 \
        -subj "/CN=sandboxed-copilot CA/O=sandboxed-copilot" \
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
cp "${SCRIPT_DIR}/sandboxed-copilot" "${BIN_DIR}/sandboxed-copilot"
chmod +x "${BIN_DIR}/sandboxed-copilot"
echo "  Installed ${BIN_DIR}/sandboxed-copilot"

echo ""
echo "Building Docker images (this may take a few minutes)..."
# Use a stable project name so images are always built as sandboxed-copilot-copilot
# and sandboxed-copilot-proxy regardless of the install directory name.
docker compose \
    -f "${INSTALL_DIR}/docker-compose.yml" \
    --project-directory "${INSTALL_DIR}" \
    --project-name sandboxed-copilot \
    build

echo ""
echo "✓ Installation complete!"
echo ""
echo "Usage:"
echo "  cd /your/project"
echo "  sandboxed-copilot                      # open an interactive shell"
echo "  sandboxed-copilot gh copilot suggest … # run a copilot command"
echo ""
echo "To update to the latest version:"
echo "  sandboxed-copilot update"
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
    if grep -qF 'sandboxed-copilot completion bash' "$rc_file" 2>/dev/null; then
        echo "  Shell completion already configured in ${rc_file}"
    else
        echo "" >> "$rc_file"
        echo "# sandboxed-copilot shell completion" >> "$rc_file"
        echo 'source <(sandboxed-copilot completion bash)' >> "$rc_file"
        echo "  ✓ Added bash completion to ${rc_file}"
        echo "    Run: source ${rc_file}  (or open a new terminal)"
    fi
}

setup_completion_zsh() {
    local rc_file="$1"
    if grep -qF 'sandboxed-copilot completion zsh' "$rc_file" 2>/dev/null; then
        echo "  Shell completion already configured in ${rc_file}"
    else
        echo "" >> "$rc_file"
        echo "# sandboxed-copilot shell completion" >> "$rc_file"
        echo 'source <(sandboxed-copilot completion zsh)' >> "$rc_file"
        echo "  ✓ Added zsh completion to ${rc_file}"
        echo "    Run: source ${rc_file}  (or open a new terminal)"
    fi
}

setup_completion_fish() {
    local comp_dir="${HOME}/.config/fish/completions"
    local comp_file="${comp_dir}/sandboxed-copilot.fish"
    mkdir -p "$comp_dir"
    "${BIN_DIR}/sandboxed-copilot" completion fish > "$comp_file"
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
                echo "    echo 'source <(sandboxed-copilot completion bash)' >> ~/.bashrc"
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
                echo "    echo 'source <(sandboxed-copilot completion zsh)' >> ~/.zshrc"
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
                echo "    sandboxed-copilot completion fish > ~/.config/fish/completions/sandboxed-copilot.fish"
                ;;
        esac
        echo ""
        ;;
esac

if [ "$_offered_completion" = false ]; then
    echo "Shell completion is available. Enable it with:"
    echo "  source <(sandboxed-copilot completion bash)   # bash → add to ~/.bashrc"
    echo "  source <(sandboxed-copilot completion zsh)    # zsh  → add to ~/.zshrc"
    echo "  sandboxed-copilot completion fish > ~/.config/fish/completions/sandboxed-copilot.fish"
    echo ""
fi

# Warn if ~/.local/bin is not in PATH
if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
    echo "⚠️  ${BIN_DIR} is not in your PATH. Add it with:"
    echo "   echo 'export PATH=\"\${HOME}/.local/bin:\${PATH}\"' >> ~/.zshrc"
    echo "   echo 'export PATH=\"\${HOME}/.local/bin:\${PATH}\"' >> ~/.bashrc"
    echo ""
fi
