<div align="center">
  <h1>Opencode Server</h1>
  <p><strong>Run opencode as a server in Docker or Kubernetes.</strong></p>
  <p>The opencode web UI and API in one Ubuntu image, with dev tools that install the first time you use them.</p>
  <p>
    <a href="#quick-start"><strong>Quick start</strong></a> ·
    <a href="#tools"><strong>Tools</strong></a> ·
    <a href="#configuration"><strong>Configuration</strong></a> ·
    <a href="#kubernetes"><strong>Kubernetes</strong></a>
  </p>
  <p>
    <a href="https://hub.docker.com/r/sprisa/opencode"><img src="https://img.shields.io/docker/pulls/sprisa/opencode" alt="Docker Pulls"></a>
    <a href="https://hub.docker.com/r/sprisa/opencode"><img src="https://img.shields.io/docker/image-size/sprisa/opencode" alt="Docker Image Size"></a>
    <a href="https://artifacthub.io/packages/search?repo=opencode-server"><img src="https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/opencode-server" alt="Artifact Hub"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MPL%202.0-blue" alt="License: MPL 2.0"></a>
  </p>
  <p>
    <a href="https://github.com/sprisa/opencode-server"><img src="https://shieldcn.dev/group/github/stars/sprisa/opencode-server+github/forks/sprisa/opencode-server+github/release/sprisa/opencode-server+github/last-commit/sprisa/opencode-server.svg?variant=secondary&size=xs" alt="GitHub stars, forks, release, and last commit"></a>
  </p>
</div>

