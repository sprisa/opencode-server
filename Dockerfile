# Ubuntu-based opencode server image.
#
# Runs `opencode serve` as the unprivileged `opencode` user (uid/gid 1000) on an
# Ubuntu base with a broad, familiar dev toolchain. All configuration is env-driven
# (OPENCODE_SERVER_PASSWORD, OPENCODE_CORS_ORIGIN, OPENCODE_PORT). The entire home
# directory (/home/opencode) is the persistent mount point; the active project
# lives under ~/workspace. Node lives in /opt/n (outside home) so it's never
# shadowed when a volume mounts over the home directory.
#
# Multi-stage: the `builder` stage fetches relocatable toolchains (Node via `n`,
# the opencode binary) so installers and caches never land in the final image.
# The final stage carries only the runtime: apt dev packages + copied-in Node + opencode.

ARG OPENCODE_VERSION=0.0.0
# Node lives OUTSIDE /home/opencode so it's never shadowed by a volume mount
# over the entire home directory. /opt/n stays on the ephemeral image rootfs.
ARG NODE_PREFIX=/opt/n

# ---------------------------------------------------------------------------
# builder: fetch Node (via n) + the opencode binary
# ---------------------------------------------------------------------------
FROM ubuntu:26.04 AS builder
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils bash libatomic1 \
  && rm -rf /var/lib/apt/lists/*

ARG NODE_PREFIX
ENV N_PREFIX=${NODE_PREFIX}
ENV PATH=${NODE_PREFIX}/bin:${PATH}
RUN curl -fsSL -o /usr/local/bin/n https://raw.githubusercontent.com/tj/n/master/bin/n \
  && chmod 0755 /usr/local/bin/n \
  && mkdir -p "${N_PREFIX}" \
  && n install --cleanup current \
  && node --version && npm --version

ARG OPENCODE_VERSION
RUN curl -fsSL https://opencode.ai/install | VERSION="${OPENCODE_VERSION}" bash \
  && (cp /root/.opencode/bin/opencode /opt/opencode 2>/dev/null \
      || cp "$HOME/.opencode/bin/opencode" /opt/opencode) \
  && chmod 0755 /opt/opencode \
  && /opt/opencode --version

# ---------------------------------------------------------------------------
# final: the sandbox runtime
# ---------------------------------------------------------------------------
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# General-purpose toolchain: VCS, build tools, common languages + CLI utilities.
# `sudo` lets the sandbox user install system packages at runtime.
# `build-essential`/`pkg-config` support native npm addons and pip source builds.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git openssh-client unzip xz-utils \
      build-essential pkg-config \
      python3 python3-pip python3-venv \
      ripgrep fd-find jq less nano vim-tiny \
      sudo \
      tini \
      open-iscsi \
      tzdata locales \
  && rm -rf /var/lib/apt/lists/*

# Unprivileged runtime user; uid/gid 1000.
RUN userdel --remove ubuntu 2>/dev/null || true; \
    groupdel ubuntu 2>/dev/null || true; \
    groupadd --gid 1000 opencode \
  && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash opencode

# Passwordless sudo. The root filesystem is ephemeral — apt-installed packages
# are lost on container restart; only /home/opencode (the persistent mount) keeps data.
RUN echo 'opencode ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/opencode \
  && chmod 0440 /etc/sudoers.d/opencode \
  && visudo -cf /etc/sudoers.d/opencode

# Homebrew package manager for Linux — installed system-wide, not under the
# persistent home volume, so it survives container restarts.
RUN NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
  && chown -R opencode:opencode /home/linuxbrew

# `n` CLI for runtime Node version switches.
RUN curl -fsSL -o /usr/local/bin/n https://raw.githubusercontent.com/tj/n/master/bin/n \
  && chmod 0755 /usr/local/bin/n
ARG NODE_PREFIX
ENV N_PREFIX=${NODE_PREFIX}
ENV PATH=${N_PREFIX}/bin:/home/opencode/.local/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:${PATH}

# Toolchains from builder (no installer residue).
COPY --from=builder --chown=opencode:opencode ${NODE_PREFIX} ${NODE_PREFIX}
COPY --from=builder /opt/opencode /usr/local/bin/opencode
RUN node --version && npm --version && opencode --version

# Ensure login shells pick up NODE_PREFIX on PATH.
RUN printf 'export N_PREFIX=%s\nfor d in "$N_PREFIX/bin" "$HOME/.local/bin" "/home/linuxbrew/.linuxbrew/bin" "/home/linuxbrew/.linuxbrew/sbin"; do case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH";; esac; done\nexport PATH\n' "${N_PREFIX}" > /etc/profile.d/node-path.sh \
  && chmod 0644 /etc/profile.d/node-path.sh

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER opencode
ENV HOME=/home/opencode
WORKDIR /home/opencode/workspace

EXPOSE 4096

# tini as PID 1 for zombie reaping and clean signal forwarding.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
