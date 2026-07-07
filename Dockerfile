# Ubuntu-based opencode server image.
#
# Runs `opencode serve` as the unprivileged `opencode` user (uid/gid 1000) on an
# Ubuntu base with a broad, familiar dev toolchain. All configuration is env-driven
# (OPENCODE_SERVER_PASSWORD, OPENCODE_CORS_ORIGIN, OPENCODE_PORT). The entire home
# directory (/home/opencode) is the persistent mount point; the active project
# lives under ~/workspace.
#
# Three-stage build:
#   runtime   — minimal apt packages, user, sudo, init
#   builder   — runtime + compiler toolchain + relocatable toolchains (opencode, Homebrew, mise)
#   final     — copies in runtimes from builder; carries only runtime layers

ARG OPENCODE_VERSION=0.0.0
ARG IMAGE_CREATED="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

# ---------------------------------------------------------------------------
# runtime: minimal runtime layer (apt, user, sudo, init)
# ---------------------------------------------------------------------------
FROM ubuntu:26.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive

# CLI utilities for day-to-day dev work (git, curl, etc.).
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates curl git openssh-client unzip \
  less libatomic1 sudo tini tzdata \
  && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb \
  && rm -rf /usr/share/doc /usr/share/man /usr/share/locale \
  && userdel --remove ubuntu 2>/dev/null || true; \
  groupdel ubuntu 2>/dev/null || true; \
  groupadd --gid 1000 opencode \
  && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash opencode \
  && echo 'opencode ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/opencode \
  && chmod 0440 /etc/sudoers.d/opencode \
  && visudo -cf /etc/sudoers.d/opencode \
  && find /var/log -type f -delete 2>/dev/null; \
  rm -f /var/cache/debconf/*.dat 2>/dev/null || true

# Entrypoint (tini + init script)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# ---------------------------------------------------------------------------
# builder: runtime + compiler toolchain + relocatable toolchains —
# only what's explicitly COPIED to final lands in the runtime image.
# Order: most-stable first, so frequent version bumps don't bust the
# cache of the other toolchains.
# ---------------------------------------------------------------------------
FROM runtime AS builder

# Compiler toolchain needed for building native extensions during
# toolchain installation (Homebrew bottles, mise plugins, etc.).
RUN apt-get update && apt-get install -y --no-install-recommends \
  build-essential pkg-config xz-utils \
  && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb

# 1. Homebrew — partial clone with --filter=blob:none avoids downloading
#    all past file versions, saving ~70 MB while keeping brew update working.
RUN mkdir -p /home/linuxbrew \
  && chown opencode:opencode /home/linuxbrew \
  && sudo -u opencode git clone --filter=blob:none \
    https://github.com/Homebrew/brew /home/linuxbrew/.linuxbrew/Homebrew \
  && sudo -u opencode mkdir -p /home/linuxbrew/.linuxbrew/bin \
  && sudo -u opencode ln -sf \
    /home/linuxbrew/.linuxbrew/Homebrew/bin/brew /home/linuxbrew/.linuxbrew/bin/brew \
  && sudo -u opencode /home/linuxbrew/.linuxbrew/bin/brew update --force \
  && sudo -u opencode /home/linuxbrew/.linuxbrew/bin/brew cleanup --prune=all \
  && sudo -u opencode rm -rf "$(sudo -u opencode /home/linuxbrew/.linuxbrew/bin/brew --cache)" \
  && rm -rf /home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/test \
  && rm -rf /home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/bundle/ruby/*/cache \
  && rm -rf /home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/bundle/ruby/*/doc \
  && rm -rf /home/linuxbrew/.linuxbrew/share/man \
  && rm -rf /home/linuxbrew/.linuxbrew/share/doc \
  && rm -rf /home/linuxbrew/.linuxbrew/share/zsh \
  && rm -rf /home/linuxbrew/.linuxbrew/Homebrew/Library/Taps/homebrew/homebrew-core

# 1.5. mise — dev tool manager; pre-approved tools defined in the global config
#     auto-install via zerobrew backend on first use at runtime.
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
  && mkdir -p /opt/mise \
  && MISE_DATA_DIR=/opt/mise mise plugins install zerobrew https://github.com/kennyg/mise-zerobrew \
  && sed -i '/quoted_path .. " install /i\    cmd.exec(quoted_zb .. " --root " .. quoted_path .. " init")' /opt/mise/plugins/zerobrew/hooks/backend_install.lua

# 1.6. zerobrew — fast Homebrew alternative; used as mise backend
RUN sudo -u opencode HOME=/home/opencode NONINTERACTIVE=1 /bin/bash -c " \
  curl -fsSL https://zerobrew.rs/install | bash -s -- --no-modify-path \
"

ARG OPENCODE_VERSION

# 2. opencode server binary — changes on every version bump (most frequent)
RUN curl -fsSL https://opencode.ai/install | VERSION="${OPENCODE_VERSION}" bash \
  && (cp /root/.opencode/bin/opencode /opt/opencode 2>/dev/null \
  || cp "$HOME/.opencode/bin/opencode" /opt/opencode) \
  && chmod 0755 /opt/opencode \
  && /opt/opencode --version

# ---------------------------------------------------------------------------
# final: runtime image — only the base layer plus copied-in toolchains
# ---------------------------------------------------------------------------
FROM runtime

