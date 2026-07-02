# Ubuntu-based opencode server image.
#
# Runs `opencode serve` as the unprivileged `opencode` user (uid/gid 1000) on an
# Ubuntu base with a broad, familiar dev toolchain. All configuration is env-driven
# (OPENCODE_SERVER_PASSWORD, OPENCODE_CORS_ORIGIN, OPENCODE_PORT). The entire home
# directory (/home/opencode) is the persistent mount point; the active project
# lives under ~/workspace.
#
# Three-stage build:
#   base     — apt packages, user, sudo, init — shared by builder and final
#   builder  — fetches relocatable toolchains (opencode, Homebrew, mise)
#   final    — copies in runtimes from builder; carries only runtime layers

ARG OPENCODE_VERSION=0.0.0
ARG IMAGE_CREATED="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

# ---------------------------------------------------------------------------
# base: common runtime layer (apt, user, sudo, init)
# ---------------------------------------------------------------------------
FROM ubuntu:26.04 AS base

ENV DEBIAN_FRONTEND=noninteractive

# General dev toolchain: VCS, build tools, languages, CLI utilities.
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates curl git openssh-client unzip xz-utils \
  build-essential jq pkg-config \
  less sudo tini tzdata locales \
  && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb \
  && userdel --remove ubuntu 2>/dev/null || true; \
  groupdel ubuntu 2>/dev/null || true; \
  groupadd --gid 1000 opencode \
  && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash opencode \
  && echo 'opencode ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/opencode \
  && chmod 0440 /etc/sudoers.d/opencode \
  && visudo -cf /etc/sudoers.d/opencode

# Entrypoint (tini + init script)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# ---------------------------------------------------------------------------
# builder: fetch relocatable toolchains (layers are ephemeral —
# only what's explicitly COPIED to final lands in the runtime image).
# Order: most-stable first, so frequent version bumps don't bust the
# cache of the other toolchains.
# ---------------------------------------------------------------------------
FROM base AS builder

# 1. Homebrew — the install script URL is stable; brew releases rarely
#    invalidate the layer once installed.
RUN mkdir -p /home/linuxbrew \
  && chown opencode:opencode /home/linuxbrew \
  && sudo -u opencode NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
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
  && MISE_DATA_DIR=/opt/mise mise plugins install zerobrew https://github.com/kennyg/mise-zerobrew

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
FROM base

ARG OPENCODE_VERSION
ARG IMAGE_CREATED

ENV PATH=/home/opencode/.local/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/home/opencode/.local/share/zerobrew/prefix/bin:/opt/auto-install-shims:${PATH}
ENV HOMEBREW_NO_AUTO_UPDATE=1
ENV HOMEBREW_INSTALL_FROM_API=1
ENV MISE_DATA_DIR=/opt/mise
ENV MISE_ALWAYS_INSTALL=1

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

# Runtimes copied from builder (most-stable first so frequent version
# bumps don't invalidate cache for the other layers).
COPY --from=builder --chown=opencode:opencode /home/linuxbrew /home/linuxbrew
COPY --from=builder /opt/opencode /usr/local/bin/opencode

# Mise — dev tool manager; auto-installs tools defined in the global config.
COPY --from=builder /usr/local/bin/mise /usr/local/bin/mise
COPY --from=builder --chown=opencode:opencode /opt/mise /opt/mise
COPY mise-config.toml /etc/mise/config.toml

# Zerobrew — fast Homebrew alternative; mise zerobrew backend.
COPY --from=builder /home/opencode/.local/bin/zb /usr/local/bin/zb
COPY --from=builder /home/opencode/.local/bin/zbx /usr/local/bin/zbx
COPY --from=builder --chown=opencode:opencode /home/opencode/.local/share/zerobrew /home/opencode/.local/share/zerobrew

# Verify runtime and set up login-shell PATH and auto-install handler
RUN opencode --version \
  && printf 'for d in "$HOME/.local/bin" "/home/linuxbrew/.linuxbrew/bin" "/home/linuxbrew/.linuxbrew/sbin" "$HOME/.local/share/zerobrew/prefix/bin"; do case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH";; esac; done\nexport PATH\n' > /etc/profile.d/brew-path.sh \
  && chmod 0644 /etc/profile.d/brew-path.sh \
  && printf '\neval "$(mise activate bash)"\n' >> /home/opencode/.bashrc \
  && printf '\neval "$(mise activate zsh)"\n' >> /home/opencode/.zshrc \
  && mkdir -p /home/opencode/.config/fish \
  && printf '\nmise activate fish | source\n' >> /home/opencode/.config/fish/config.fish \
  && printf '\neval "$(mise activate sh)"\n' >> /home/opencode/.profile \
  && mkdir -p /opt/auto-install-shims \
  && grep -E '^\s*"' /etc/mise/config.toml | while IFS='=' read -r key value; do \
  key="$(echo "$key" | tr -d ' "')" \
  && shim="${key#*:}" \
  && printf '#!/usr/bin/env bash\nexec /usr/local/bin/mise exec "%s" -- %s "$@"\n' "$key" "$shim" > "/opt/auto-install-shims/$shim" \
  && chmod 0755 "/opt/auto-install-shims/$shim"; \
  done \
  && chown -R opencode:opencode /opt/auto-install-shims \
  && mkdir -p /home/opencode/workspace \
  && chown -R opencode:opencode /home/opencode

USER opencode
ENV HOME=/home/opencode
WORKDIR /home/opencode/workspace

EXPOSE 4096

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
