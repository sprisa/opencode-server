# Ubuntu-based opencode server image.
#
# Runs `opencode serve` as the unprivileged `opencode` user (uid/gid 1000) on an
# Ubuntu base with a broad, familiar dev toolchain. All configuration is env-driven
# (OPENCODE_SERVER_PASSWORD, OPENCODE_CORS_ORIGIN, OPENCODE_PORT). The entire home
# directory (/home/opencode) is the persistent mount point; the active project
# lives under ~/workspace. Node lives in /opt/n (outside home) so it's never
# shadowed when a volume mounts over the home directory.
#
# Three-stage build:
#   base     — apt packages, user, sudo, init — shared by builder and final
#   builder  — fetches relocatable toolchains (Node, opencode, Homebrew)
#   final    — copies in runtimes from builder; carries only runtime layers

ARG OPENCODE_VERSION=0.0.0
ARG NODE_PREFIX=/opt/n

# ---------------------------------------------------------------------------
# base: common runtime layer (apt, user, sudo, init)
# ---------------------------------------------------------------------------
FROM ubuntu:26.04 AS base

ENV DEBIAN_FRONTEND=noninteractive

# General dev toolchain: VCS, build tools, languages, CLI utilities.
# Also installs GitHub CLI via its official apt repo.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git openssh-client unzip xz-utils \
      build-essential pkg-config \
      python3 python3-pip python3-venv ruby \
      ripgrep fd-find jq less nano vim-tiny \
      sudo tini open-iscsi tzdata locales \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/* \
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
# builder: fetch Node, opencode, and Homebrew (layers are ephemeral —
# only what's explicitly COPIED to final lands in the runtime image)
# ---------------------------------------------------------------------------
FROM base AS builder

ARG NODE_PREFIX
ENV N_PREFIX=${NODE_PREFIX}
ENV PATH=${NODE_PREFIX}/bin:${PATH}

# Node.js via `n` (version manager)
RUN curl -fsSL -o /usr/local/bin/n https://raw.githubusercontent.com/tj/n/master/bin/n \
  && chmod 0755 /usr/local/bin/n \
  && mkdir -p "${N_PREFIX}" \
  && n install --cleanup current \
  && node --version && npm --version

ARG OPENCODE_VERSION

# opencode server binary
RUN curl -fsSL https://opencode.ai/install | VERSION="${OPENCODE_VERSION}" bash \
  && (cp /root/.opencode/bin/opencode /opt/opencode 2>/dev/null \
      || cp "$HOME/.opencode/bin/opencode" /opt/opencode) \
  && chmod 0755 /opt/opencode \
  && /opt/opencode --version

# Homebrew package manager — install and strip unnecessary data
RUN mkdir -p /home/linuxbrew \
  && chown opencode:opencode /home/linuxbrew \
  && sudo -u opencode NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
  && sudo -u opencode /home/linuxbrew/.linuxbrew/bin/brew cleanup --prune=all \
  && sudo -u opencode rm -rf "$(sudo -u opencode /home/linuxbrew/.linuxbrew/bin/brew --cache)" \
  && rm -rf /home/linuxbrew/.linuxbrew/Homebrew/Library/Taps/homebrew/homebrew-core \
  && rm -rf /home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/test \
  && rm -rf /home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/cask \
  && rm -rf /home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/bundle/ruby/*/cache \
  && rm -rf /home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/bundle/ruby/*/doc \
  && rm -rf /home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/portable-ruby \
  && rm -rf /home/linuxbrew/.linuxbrew/share/man \
  && rm -rf /home/linuxbrew/.linuxbrew/share/doc \
  && rm -rf /home/linuxbrew/.linuxbrew/share/zsh

# ---------------------------------------------------------------------------
# final: runtime image — only the base layer plus copied-in toolchains
# ---------------------------------------------------------------------------
FROM base

ARG NODE_PREFIX
ENV N_PREFIX=${NODE_PREFIX}
ENV PATH=${N_PREFIX}/bin:/home/opencode/.local/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:${PATH}

# Runtimes copied from builder (no installer residue)
COPY --from=builder --chown=opencode:opencode ${NODE_PREFIX} ${NODE_PREFIX}
COPY --from=builder /opt/opencode /usr/local/bin/opencode
COPY --from=builder --chown=opencode:opencode /home/linuxbrew /home/linuxbrew

# Verify runtimes and set up login-shell PATH
RUN node --version && npm --version && opencode --version \
  && printf 'export N_PREFIX=%s\nfor d in "$N_PREFIX/bin" "$HOME/.local/bin" "/home/linuxbrew/.linuxbrew/bin" "/home/linuxbrew/.linuxbrew/sbin"; do case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH";; esac; done\nexport PATH\n' "${N_PREFIX}" > /etc/profile.d/node-path.sh \
  && chmod 0644 /etc/profile.d/node-path.sh

USER opencode
ENV HOME=/home/opencode
WORKDIR /home/opencode/workspace

EXPOSE 4096

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
