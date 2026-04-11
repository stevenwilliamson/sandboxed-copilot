#!/usr/bin/env bash
set -e

ALLOWLIST="/etc/squid/config/allowlist.txt"
# PROJECT_ALLOWLIST_FILE is injected by the launcher per session so concurrent
# sessions each write to their own file and don't clobber each other.
PROJECT_ALLOWLIST="/etc/squid/config/${PROJECT_ALLOWLIST_FILE:-project-allowlist.txt}"
MODE_FILE="/etc/squid/config/.mode"
ACCESS_RULES="/etc/squid/access_rules.conf"
MERGED_ALLOWLIST="/etc/squid/merged_allowlist.txt"
LOG_DIR="/var/log/squid"

# Minimum domains required for the Copilot CLI to function (used in lock mode).
LOCK_DOMAINS=".github.com .githubusercontent.com .githubcopilot.com default.exp-tas.com"

# Pre-create log files owned by the 'proxy' user that squid drops privileges to.
mkdir -p "$LOG_DIR"
touch "${LOG_DIR}/access.log" "${LOG_DIR}/cache.log"
chown proxy:proxy "${LOG_DIR}" "${LOG_DIR}/access.log" "${LOG_DIR}/cache.log"

# ---------------------------------------------------------------------------
# Generate the per-install CA certificate if not already present.
# The cert and key live in the ca-certs named volume (/etc/squid/ca) — not in
# the config bind-mount (which is read-only). This makes the proxy fully
# self-bootstrapping: no pre-flight step (install.sh) is required.
#
# The volume persists across container restarts. Deleting the ca-certs volume
# (e.g. during uninstall) causes a fresh CA to be generated on next startup.
# ---------------------------------------------------------------------------
CA_DIR="/etc/squid/ca"
mkdir -p "$CA_DIR"
if [ ! -f "${CA_DIR}/ca.key" ] || [ ! -f "${CA_DIR}/ca.crt" ]; then
    echo "[proxy] Generating per-install CA certificate for TLS inspection..."
    openssl req -new -newkey rsa:4096 -days 1825 -nodes -x509 \
        -subj "/CN=sandboxed-copilot CA/O=sandboxed-copilot" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -keyout "${CA_DIR}/ca.key" \
        -out "${CA_DIR}/ca.crt" \
        2>/dev/null
    chmod 600 "${CA_DIR}/ca.key"
    echo "[proxy] CA certificate generated."
fi

# ---------------------------------------------------------------------------
# Initialise the ssl_db certificate cache.
# Squid's security_file_certgen stores dynamically generated leaf certificates
# here. The directory must exist and be initialised before Squid starts.
# The 'proxy' user owns the directory because Squid drops privileges to it.
# ---------------------------------------------------------------------------
SSL_DB="/var/lib/ssl_db"
if [ ! -d "${SSL_DB}/index" ]; then
    echo "[proxy] Initialising ssl_db cert cache..."
    /usr/lib/squid/security_file_certgen -c -s "$SSL_DB" -M 4MB 2>/dev/null || true
fi
chown -R proxy:proxy "$SSL_DB" 2>/dev/null || true

# ---------------------------------------------------------------------------
# write_access_rules <mode>
#   Merges allowlist sources into a single file squid reads, then writes
#   access_rules.conf for the given mode. Using a single merged file avoids
#   squid silent-failure issues with multi-file dstdomain ACLs.
# ---------------------------------------------------------------------------
write_access_rules() {
    local mode="$1"

    # Always regenerate the merged allowlist so squid always reads a single,
    # fully-resolved file regardless of which source changed.
    cat "$ALLOWLIST" "$PROJECT_ALLOWLIST" 2>/dev/null > "$MERGED_ALLOWLIST" || true

    case "$mode" in
        allow-all)
            cat > "$ACCESS_RULES" <<'EOF'
