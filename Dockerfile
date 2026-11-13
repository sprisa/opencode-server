# Ubuntu-based opencode server image.
#
# Runs `opencode serve` as the unprivileged `opencode` user (uid/gid 1000) on an
# Ubuntu base with a broad, familiar dev toolchain. All configuration is env-driven
# (OPENCODE_PASSWORD / OPENCODE_SERVER_PASSWORD, OPENCODE_CORS_ORIGIN, OPENCODE_PORT). The entire home
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
# Pin the last known-good Ubuntu 26.04 multi-arch image. The 2026-07-16
# refresh breaks portable-ruby extraction during emulated amd64 builds with
# spurious ENOSYS ("Function not implemented") errors from tar.
# Related: https://github.com/orbstack/orbstack/issues/2588
FROM ubuntu:26.04@sha256:b7f48194d4d8b763a478a621cdc81c27be222ba2206ca3ca6bc42b49685f3d9e AS runtime

ENV DEBIAN_FRONTEND=noninteractive

# CLI utilities for day-to-day dev work (git, curl, etc.).
# Publishing reuses cached layers, so this apt layer and everything built on it
# stay byte-identical between releases and nodes only download what changed.
# The Taskfile sets APT_REFRESH to the current month (YYYY-MM), so published
# images still pick up Ubuntu security updates once a month.
ARG APT_REFRESH=manual
RUN echo "apt refresh: ${APT_REFRESH}" \
  && apt-get update && apt-get install -y --no-install-recommends \
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

# 1. Homebrew — shallow clone of the pinned release tag. Homebrew needs its
#    .git directory, but not the project history. Cloning a tag leaves no
#    origin/main, which makes the first `brew update` print "Not a valid ref",
#    so also fetch main's tip (~2 MB) with the normal refspec.
#    `brew cleanup` downloads Homebrew's portable Ruby (45 MB); drop it so brew
#    fetches it on its first Ruby-backed command instead (~4s), like a fresh
#    Homebrew install does.
ARG HOMEBREW_VERSION=7.0.11
RUN mkdir -p /home/linuxbrew \
  && chown opencode:opencode /home/linuxbrew \
  && sudo -u opencode git clone --depth 1 \
    --branch "${HOMEBREW_VERSION}" \
    https://github.com/Homebrew/brew /home/linuxbrew/.linuxbrew/Homebrew \
  && sudo -u opencode git -C /home/linuxbrew/.linuxbrew/Homebrew \
    config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*' \
  && sudo -u opencode git -C /home/linuxbrew/.linuxbrew/Homebrew \
    fetch --quiet --depth 1 origin main \
  && sudo -u opencode git -C /home/linuxbrew/.linuxbrew/Homebrew \
    checkout --quiet -B stable "${HOMEBREW_VERSION}" \
  && sudo -u opencode mkdir -p /home/linuxbrew/.linuxbrew/bin \
  && sudo -u opencode ln -sf \
    /home/linuxbrew/.linuxbrew/Homebrew/bin/brew /home/linuxbrew/.linuxbrew/bin/brew \
  && sudo -u opencode /home/linuxbrew/.linuxbrew/bin/brew cleanup --prune=all \
  && sudo -u opencode rm -rf "$(sudo -u opencode /home/linuxbrew/.linuxbrew/bin/brew --cache)" \
  && rm -rf /home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/portable-ruby \
  && rm -rf /home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/test \
  && rm -rf /home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/bundle/ruby/*/cache \
  && rm -rf /home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/bundle/ruby/*/doc \
  && rm -rf /home/linuxbrew/.linuxbrew/share/man \
  && rm -rf /home/linuxbrew/.linuxbrew/share/doc \
  && rm -rf /home/linuxbrew/.linuxbrew/share/zsh \
  && rm -rf /home/linuxbrew/.linuxbrew/Homebrew/Library/Taps/homebrew/homebrew-core

ARG MISE_VERSION=2026.10.24
ARG MISE_ZEROBREW_PLUGIN_COMMIT=998174989a12910f82c1f6e791a432731ed2647d

# 1.5. mise — dev tool manager; pre-approved tools defined in the global config
#     auto-install on first use at runtime. The release is
#     pinned so Docker caching cannot silently retain an old moving target.
RUN curl -fsSL https://mise.run | MISE_VERSION="${MISE_VERSION}" MISE_INSTALL_PATH=/usr/local/bin/mise sh \
  && mkdir -p /opt/mise \
  && MISE_DATA_DIR=/opt/mise mise plugins install zerobrew "https://github.com/kennyg/mise-zerobrew#${MISE_ZEROBREW_PLUGIN_COMMIT}" \
  && sed -i '/quoted_path .. " install /i\    cmd.exec(quoted_zb .. " --root " .. quoted_path .. " init")' /opt/mise/plugins/zerobrew/hooks/backend_install.lua