**opencode-server** is a Docker image for [opencode](https://github.com/anomalyco/opencode),
the open source AI coding agent. It runs `opencode serve`, so you get opencode's
web UI and API on one port. Start the container, open it in your browser, and
work on the project you mounted.

- **Sign in with a password.** The web UI and API share port 4096. You set the
  password, or the server generates one for you.
- **Install tools on first use.** Run `gh`, `rg`, `node`, `claude`, or any other
  [listed tool](#tools) and it installs on the spot. Agents get the same
  behavior, and the image stays small.
- **Bring your Claude or ChatGPT plan.** Sign in from opencode's web UI with the
  subscription you already have; see
  [Use your Claude or ChatGPT subscription](#use-your-claude-or-chatgpt-subscription).
- **Keep one folder.** Your config, sessions, and projects live in
  `/home/opencode`. Mount a volume there and the rest of the container can be
  thrown away.
- **Run it on Kubernetes.** We run this image on Kubernetes for
  [Codeplace](https://www.codeplace.app), one pod per user. See
  [Kubernetes](#kubernetes) for the setup.

The image is published to Docker Hub as
[`sprisa/opencode`](https://hub.docker.com/r/sprisa/opencode).

## Quick start

Run this from the folder where you want opencode to keep its files:

```sh
docker run -it -p 4096:4096 -v $(pwd):/home/opencode sprisa/opencode:latest
```

The server prints a generated password at startup, on the `server password`
line. Open <http://localhost:4096> and sign in with it. To choose your own, add
`-e OPENCODE_PASSWORD=change-me`. If the container runs in the background, get
the password from its logs:

```sh
docker logs <container> 2>&1 | grep 'server password'
```

The current folder becomes the container's home directory. opencode saves its
config, sessions, and dotfiles there, and starts in the `workspace/` subfolder.
Put your projects in `workspace/`.

To check the API from a script, use HTTP Basic auth with the username `opencode`:

```sh
curl --fail --user opencode:<password> http://localhost:4096/api/info
```

### Mount an existing project

The command above writes opencode's config and hidden folders into the folder
you mount. To work on an existing project without that, use two mounts. A Docker
volume holds the home directory, and your project goes at `~/workspace`:

```sh
docker run -it -p 4096:4096 \
  -v opencode-home:/home/opencode \
  -v "$(pwd)":/home/opencode/workspace \
  sprisa/opencode:latest
```

Docker creates the `opencode-home` volume on the first run. It keeps your config
and sessions between containers, and your project folder only holds your code.

## Tools

The image comes with git, curl, ssh, less, and unzip. The tools below install
through [mise](https://mise.jdx.dev) the first time someone runs the command:

| Tool | Command | Backend |
|---|---|---|
| GitHub CLI | `gh` | mise core |
| jq | `jq` | mise core |
| GitLab CLI | `glab` | mise core |
| Ruby | `ruby` | mise core |
| ripgrep | `rg` | mise core |
| fd | `fd` | mise core |
| Wget | `wget` | zerobrew |
| Vim | `vim` | mise core |
| Micro | `micro` | mise core |
| Nano | `nano` | zerobrew |
| Python 3 | `python3` | mise core |
| Node.js | `node` | mise core |
| Sapling | `sl` | github |
| clonetree | `clonetree` | github |
| Codex | `codex` | mise core |
| Claude Code | `claude` | mise core |
| cloudflared | `cloudflared` | mise core |

Most tools install in a few seconds. They're saved to `/opt/mise`, outside the
home directory, so a new container downloads them again the first time they're
used.

Each image locks these tools to the newest release at build time, in
`/etc/mise/mise.lock`. First runs download that release directly, with no
version lookup and no GitHub API calls, and a newer image brings newer
versions. To get the newest release of one of these tools in an older image,
run `mise upgrade <tool>` or `mise use <tool>@latest`. A bare `mise use <tool>`
keeps the image's version. Tools that aren't in the table always resolve to
their newest release.

<details>
<summary><strong>What the backends mean</strong></summary>

**mise core** tools use a name from mise's built-in registry, for example
`ripgrep` rather than `github:BurntSushi/ripgrep`. They're preferred. **github**
tools look up releases through the GitHub API, which is rate limited. **zerobrew**
tools install from Homebrew packages and add a per-tool install prefix. Those two
are only used for tools that aren't in the mise registry.

Ruby uses mise's prebuilt versions (`ruby.compile = false`) because the image has
no compiler. Gems that ship prebuilt, such as nokogiri, install normally. Gems
that build native code need `sudo apt-get install build-essential` first.

</details>

### Use your Claude or ChatGPT subscription

You can sign in with a Claude or ChatGPT subscription you already have. Both
sign-ins happen in opencode's web UI.

**Claude:** open the terminal built into opencode's web UI and run:

```sh
claude auth login
```

It prints a sign-in link. Open the link in your browser, then paste the code it
shows back into the terminal. Then connect the Claude agent from the opencode UI.

**ChatGPT:** sign in through opencode with the device code option. You don't
need the Codex CLI. Turn device codes on in ChatGPT first: under **App
security** in ChatGPT's security settings, enable **Enable device code sign-in
for Codex, Excel, PowerPoint, and Word**.

Both sign-ins are saved in the home directory, so they last as long as you keep
your home mount.

### Add your own tools

Tools you add go in `~/.config/mise/config.toml`, which lives on the home volume.
mise merges it with the image's defaults in `/etc/mise/config.toml`:

```sh
mise use -g go@latest
```

Tools you add this way also install on first use. To install them in the
background each time the container starts, set `OPENCODE_INSTALL_HOME_TOOLS=true`.

Need a system package instead? The `opencode` user has passwordless sudo:

```sh
sudo apt-get update && sudo apt-get install -y <package>
```

opencode loads an instruction file, `/etc/opencode/mise-instructions.md`, that
tells agents to try mise before apt.

<details>
<summary><strong>Other package managers and paths</strong></summary>

- **Homebrew** (`brew`) is installed under `/home/linuxbrew/.linuxbrew`. It runs on
  its own bundled Ruby.
- **zerobrew** (`zb`), a faster Homebrew client, is at `/usr/local/bin/zb`.
- **`~/.local/bin`** is on `PATH` and writable, so you can drop your own binaries
  there.
- The image runs on Ubuntu 26.04 with [tini](https://github.com/krallin/tini) as
  PID 1, so the server shuts down cleanly and leftover processes get cleaned up.

</details>

## Configuration

Configure the server with environment variables:

| Variable | Default | What it does |
|---|---|---|
| `OPENCODE_PASSWORD` | generated | Password for the web UI and API. A generated password changes on every restart. |
| `OPENCODE_PORT` | `4096` | Port the server listens on. |
| `OPENCODE_CORS_ORIGIN` | none | An extra browser origin allowed to call the API, such as `https://myapp.example.com`. |
| `OPENCODE_PRINT_LOGS` | `false` | Set to `true` to print opencode's logs to the container output. |
| `OPENCODE_LOG_LEVEL` | opencode's default | `DEBUG`, `INFO`, `WARN`, or `ERROR`. v2 also accepts lowercase. |
| `OPENCODE_INSTALL_HOME_TOOLS` | `false` | Set to `true` to install the tools in `~/.config/mise/config.toml` in the background, 3 seconds after startup. |
| `OPENCODE_SERVER_PASSWORD` | none | The password variable for v1 images. v2 accepts it as an older name, and `OPENCODE_PASSWORD` wins if both are set. |
| `OPENCODE_SERVER_USERNAME` | `opencode` | v1 images only: changes the API username. |

The defaults are for v2, which `latest` runs. On v1 images, the server has no
password unless you set `OPENCODE_SERVER_PASSWORD`.

For example, to run on port 8080 with logs:

```sh
docker run -it -p 8080:8080 \
  -e OPENCODE_PORT=8080 \
  -e OPENCODE_PASSWORD=change-me \
  -e OPENCODE_PRINT_LOGS=true \
  sprisa/opencode:latest
```

## Deploy

### Kubernetes

We run this image in production on Kubernetes for
[Codeplace](https://www.codeplace.app). Each user gets their own opencode pod
with its own persistent volume. Codeplace uses the published `sprisa/opencode`
image unchanged and adds its own setup from an init container. You can customize
it the same way, without forking the image.

For your own Deployment or StatefulSet, set up these four things:

- **Storage.** Mount a PersistentVolumeClaim at `/home/opencode`. Nothing outside
  it is kept when the pod restarts.
- **User.** The server runs as uid and gid 1000. Set `fsGroup: 1000` so it can
  write to the volume.
- **Password.** Pass `OPENCODE_PASSWORD` from a Secret. Otherwise the password
  changes on every restart.
- **Probes.** Use a TCP probe on port 4096. `/api/info` returns 401 without
  credentials, so it isn't a good plain HTTP probe.

### Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/opencode-server?referralCode=KSFpZz&utm_medium=integration&utm_source=template&utm_campaign=generic)

## Versions and tags

| Tag | Follows |
|---|---|
| `latest`, `v2` | The newest opencode v2 release |
| `2.x.y` | One exact opencode release |
| `v1` | The newest opencode v1 release, for existing v1 setups |

Each image tag matches the opencode version inside it. The repo pins those
versions in `version.txt` (v2) and `version-v1.txt` (v1).

<details>
<summary><strong>Upgrading from v1</strong></summary>

`latest` moved from v1 to v2. To stay on v1, switch to the `v1` tag.

v2 reads your v1 config from the same locations and migrates your old sessions.
Its server API and plugin API are new, though, so v1 API integrations and plugins
need changes. See opencode's
[migration guide](https://opencode.ai/v2/docs/migrate-v1).

A few behaviors differ between the two lines:

- **Auth.** v2 always requires a password. v1 only turns on auth when
  `OPENCODE_SERVER_PASSWORD` is set.
- **Health check.** v2 uses `/api/info`. v1 uses `/global/health`. On v2, the
  old v1 paths can return the web app's HTML with a 200, so they don't prove the
  API is up.

</details>

## Development

Build and publish tasks run through [Task](https://taskfile.dev) and read the
pinned versions from `version.txt` and `version-v1.txt`:

```sh
task docker:build      # Build v2 locally as sprisa/opencode:<version>
task docker:build:v1   # Build v1 locally
task update            # Bump both pins to the newest stable opencode releases
task publish           # Push both lines and create any missing GitHub releases
```

The end-to-end tests run against a built image:

```sh
bash tests/test-server-e2e.sh sprisa/opencode:<version>
bash tests/test-toolchain-e2e.sh sprisa/opencode:<version>
bash tests/test-home-tools-e2e.sh sprisa/opencode:<version>
bash tests/test-mise-lock-e2e.sh sprisa/opencode:<version>
```

The image locks its mise tools during the build, so building needs network
access. A new opencode version always produces a fresh lock. To refresh tool
versions without changing the opencode version, build with `--no-cache`.

<details>
<summary><strong>Releases and publishing</strong></summary>

`task update` uses an authenticated GitHub CLI (`gh`) and `jq` to find the
newest stable v2 and v1 [opencode releases](https://github.com/anomalyco/opencode/releases).
It skips drafts, prereleases, and component releases, and never moves a pin
backwards. A scheduled workflow, `opencode release checker`, runs the same check
and opens a pull request for each line that has a new release.

`task publish` pushes multi-arch (amd64 and arm64) images for both lines,
updates the moving tags, and creates any missing GitHub releases at the current
commit. Only v2 releases are marked as GitHub's latest release. Other tasks:

```sh
task docker:login     # Log in to Docker Hub (needs $DOCKER_USER and $DOCKER_PASS)
task docker:push      # Push v2 as <version>, latest, and v2
task docker:push:v1   # Push v1 as <version> and v1
```

To publish from GitHub instead, run **Actions → Publish → Run workflow** on
`main`. Add two repository secrets first:

- `DOCKERHUB_USERNAME`: a Docker Hub account that can push to `sprisa/opencode`.
- `DOCKERHUB_TOKEN`: a Docker Hub access token with read and write access.

The workflow creates GitHub releases with the built-in `GITHUB_TOKEN`.

</details>

---

Runs in production on Kubernetes at [codeplace.app](https://www.codeplace.app).
Licensed under [MPL 2.0](LICENSE).
