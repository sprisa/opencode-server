# sprisa/opencode

[![Docker Image Version](https://img.shields.io/docker/v/sprisa/opencode)](https://hub.docker.com/r/sprisa/opencode)  [![Docker Pulls](https://img.shields.io/docker/pulls/sprisa/opencode)](https://hub.docker.com/r/sprisa/opencode) [![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/opencode-server)](https://artifacthub.io/packages/search?repo=opencode-server)




A general-purpose Ubuntu Docker image for running [opencode](https://github.com/anomalyco/opencode). Published to Docker Hub as `sprisa/opencode:<version>` where `<version>` matches the release pinned in `version.txt`.

## What's inside

| Layer | Details |
|---|---|
| **Base OS** | ubuntu:26.04 |
| **User** | `opencode` (uid/gid 1000), passwordless sudo |
| **opencode** | Pinned in `version.txt` as `OPENCODE_VERSION` build arg |
| **Build tools** | Not included in runtime — `sudo apt install build-essential` if needed for native addons |
| **Python 3** | Lazy-installed via mise (see table below) |
| **Homebrew** | Linux-native Homebrew (`/home/linuxbrew/.linuxbrew`) — `brew` on PATH |
| **zerobrew** | Faster Homebrew alternative (`zb` on PATH) -- used as mise backend for lazy-installed tools |
| **mise** | Dev tool manager — tools listed below install on first use via `zerobrew` backend |
| **CLI utilities** | git, curl, less, unzip, ssh client |
| **Init** | tini as PID 1 (zombie reaping, clean shutdown) |

### Lazy-installed tools

These tools install on first use (via mise → github/zerobrew):

| Tool | Command | Backend |
|---|---|---|
| GitHub CLI | `gh` | github |
| jq | `jq` | github |
| GitLab CLI | `glab` | zerobrew |
| Ruby | `ruby` | zerobrew |
| ripgrep | `rg` | github |
| fd | `fd` | github |
| Wget | `wget` | zerobrew |
| Vim | `vim` | zerobrew |
| Micro | `micro` | github |
| Nano | `nano` | zerobrew |
| Python 3 | `python3` | zerobrew |
| Node.js | `node` | github |
| Sapling | `sl` | github |

The image ships with a system config at `/etc/mise/config.toml` with these pre-approved tools. Users can add or override tools by creating `~/.config/mise/config.toml` — mise merges both.

## Usage

### Quick start

```bash
docker run -it -p 4096:4096 -v $(pwd):/home/opencode sprisa/opencode:latest
```

The server starts on port 4096. Mount your project at `/home/opencode` to persist the entire home directory (dotfiles, config, and `~/workspace`).

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `OPENCODE_PORT` | `4096` | Port the server listens on |
| `OPENCODE_SERVER_PASSWORD` | *(none)* | Optional auth password for the server |
| `OPENCODE_CORS_ORIGIN` | *(none)* | Optional CORS origin; omit to disable CORS |

### Examples

**With authentication:**
```bash
docker run -it -p 4096:4096 \
  -e OPENCODE_SERVER_PASSWORD=secret \
  -v myproject:/home/opencode \
  sprisa/opencode:latest
```

**With CORS enabled for a specific origin:**
```bash
docker run -it -p 4096:4096 \
  -e OPENCODE_CORS_ORIGIN=https://myapp.example.com \
  sprisa/opencode:latest
```

**Custom port:**
```bash
docker run -it -p 8080:8080 \
  -e OPENCODE_PORT=8080 \
  sprisa/opencode:latest
```

## Building & pushing

All docker commands go through `task` which reads the pinned version from `version.txt`:

```bash
task docker:build                          # Build locally as sprisa/opencode:<version>
task docker:login                          # Docker Hub login (needs $DOCKER_USER / $DOCKER_PASS)
task docker:push                           # Push +latest and +<version> for amd64/arm64
task publish                               # Push, create GitHub Release with auto-generated notes
```

## Updating the opencode version

```bash
task update
```

Fetches the latest release from [anomalyco/opencode](https://github.com/anomalyco/opencode) on GitHub and writes it to `version.txt`.

## Runtime notes

- The `opencode` user has passwordless sudo, so you can `su - opencode -c 'apt install <pkg>'` inside the container.
- The root filesystem is ephemeral; mount `/home/opencode` as the persistent volume for all user data (dotfiles, config, projects). The `~/workspace` subdirectory is the default workdir.
- `~/.local/bin` is on PATH and user-writable, useful for dropping custom tools at runtime.
- Node version can be switched at runtime with `n <version>` (e.g. `n lts`).
- Homebrew is installed under `/home/linuxbrew/.linuxbrew` (outside the persistent volume). It uses its bundled portable Ruby — no system Ruby needed.
- Zerobrew (`zb`) is installed at `/usr/local/bin/zb` with its prefix at `~/.local/share/zerobrew/prefix` on PATH for accessing formula binaries.
- **Lazy-installed tools** (see table above): run any listed tool and mise auto-installs it via zerobrew or github backend on first use. The image ships defaults in `/etc/mise/config.toml`; create `~/.config/mise/config.toml` to add your own — mise merges both.
