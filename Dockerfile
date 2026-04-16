# =============================================================================
# Stage: base
# Common foundation shared by all variants. Contains gh CLI, mise, the copilot
# CLI binary, entrypoint.sh, proxy env vars, and telemetry opt-outs.
# No language runtimes — those are added by the standard and full stages.
#
# IMPORTANT: All RUN commands that need internet access must come BEFORE the
# ENV HTTP_PROXY directives. The proxy sidecar does not exist at build time;
# setting HTTP_PROXY before downloads would cause them to fail.
# =============================================================================
FROM ubuntu:24.04 AS base

ENV DEBIAN_FRONTEND=noninteractive

# Disable apt's internal privilege dropping. apt normally drops to the _apt
# user (UID 42) for downloads, which requires CAP_SETUID/CAP_SETGID. Since
# the container runs as root with cap_drop: ALL those caps are unavailable.
# Apt sandboxing is designed to protect a root system from a compromised
# download process — in our container the whole boundary is Docker, not user
# separation, so this is the correct configuration.
# Also fix ownership of apt's partial directories: the Ubuntu base image
# creates them owned by _apt, but root with cap_drop:ALL has no CAP_DAC_OVERRIDE
# so it cannot write there without owning the directory.
RUN printf 'APT::Sandbox::User "root";\n' > /etc/apt/apt.conf.d/99no-sandbox \
    && chown root:root /var/cache/apt/archives/partial

# Install system packages. Ruby and its build dependencies are NOT included
# here — they are added in the standard stage. build-essential is included
# because agents frequently compile native extensions (node-gyp, C Python
# extensions, etc.) regardless of which language runtime is pre-installed.
RUN apt-get update && apt-get install -y \
    curl \
    git \
    ca-certificates \
    gnupg \
    jq \
    unzip \
    wget \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install gh CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install mise to system path so all users have access
RUN curl https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

# The container runs as root — cap_drop: ALL provides the real containment.
# In a single-user container, a separate Unix user adds no meaningful boundary:
# the agent can write and execute arbitrary software regardless of UID. Setting
# HOME=/home/copilot keeps all tool paths (mise, gh, copilot-cli) in a
# well-known directory without needing a separate user account.
ENV HOME=/home/copilot

# Pre-create the home directories needed by tools and volume mounts.
# Also pre-create .gitconfig and .config/git/config as empty files so that
# when the launcher bind-mounts the host gitconfig files, Docker replaces the
# files rather than creating directories at those paths (Docker creates a
# directory if the target file doesn't exist at mount time).
RUN mkdir -p /home/copilot/.local/share/gh \
             /home/copilot/.shell_history \
             /home/copilot/.config/git \
    && touch /home/copilot/.gitconfig \
             /home/copilot/.config/git/config

# Copy entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Add mise shims and user local bin to PATH
ENV PATH="/home/copilot/.local/share/mise/shims:/home/copilot/.local/bin:${PATH}"

# Shell history persistence — the volume is mounted at this directory so history
# survives container restarts. HISTFILE is inherited by all child processes.
ENV HISTFILE=/home/copilot/.shell_history/.bash_history
ENV HISTSIZE=10000
ENV HISTFILESIZE=20000