# 1.6. zerobrew — fast Homebrew alternative; used as mise backend
ARG ZEROBREW_VERSION=0.4.2
RUN set -eux; \
  case "$(uname -m)" in \
    x86_64) ZEROBREW_ARCH=x64 ;; \
    aarch64) ZEROBREW_ARCH=arm64 ;; \
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
  esac; \
  base_url="https://github.com/zerobrewhq/zerobrew/releases/download/v${ZEROBREW_VERSION}"; \
  download_dir="$(mktemp -d)"; \
  trap 'rm -rf "$download_dir"' 0; \
  curl -fsSL "${base_url}/SHA256SUMS" -o "${download_dir}/SHA256SUMS"; \
  curl -fsSL "${base_url}/zb-linux-${ZEROBREW_ARCH}" -o "${download_dir}/zb-linux-${ZEROBREW_ARCH}"; \
  curl -fsSL "${base_url}/zbx-linux-${ZEROBREW_ARCH}" -o "${download_dir}/zbx-linux-${ZEROBREW_ARCH}"; \
  (cd "$download_dir" && sha256sum -c --ignore-missing SHA256SUMS); \
  install -Dm755 "${download_dir}/zb-linux-${ZEROBREW_ARCH}" /home/opencode/.local/bin/zb; \
  install -Dm755 "${download_dir}/zbx-linux-${ZEROBREW_ARCH}" /home/opencode/.local/bin/zbx; \
  mkdir -p /home/opencode/.local/share/zerobrew; \
  chown -R opencode:opencode /home/opencode/.local; \
  sudo -u opencode HOME=/home/opencode XDG_DATA_HOME=/home/opencode/.local/share \
    /home/opencode/.local/bin/zb init --no-modify-path

ARG OPENCODE_VERSION

# 2. opencode server binary — changes on every version bump (most frequent)
# Upstream splits installers by major: opencode.ai/install only accepts v1
# releases and opencode.ai/v2/install only accepts v2 releases. Both install
# to ~/.opencode/bin/opencode and honor $VERSION.
RUN major="$(printf '%s' "${OPENCODE_VERSION}" | cut -d. -f1)" \
  && case "$major" in 1) installer="https://opencode.ai/install" ;; *) installer="https://opencode.ai/v2/install" ;; esac \
  && curl -fsSL "$installer" | VERSION="${OPENCODE_VERSION}" bash \
  && (cp /root/.opencode/bin/opencode /opt/opencode 2>/dev/null \
  || cp "$HOME/.opencode/bin/opencode" /opt/opencode) \
  && chmod 0755 /opt/opencode \
  && /opt/opencode --version

# ---------------------------------------------------------------------------
# final: runtime image — only the base layer plus copied-in toolchains
# ---------------------------------------------------------------------------
FROM runtime

ARG OPENCODE_VERSION

# mise/auto-install shims go LAST: they are "tool not installed" fallbacks that
# exec `mise exec <tool>`, so anything explicitly installed into a real bin dir
# (~/.local/bin, Homebrew, zerobrew, or /usr/local/bin via the base ${PATH})
# MUST win over the shim.
ENV PATH=/home/opencode/.local/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/home/opencode/.local/share/zerobrew/prefix/bin:${PATH}:/opt/mise/shims:/opt/auto-install-shims
ENV HOMEBREW_NO_AUTO_UPDATE=1
ENV HOMEBREW_INSTALL_FROM_API=1
ENV MISE_DATA_DIR=/opt/mise
ENV MISE_ALWAYS_INSTALL=1
ENV OPENCODE_INSTALL_HOME_TOOLS=false
ENV OPENCODE_PORT=4096
ENV OPENCODE_PRINT_LOGS=false
# Do not set a default password ENV: v2 generates one when both password names
# are absent, and OPENCODE_PASSWORD takes precedence over the legacy name.

# Copy layers
# Ordered by most stable layers first so cache can be reused. The opencode
# binary changes every release; small files that change independently (mise
# config, entrypoints) come after it so editing them doesn't rebuild it.
COPY --from=builder --chown=opencode:opencode /home/linuxbrew /home/linuxbrew