# ALLOW-ALL MODE — proxy is fully open. This mode expires automatically.
# Safe_ports: deny plain HTTP to non-standard ports (belt-and-suspenders).
acl Safe_ports port 80 443
http_access deny !Safe_ports
http_access allow all
EOF
            echo "[proxy] Mode: allow-all — all outbound traffic permitted"
            ;;
        lock)
            # shellcheck disable=SC2086
            cat > "$ACCESS_RULES" <<EOF
# LOCK MODE — only the minimum domains required for Copilot CLI are reachable.
# CONNECT is restricted to port 443 to prevent SSH/non-HTTPS tunnelling.
# Safe_ports: deny plain HTTP to non-standard ports.
acl SSL_ports port 443
acl Safe_ports port 80 443
acl copilot_minimum dstdomain ${LOCK_DOMAINS}
http_access deny !Safe_ports
http_access allow CONNECT SSL_ports copilot_minimum
http_access allow copilot_minimum
http_access deny all
EOF
            echo "[proxy] Mode: lock — restricted to minimum Copilot domains"
            ;;
        *)
            cat > "$ACCESS_RULES" <<EOF
# NORMAL MODE — outbound access controlled by the merged allowlist.
# CONNECT is restricted to port 443 to prevent SSH/non-HTTPS tunnelling.
# Safe_ports: deny plain HTTP to non-standard ports.
acl SSL_ports port 443
acl Safe_ports port 80 443
acl allowed_domains dstdomain "${MERGED_ALLOWLIST}"
http_access deny !Safe_ports
http_access allow CONNECT SSL_ports allowed_domains
http_access allow allowed_domains
http_access deny all
EOF
            echo "[proxy] Mode: normal — using user allowlist"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# read_mode
#   Reads the current mode from MODE_FILE. Handles allow-all expiry.
# ---------------------------------------------------------------------------
read_mode() {
    if [ ! -f "$MODE_FILE" ]; then
        echo "normal"
        return
    fi

    local content
    content=$(cat "$MODE_FILE" 2>/dev/null || echo "")

    if [[ "$content" == allow-all:* ]]; then
        local expiry="${content#allow-all:}"
        local now
        now=$(date +%s)
        if [ "$now" -lt "$expiry" ]; then
            echo "allow-all"
        else
            echo "[proxy] allow-all expired — reverting to normal allowlist" >&2
            echo "normal"
        fi
    elif [ "$content" = "lock" ]; then
        echo "lock"
    else
        echo "normal"
    fi
}

# Write initial access rules before squid starts
write_access_rules "$(read_mode)"

# Initialise squid cache directories
echo "[proxy] Initialising squid..."
squid -z --foreground 2>/dev/null || true

# Stream squid log files to Docker stdout so `docker compose logs` works.
tail -qF "${LOG_DIR}/access.log" "${LOG_DIR}/cache.log" 2>/dev/null &

# ---------------------------------------------------------------------------
# watch_config
#   Polls every 5 seconds for changes to the mode file or allowlist.
#   Regenerates access_rules.conf and reconfigures squid as needed.
# ---------------------------------------------------------------------------
watch_config() {
    local last_mode=""
    local last_allowlist_hash=""
    last_mode=$(read_mode)
    last_allowlist_hash=$(cat "$ALLOWLIST" "$PROJECT_ALLOWLIST" 2>/dev/null | md5sum | cut -d' ' -f1)

    while true; do
        sleep 5

        local current_mode
        current_mode=$(read_mode)

        local current_allowlist_hash
        current_allowlist_hash=$(cat "$ALLOWLIST" "$PROJECT_ALLOWLIST" 2>/dev/null | md5sum | cut -d' ' -f1)

        if [ "$current_mode" != "$last_mode" ] || \
           { [ "$current_mode" = "normal" ] && [ "$current_allowlist_hash" != "$last_allowlist_hash" ]; }; then
            write_access_rules "$current_mode"
            squid -k reconfigure 2>/dev/null || true
            last_mode="$current_mode"
        fi

        last_allowlist_hash="$current_allowlist_hash"
    done
}

watch_config &

echo "[proxy] Starting squid on port 3128..."
exec squid -N -f /etc/squid/squid.conf