# Pre-install the Copilot CLI binary at image build time so `gh copilot` works
# immediately without a runtime download. `gh copilot` (built-in) looks for a
# binary named `copilot` in gh's data dir (~/.local/share/gh/copilot/copilot)
# before prompting for installation. Baking it into an immutable image layer
# eliminates both the shared-volume write path (Critical #1) and unauthenticated
# runtime downloads.
#
# SHA-256 is verified against the official SHA256SUMS.txt published alongside
# every copilot-cli release, properly addressing binary integrity (Critical #2).
#
# Runs before HTTP_PROXY/HTTPS_PROXY env vars so the build context reaches
# GitHub directly (the proxy sidecar does not exist at build time).
RUN set -eu; \
    case "$(uname -m)" in \
        x86_64)  arch="x64"   ;; \
        aarch64) arch="arm64" ;; \
        *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/github/copilot-cli/releases/latest/download"; \
    archive="copilot-linux-${arch}.tar.gz"; \
    install_dir="/home/copilot/.local/share/gh/copilot"; \
    mkdir -p "$install_dir"; \
    curl -fsSL --max-time 30 "${base}/SHA256SUMS.txt" -o /tmp/copilot-sums.txt; \
    curl -fsSL --max-time 120 "${base}/${archive}" -o "/tmp/${archive}"; \
    expected=$(awk -v f="$archive" '$2==f{print $1}' /tmp/copilot-sums.txt); \
    actual=$(sha256sum "/tmp/${archive}" | awk '{print $1}'); \
    [ "$expected" = "$actual" ] || { echo "Checksum mismatch for ${archive}: expected ${expected}, got ${actual}" >&2; exit 1; }; \
    tar -xzf "/tmp/${archive}" -C "$install_dir" --no-same-owner; \
    chmod +x "${install_dir}/copilot"; \
    test -x "${install_dir}/copilot"; \
    rm -f "/tmp/${archive}" /tmp/copilot-sums.txt; \
    mkdir -p /home/copilot/.config/gh \
    && printf 'git_protocol: https\n' > /home/copilot/.config/gh/config.yml

# Route all traffic through the proxy sidecar.
# Set LAST so all build-time downloads above go directly to the internet
# (the proxy sidecar does not exist at build time).
ENV HTTP_PROXY=http://proxy:3128
ENV HTTPS_PROXY=http://proxy:3128
ENV http_proxy=http://proxy:3128
ENV https_proxy=http://proxy:3128
ENV NO_PROXY=localhost,127.0.0.1
ENV no_proxy=localhost,127.0.0.1

# Telemetry opt-out — disable usage reporting for GitHub Copilot CLI / gh CLI
# and any other tooling that honours the consoledonottrack.com standard.
# These are baked into the image so they apply in all run modes and cannot be
# accidentally omitted by a caller.
#   GITHUB_NO_TELEMETRY — official GitHub CLI / Copilot CLI opt-out
#   DO_NOT_TRACK        — universal standard respected by Netlify CLI, Homebrew
#                         analytics, Gatsby, Angular CLI, Nuxt, Parcel, etc.
ENV GITHUB_NO_TELEMETRY=1
ENV DO_NOT_TRACK=1

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]

# =============================================================================
# Stage: minimal
# Base + SANDBOX_VARIANT marker. No pre-installed language runtimes.
# mise is available so users (or agents) can run `mise use python@latest` etc.
# at runtime to install runtimes on demand.
# =============================================================================
FROM base AS minimal

ENV SANDBOX_VARIANT=minimal

# =============================================================================
# Stage: standard  (default)
# Adds Ruby (via apt), Python and Node.js LTS (via mise), and upgrades npm to
# v11.10.0+ for native package cooldown support. This matches the behaviour of
# the previous single-stage image.
#
# ARG declarations clear the inherited HTTP_PROXY env vars for build-time
# downloads. The proxy sidecar does not exist at build time and these ARGs
# override the inherited ENV values during RUN commands only; the final image
# layers still contain the runtime proxy configuration from the base stage.
# =============================================================================
FROM minimal AS standard

# Clear proxy env vars for build-time downloads (proxy doesn't exist at build time).
# ARG values override inherited ENV values with the same name during RUN commands.
ARG HTTP_PROXY=""
ARG HTTPS_PROXY=""
ARG http_proxy=""
ARG https_proxy=""