# Zerobrew — fast Homebrew alternative; mise zerobrew backend.
COPY --from=builder /home/opencode/.local/bin/zb /usr/local/bin/zb
COPY --from=builder /home/opencode/.local/bin/zbx /usr/local/bin/zbx
COPY --from=builder --chown=opencode:opencode /home/opencode/.local/share/zerobrew /home/opencode/.local/share/zerobrew

# Mise — dev tool manager; auto-installs tools defined in the global config.
COPY --from=builder /usr/local/bin/mise /usr/local/bin/mise
COPY --from=builder --chown=opencode:opencode /opt/mise /opt/mise

# Opencode
COPY --from=builder /opt/opencode /usr/local/bin/opencode

COPY mise-config.toml /etc/mise/config.toml
COPY mise-instructions.md /etc/opencode/mise-instructions.md

# Select the major-specific entrypoint at build time. Keep these late so startup
# script changes reuse the toolchain layers.
COPY entrypoint.sh entrypoint-v1.sh scripts/init-home.sh /usr/local/lib/opencode/
RUN case "${OPENCODE_VERSION}" in \
      1.*) entrypoint=entrypoint-v1.sh ;; \
      2.*) entrypoint=entrypoint.sh ;; \
      *) echo "unsupported opencode version: ${OPENCODE_VERSION}" >&2; exit 1 ;; \
    esac \
  && install -m 0755 "/usr/local/lib/opencode/${entrypoint}" /usr/local/bin/entrypoint.sh

# Lock each "latest" tool in the system config to the release that is newest at
# build time. First runs then download straight from the locked URL instead of
# fetching release lists (codex's is ~10 MB, past mise's 3s timeout) or calling
# the rate-limited GitHub API. Tools users add still resolve at runtime.
# OPENCODE_VERSION is referenced so every opencode release re-locks rather than
# reusing a cached layer. mise writes a temp file beside the lockfile whenever
# it checks it, so the opencode user must own /etc/mise.
RUN echo "locking mise tools for opencode ${OPENCODE_VERSION}" \
  && cd / \
  && MISE_LOCKFILE=1 MISE_FETCH_REMOTE_VERSIONS_TIMEOUT=60s \
    MISE_CACHE_DIR=/tmp/mise-lock-cache MISE_STATE_DIR=/tmp/mise-lock-state \
    mise lock -g --platform linux-x64,linux-arm64 \
  && rm -rf /tmp/mise-lock-cache /tmp/mise-lock-state \
  && chmod 0644 /etc/mise/mise.lock \
  && chown opencode:opencode /etc/mise /etc/mise/mise.lock \
  && chown -R opencode:opencode /opt/mise

# Verify runtime and set up login-shell PATH and auto-install handler.
# The version check leaves Bun's extracted native library (~7 MB) in /tmp and
# opencode logs under /root; Bun re-extracts at runtime, so drop both.
# Only chown the home files this step creates: chown -R over the whole home
# would copy the zerobrew files from the layer above into this one.
RUN opencode --version \
  && rm -rf /tmp/.bun-* /tmp/opencode /root/.local/share/opencode /root/.local/state/opencode \
  && install -m 0644 /dev/null /etc/mise/empty.toml \
  && mkdir -p /etc/opencode \
  && printf '%s\n' '{"$schema":"https://opencode.ai/config.json","instructions":["/etc/opencode/mise-instructions.md"]}' > /etc/opencode/opencode.json \
  && printf 'for d in "$HOME/.local/bin" "/home/linuxbrew/.linuxbrew/bin" "/home/linuxbrew/.linuxbrew/sbin" "$HOME/.local/share/zerobrew/prefix/bin"; do case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH";; esac; done\nexport PATH\n' > /etc/profile.d/brew-path.sh \
  && chmod 0644 /etc/profile.d/brew-path.sh \
  && printf '\neval "$(mise activate bash)"\n' >> /home/opencode/.bashrc \
  && printf '\neval "$(mise activate zsh)"\n' >> /home/opencode/.zshrc \
  && mkdir -p /home/opencode/.config/fish \
  && printf '\nmise activate fish | source\n' >> /home/opencode/.config/fish/config.fish \
  && printf '\nif [ -n "${BASH_VERSION:-}" ]; then eval "$(mise activate bash)"; fi\n' >> /home/opencode/.profile \
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
  && chown -R opencode:opencode /home/opencode/.zshrc /home/opencode/.config /home/opencode/workspace

USER opencode
ENV HOME=/home/opencode
WORKDIR /home/opencode/workspace

EXPOSE 4096

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

# Labels go last: IMAGE_CREATED changes on every build, and declaring it
# earlier puts it in the cache key of every later RUN, so none could be reused.
ARG IMAGE_CREATED
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
