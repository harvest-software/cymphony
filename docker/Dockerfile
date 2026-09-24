# Cymphony orchestrator, for running locally under rootless Podman.
#
# The container is a *dependency sandbox*, not a security boundary: it pins the
# Elixir/OTP toolchain, Node, the Claude Code CLI and the forge CLIs, and then
# runs as the invoking user against that user's real home. Nothing here creates
# an application user or owns any state — `podman --userns=keep-id` maps your
# uid straight through, and `$HOME` is a bind mount of your actual home, so
# `~/.cymphony`, `~/.claude` and `~/.cld` are the same files the native install
# would use.
#
# Two stages: the pinned Elixir toolchain assembles an OTP release, and a slim
# Erlang runtime carries it plus the toolchain the *agents* need — git, gh/glab,
# the Docker CLI and the Claude Code CLI. The dashboard's CSS/JS/icons are
# compiled into the beam files (`CymphonyElixirWeb.StaticAssets`), so no asset
# pipeline is involved.
#
# A release, not the escript: escripts cannot carry a dependency's `priv/`
# directory, and exqlite (the completion store) is a NIF — an escript build
# dies at boot with `Exqlite.Sqlite3NIF.open/2 undefined`.

# Fully qualified: podman enforces short-name resolution and, non-interactively
# (which is how compose builds), refuses a bare `hexpm/elixir` rather than
# guessing a registry.
ARG ELIXIR_IMAGE=docker.io/hexpm/elixir:1.19.5-erlang-28.4.3-debian-trixie-20260824
ARG ERLANG_IMAGE=docker.io/hexpm/erlang:28.4.3-debian-trixie-20260824-slim

FROM ${ELIXIR_IMAGE} AS build

# Selects `CymphonyElixir.BurritoCLI` as the OTP application module (see
# `application_mod/0` in mix.exs): it brings up the supervision tree and then
# hands off to `CLI.main/1`, which is exactly the boot order a container
# wants. The `cymphony_docker` release stops at `:assemble`, so none of
# Burrito's Zig wrapping runs.
ENV MIX_ENV=prod \
    BURRITO_BUILD=1

WORKDIR /src

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get

COPY config config
COPY lib lib
COPY priv priv
COPY WORKFLOW.md ./

RUN mix release cymphony_docker


FROM ${ERLANG_IMAGE} AS runtime

