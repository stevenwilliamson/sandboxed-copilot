FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

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

# Ubuntu 24.04 ships with a built-in 'ubuntu' user at UID 1000.
# Rename it to 'copilot' and move the home directory.
# The explicit chown -R ensures all files inside the moved directory
# are owned by the new user (usermod -m only chowns the directory itself).
RUN usermod -l copilot -d /home/copilot -m ubuntu \
    && groupmod -n copilot ubuntu \
    && chown -R copilot:copilot /home/copilot

# Pre-create the gh extensions path and shell history dir so Docker volumes
# initialise with copilot:copilot ownership rather than root when first mounted.
# Also pre-create .gitconfig and .config/git/config as empty files so that
# when the launcher bind-mounts the host gitconfig files, Docker replaces the
# files rather than creating directories at those paths (Docker creates a
# directory if the target file doesn't exist at mount time).
RUN mkdir -p /home/copilot/.local/share/gh/extensions \
             /home/copilot/.shell_history \
             /home/copilot/.config/git \
    && touch /home/copilot/.gitconfig \
             /home/copilot/.config/git/config \
    && chown -R copilot:copilot /home/copilot/.local \
                                /home/copilot/.config \
    && chown copilot:copilot /home/copilot/.shell_history \
                             /home/copilot/.gitconfig

# Copy entrypoint (owned by root, executed by copilot)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER copilot

# Add mise shims and user local bin to PATH
ENV PATH="/home/copilot/.local/share/mise/shims:/home/copilot/.local/bin:${PATH}"

# Shell history persistence — the volume is mounted at this directory so history
# survives container restarts. HISTFILE is inherited by all child processes.
ENV HISTFILE=/home/copilot/.shell_history/.bash_history
ENV HISTSIZE=10000
ENV HISTFILESIZE=20000

# Pre-install latest Ruby, Python, and Node.js LTS via mise.
# Runs BEFORE the HTTP_PROXY env vars so downloads go directly to the internet
# during build (the proxy sidecar doesn't exist at build time).
RUN mise use --global ruby@latest python@latest node@lts \
    && mise install \
    && mise reshim

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