ARG OPENCODE_VERSION
ARG IMAGE_CREATED

ENV PATH=/opt/mise/shims:/home/opencode/.local/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/home/opencode/.local/share/zerobrew/prefix/bin:/opt/auto-install-shims:${PATH}
ENV HOMEBREW_NO_AUTO_UPDATE=1
ENV HOMEBREW_INSTALL_FROM_API=1
ENV MISE_DATA_DIR=/opt/mise
ENV MISE_ALWAYS_INSTALL=1
ENV BASH_ENV=/etc/opencode-mise.bash

LABEL io.artifacthub.package.readme-url="https://raw.githubusercontent.com/sprisa/opencode-server/refs/heads/main/README.md" \
  org.opencontainers.image.created="${IMAGE_CREATED}" \
  org.opencontainers.image.description="Opencode server for general-purpose agent development. Supports web desktop & server mode." \
  org.opencontainers.image.documentation="https://github.com/sprisa/opencode-server" \
  org.opencontainers.image.source="https://github.com/sprisa/opencode-server" \
  org.opencontainers.image.title="opencode-server" \
  org.opencontainers.image.url="https://github.com/sprisa/opencode-server" \
  org.opencontainers.image.vendor="Sprisa Inc" \
  org.opencontainers.image.version="${OPENCODE_VERSION}" \
  io.artifacthub.package.license="MPL-2.0" \
  io.artifacthub.package.maintainers='[{"name":"Gabriel Meola","email":"banter@gabe.mx"}]' \
  io.artifacthub.package.keywords="opencode,server,docker,ai,code,editor,development"

# Copy layers
# Ordered by most stable layers first so cache can be reused.
COPY --from=builder --chown=opencode:opencode /home/linuxbrew /home/linuxbrew

# Zerobrew — fast Homebrew alternative; mise zerobrew backend.
COPY --from=builder /home/opencode/.local/bin/zb /usr/local/bin/zb
COPY --from=builder /home/opencode/.local/bin/zbx /usr/local/bin/zbx
COPY --from=builder --chown=opencode:opencode /home/opencode/.local/share/zerobrew /home/opencode/.local/share/zerobrew

# Mise — dev tool manager; auto-installs tools defined in the global config.
COPY --from=builder /usr/local/bin/mise /usr/local/bin/mise
COPY --from=builder --chown=opencode:opencode /opt/mise /opt/mise
COPY mise-config.toml /etc/mise/config.toml

# Opencode
COPY --from=builder /opt/opencode /usr/local/bin/opencode

# Verify runtime and set up login-shell PATH and auto-install handler
RUN opencode --version \
  && printf 'for d in "$HOME/.local/bin" "/home/linuxbrew/.linuxbrew/bin" "/home/linuxbrew/.linuxbrew/sbin" "$HOME/.local/share/zerobrew/prefix/bin"; do case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH";; esac; done\nexport PATH\n' > /etc/profile.d/brew-path.sh \
  && chmod 0644 /etc/profile.d/brew-path.sh \
  && printf '\n# Mise activation for interactive shells\nsource /etc/opencode-mise.bash\neval "$(mise activate bash)"\n' >> /home/opencode/.bashrc \
  && printf '\neval "$(mise activate zsh)"\n' >> /home/opencode/.zshrc \
  && mkdir -p /home/opencode/.config/fish \
  && printf '\nmise activate fish | source\n' >> /home/opencode/.config/fish/config.fish \
  && printf '\neval "$(mise activate sh)"\n' >> /home/opencode/.profile \
  && printf '#!/usr/bin/env bash\n# Route unknown commands through mise (fallback for non-interactive shells)\nif [ -n "${BASH_VERSION-}" ]; then\n  command_not_found_handle() {\n    if /usr/local/bin/mise which "$1" &>/dev/null; then\n      /usr/local/bin/mise exec "$1" -- "$@"\n      return $?\n    fi\n    return 127\n  }\nfi\n' > /etc/opencode-mise.bash \
  && chmod 0644 /etc/opencode-mise.bash \
  && mkdir -p /opt/auto-install-shims \
  && grep -E '^\s*"' /etc/mise/config.toml | while IFS='=' read -r key value; do \
  key="$(echo "$key" | tr -d ' "')" \
  && shim_list="$(echo "$value" | sed -n 's/.*# shim:\([^ ]*\).*/\1/p')" \
  && if [ -z "$shim_list" ]; then \
     case "$key" in \
       github:*) shim_list="${key##*/}" ;; \
       *) shim_list="${key#*:}" ;; \
     esac; \
     fi \
  && for shim in $(echo "$shim_list" | tr ',' ' '); do \
     printf '#!/usr/bin/env bash\nexec /usr/local/bin/mise exec "%s" -- %s "$@"\n' "$key" "$shim" > "/opt/auto-install-shims/$shim" \
     && chmod 0755 "/opt/auto-install-shims/$shim"; \
     done; \
  done \
  && chown -R opencode:opencode /opt/auto-install-shims \
  && mkdir -p /opt/mise/shims \
  && chown opencode:opencode /opt/mise/shims \
  && mkdir -p /home/opencode/workspace \
  && chown -R opencode:opencode /home/opencode

USER opencode
ENV HOME=/home/opencode
WORKDIR /home/opencode/workspace

EXPOSE 4096

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