# Install Ruby via apt (fast — no compilation). Build dependencies are included
# so agents can `gem install` native extensions. Users who need a different Ruby
# version can run `mise use ruby@<version>` at runtime.
RUN apt-get update && apt-get install -y \
    libssl-dev \
    libyaml-dev \
    zlib1g-dev \
    libffi-dev \
    libgdbm-dev \
    libreadline-dev \
    ruby-full \
    && rm -rf /var/lib/apt/lists/*

# Pre-install Python and Node.js LTS via mise (both use pre-built binaries — fast).
RUN mise use --global python@latest node@lts \
    && mise install \
    && mise reshim

# Upgrade npm to v11.10.0+ which adds native `min-release-age` support for
# supply chain attack mitigation. Node 22 LTS ships with npm ~v10.x which
# predates this feature.
RUN npm install -g npm@latest

ENV SANDBOX_VARIANT=standard

# =============================================================================
# Stage: full
# Adds a browser for headless automation. On amd64, Google Chrome stable is
# installed from Google's APT repository. On arm64, Chromium is installed from
# the Debian bookworm repository (Google Chrome is not published for arm64, and
# Ubuntu 24.04's Chromium deb is a snap wrapper that doesn't work in containers).
# A symlink at /usr/bin/google-chrome ensures consistent paths on both archs.
# Puppeteer is pre-configured via env vars to use the system browser.
#
# Required flags at runtime: --no-sandbox --disable-dev-shm-usage
# (user namespace sandboxing is unavailable with cap_drop: ALL)
# =============================================================================
FROM standard AS full

# Clear proxy env vars for build-time downloads (same reason as standard stage).
ARG HTTP_PROXY=""
ARG HTTPS_PROXY=""
ARG http_proxy=""
ARG https_proxy=""

# Install a browser for headless automation.
# Google Chrome is only published for amd64. On arm64, Chromium is installed
# from the Debian bookworm repository — Ubuntu 24.04 replaced its Chromium deb
# with a snap transitional package that does not work inside containers.
# A symlink at /usr/bin/google-chrome ensures PUPPETEER_EXECUTABLE_PATH works
# on both architectures.
RUN arch="$(dpkg --print-architecture)" \
    && if [ "$arch" = "amd64" ]; then \
        curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
            | gpg --dearmor -o /usr/share/keyrings/google-chrome-archive-keyring.gpg \
        && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-archive-keyring.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
            | tee /etc/apt/sources.list.d/google-chrome.list > /dev/null \
        && apt-get update \
        && apt-get install -y google-chrome-stable; \
    elif [ "$arch" = "arm64" ]; then \
        { curl -fsSL https://ftp-master.debian.org/keys/archive-key-12.asc; \
          curl -fsSL https://ftp-master.debian.org/keys/archive-key-12-security.asc; } \
            | gpg --dearmor -o /usr/share/keyrings/debian-bookworm.gpg \
        && printf 'deb [arch=arm64 signed-by=/usr/share/keyrings/debian-bookworm.gpg] https://deb.debian.org/debian bookworm main\ndeb [arch=arm64 signed-by=/usr/share/keyrings/debian-bookworm.gpg] https://deb.debian.org/debian-security bookworm-security main\n' \
            > /etc/apt/sources.list.d/debian-chromium.list \
        && printf 'Package: *\nPin: release o=Debian\nPin-Priority: 100\n\nPackage: chromium*\nPin: release o=Debian\nPin-Priority: 500\n' \
            > /etc/apt/preferences.d/chromium-from-debian \
        && apt-get update \
        && apt-get install -y --no-install-recommends chromium \
        && ln -sf /usr/bin/chromium /usr/bin/google-chrome; \
    else \
        echo "Unsupported architecture for browser installation: $arch" >&2; exit 1; \
    fi \
    && rm -rf /var/lib/apt/lists/* \
    && google-chrome --version

ENV SANDBOX_VARIANT=full

# Puppeteer zero-config: use the system browser instead of downloading its own.
# /usr/bin/google-chrome exists on both archs (symlink to chromium on arm64).
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome
ENV PUPPETEER_SKIP_DOWNLOAD=true
