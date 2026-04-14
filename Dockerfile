FROM ubuntu:24.04

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

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    ca-certificates \
    gnupg \
    jq \
    unzip \
    wget \
    build-essential \
    libssl-dev \
    libyaml-dev \
    zlib1g-dev \
    libffi-dev \
    libgdbm-dev \
    libreadline-dev \
    ruby-full \
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

# Pre-install Python and Node.js LTS via mise (both use pre-built binaries — fast).
# Ruby is installed via apt above; users can run `mise use ruby@<version>` at
# runtime to switch to a different version without rebuilding the image.
# Runs BEFORE the HTTP_PROXY env vars so downloads go directly to the internet
# during build (the proxy sidecar doesn't exist at build time).
RUN mise use --global python@latest node@lts \
    && mise install \
    && mise reshim

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

# Route all traffic through the proxy sidecar
ENV HTTP_PROXY=http://proxy:3128
ENV HTTPS_PROXY=http://proxy:3128
ENV http_proxy=http://proxy:3128
ENV https_proxy=http://proxy:3128
ENV NO_PROXY=localhost,127.0.0.1
ENV no_proxy=localhost,127.0.0.1

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