ARG NODE_VERSION=22.20.0
# Toolchains the *agent* needs for this repository, bundled so nothing has to
# exist on the host. Bump deliberately; drop both blocks below for a project
# that is not .NET and needs no browser, and the image shrinks by ~700 MB.
ARG DOTNET_VERSION=10.0.201
ARG PLAYWRIGHT_VERSION=1.63.0
# Pinned: a rebuild must not change the forge CLI under a running fleet.
ARG GLAB_VERSION=1.117.0
# Pinned so a rebuild cannot silently change the agent's CLI underneath a
# running fleet. Bump deliberately.
ARG CLAUDE_CODE_VERSION=latest
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PATH=/usr/local/node/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      gnupg \
      jq \
      less \
      openssh-client \
      procps \
      python3 \
      ripgrep \
      xz-utils \
      zsh \
  && rm -rf /var/lib/apt/lists/*

# Libraries the *agent's* toolchain links against. Neither tool ships here —
# dotnet lives in the operator's ~/.dotnet and Playwright's browsers in
# ~/.cache/ms-playwright, both inside the mounted home — but their shared
# objects have to exist in the image or they fail at exec time:
#
#   * libicu: without it the .NET SDK refuses to start at all, and forcing
#     DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 to get around that silently
#     breaks culture-aware behaviour (casefolding, diacritic folding), which
#     shows up as unrelated-looking test failures.
#   * the GTK/X/NSS set: Playwright's bundled Chromium is dynamically linked
#     and dies on `libglib-2.0.so.0: cannot open shared object file`, so no
#     UI walkthrough or screenshot evidence is possible.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libicu76 \
      libglib2.0-0t64 \
      libnss3 \
      libnspr4 \
      libdbus-1-3 \
      libatk1.0-0t64 \
      libatk-bridge2.0-0t64 \
      libatspi2.0-0t64 \
      libcups2t64 \
      libdrm2 \
      libgbm1 \
      libxkbcommon0 \
      libxcomposite1 \
      libxdamage1 \
      libxfixes3 \
      libxrandr2 \
      libpango-1.0-0 \
      libcairo2 \
      libasound2t64 \
  && rm -rf /var/lib/apt/lists/*

# GitLab CLI: the agent drives `glab mr` for a `forge: gitlab` project, and
# `glab auth git-credential` is what lets the workspace `after_create` hook
# clone over HTTPS without an SSH key.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) glab_arch=amd64 ;; \
      arm64) glab_arch=arm64 ;; \
      *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/glab.tar.gz \
      "https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/packages/generic/glab/${GLAB_VERSION}/glab_${GLAB_VERSION}_linux_${glab_arch}.tar.gz"; \
    tar -xzf /tmp/glab.tar.gz -C /tmp; \
    install -m 755 /tmp/bin/glab /usr/local/bin/glab; \
    rm -rf /tmp/glab.tar.gz /tmp/bin; \
    glab --version

# GitHub CLI: kept alongside `glab` so one image serves either forge — the
# workspace `after_create` hook clones over HTTPS and a `forge: github`
# project drives `gh pr` commands.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    chmod 644 /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=${arch} signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*

# Docker CLI + Compose/Buildx plugins, *client only* — no daemon runs here.
# A repository whose dev stack is a compose project (harvest_frontend's
# `./build.sh up|stack|exec`) needs them, and without them the agent silently
# falls back to host tooling and never brings a stack up. compose.yaml mounts
# the host engine's socket at /var/run/docker.sock, the CLI's default, so no
# DOCKER_HOST has to reach the agent's curated environment. Bind mounts a
# stack declares resolve on the *host*, which works because $HOME (and so
# every workspace) is mounted at the same path.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    . /etc/os-release; \
    curl -fsSL https://download.docker.com/linux/debian/gpg \
      -o /usr/share/keyrings/docker-archive-keyring.asc; \
    chmod 644 /usr/share/keyrings/docker-archive-keyring.asc; \
    echo "deb [arch=${arch} signed-by=/usr/share/keyrings/docker-archive-keyring.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      docker-ce-cli docker-compose-plugin docker-buildx-plugin; \
    rm -rf /var/lib/apt/lists/*; \
    docker --version; \
    docker compose version

# Node is here only to host the Claude Code CLI.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) node_arch=x64 ;; \
      arm64) node_arch=arm64 ;; \
      *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" \
      | tar -xJ -C /usr/local; \
    mv "/usr/local/node-v${NODE_VERSION}-linux-${node_arch}" /usr/local/node; \
    npm install --global "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
    npm cache clean --force; \
    claude --version

COPY --from=build /src/_build/prod/rel/cymphony_docker /opt/cymphony
COPY docker/entrypoint.sh /usr/local/bin/cymphony-entrypoint
RUN chmod 755 /usr/local/bin/cymphony-entrypoint \
  && ln -s /opt/cymphony/bin/cymphony_docker /usr/local/bin/cymphony

# .NET SDK. `net10.0` is what the repository targets, and it must come from the
# image: relying on the operator's ~/.dotnet through the home mount means the
# container only works on a machine that already has it, which defeats pinning
# the toolchain in the first place. Installed to a world-readable prefix
# because the container runs as the invoking uid, whoever that is.
RUN set -eux; \
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh; \
    bash /tmp/dotnet-install.sh --version "${DOTNET_VERSION}" --install-dir /usr/local/dotnet --no-path; \
    rm -f /tmp/dotnet-install.sh; \
    ln -s /usr/local/dotnet/dotnet /usr/local/bin/dotnet; \
    chmod -R a+rX /usr/local/dotnet; \
    dotnet --version

# Playwright browsers, into the shared location Playwright looks in when
# PLAYWRIGHT_BROWSERS_PATH is set, rather than the per-user
# ~/.cache/ms-playwright. The GTK/NSS libraries they link against are
# installed above.
ENV PLAYWRIGHT_BROWSERS_PATH=/usr/local/ms-playwright
RUN set -eux; \
    npx --yes "playwright@${PLAYWRIGHT_VERSION}" install chromium; \
    chmod -R a+rX "${PLAYWRIGHT_BROWSERS_PATH}"; \
    npm cache clean --force

# No `USER`: the image has no application user of its own. Podman's
# `--userns=keep-id` runs the container as the invoking uid, and `$HOME` is
# supplied at run time as a bind mount of that user's home. The image is
# uid-agnostic — /opt and /usr/local are world-readable and executable, and the
# only writable paths it needs are $HOME (yours) and /tmp.
#
# The release lives under root-owned /opt, so point its scratch space at /tmp.
ENV RELEASE_TMP=/tmp \
    DOTNET_ROOT=/usr/local/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1

# `start` is the release script's foreground command. It does not forward
# arguments to the application; `CYMPHONY_ARGS` is that channel instead (see
# `BurritoCLI.cli_args/0`), which is how `setup`, `list` and the run flags stay
# reachable. Everything else comes from ~/.cymphony/config.json — your file,
# never generated here.
ENTRYPOINT ["/usr/local/bin/cymphony-entrypoint"]
CMD ["cymphony", "start"]
