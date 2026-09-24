# Running Cymphony locally with rootless Podman

The container is a **dependency sandbox, not a security boundary**. It pins the
toolchain — Elixir/OTP, Node, the Claude Code CLI, `glab`/`gh`, git, ripgrep,
zsh — and then runs as *you*, against *your* home directory.

It also bundles the toolchains the *agent* needs for this repository, so
nothing has to exist on the host:

| Bundled | Where | Why |
|---|---|---|
| .NET SDK (`DOTNET_VERSION`, default 10.0.201) | `/usr/local/dotnet` | the repo targets `net10.0`; `DOTNET_ROOT` points here |
| Playwright Chromium (`PLAYWRIGHT_VERSION`) | `/usr/local/ms-playwright` | `PLAYWRIGHT_BROWSERS_PATH` points here, not the per-user `~/.cache/ms-playwright` |
| `libicu` | apt | without it the .NET SDK will not start, and the usual `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` workaround quietly disables casefolding and diacritic folding — which surfaces as unrelated-looking test failures |
| GTK/X11/NSS set | apt | without it Chromium dies on `libglib-2.0.so.0: cannot open shared object file` |

Verified by running `dotnet --version` and launching Chromium against an
**empty** home, so neither depends on anything of yours. Both blocks are
`ARG`-pinned and can be deleted for a project that is not .NET and needs no
browser, which takes roughly 700 MB off the image.

Two caveats. Your host `~/.dotnet` and `~/.cache/ms-playwright` are still
visible through the home mount but unused — the image's copies win via `PATH`
and `PLAYWRIGHT_BROWSERS_PATH`. And if a project pins a Playwright version
whose browser build differs from the bundled one, the client will try to
download into the (root-owned) shared path and fail; bump `PLAYWRIGHT_VERSION`
to match, or unset `PLAYWRIGHT_BROWSERS_PATH` so it falls back to the writable
home cache. `~/.cymphony`,
`~/.claude`, `~/.cld` and `~/.gitconfig` are the same files a native install
would use, so behaviour matches the native run and nothing is copied, generated
or owned by the container.

```bash
systemctl --user enable --now podman.socket                # once per machine
$EDITOR ~/.cymphony/config.json                            # first run: see below
podman compose up
xdg-open http://localhost:4000
```

`podman compose` delegates to the Docker Compose plugin, which talks to
podman's API socket. Without that user unit running you get
`failed to connect to the docker API at unix:///run/user/1000/podman/podman.sock`.
It is a rootless user service — nothing runs as root.

To skip compose entirely, the equivalent invocation is:

```bash
podman run --rm -it \
  --userns=keep-id --security-opt label=disable --network=host \
  -v "$HOME:$HOME" -e HOME="$HOME" -w "$HOME" \
  -v /var/run/docker.sock:/var/run/docker.sock --group-add keep-groups \
  -e GITLAB_TOKEN -e GITLAB_HOST \
  localhost/cymphony:local
```

## How it runs as you

| Flag | Why |
|---|---|
| `userns_mode: keep-id` | Maps your uid straight through. Everything the agent writes — clones, logs, refreshed Claude credentials — is owned by you on the host, not by a subuid. |
| `security_opt: label=disable` | SELinux. **Never** put `:z`/`:Z` on the `$HOME` mount: that recursively relabels your entire home directory. Disabling the label for this container is the right trade for a sandbox meant to see your home. |
| `network_mode: host` | Keeps the dashboard where a native run puts it, so `server.host` stays `127.0.0.1` in your config and nothing about the config differs between containerized and native. |
| `-v $HOME:$HOME` | Your real home at the same path, so workspace paths in the dashboard and logs are valid on the host too. |
| `-v ${CYMPHONY_DOCKER_SOCK:-/var/run/docker.sock}:/var/run/docker.sock` | The host container engine, for agents whose repository runs a compose dev stack (see below). |
| `annotations: run.oci.keep_original_groups: "1"` | keep-id drops your supplementary groups, including the `docker` group that grants the socket. This is what `--group-add keep-groups` sets; compose has to spell it as the crun annotation because the Docker API rejects `keep-groups`. |

### Container engine for agents

A repository whose dev stack is a compose project (harvest_frontend's
`./build.sh up|stack|exec`, and the `harvest-frontend-stack` skill that drives
it) needs `docker` inside the container. The image ships the Docker CLI with
the Compose and Buildx plugins, client only; compose mounts the host engine's
socket at `/var/run/docker.sock`, the CLI's default, so no `DOCKER_HOST` is
involved. Without it the agent quietly falls back to host PHP/composer and
never brings a stack up.

- The default source is rootful Docker's `/var/run/docker.sock`. For rootless
  Podman, export `CYMPHONY_DOCKER_SOCK=$XDG_RUNTIME_DIR/podman/podman.sock`
  before `podman compose up`. On a host with neither, set it to `/dev/null`
  (the source must exist); the entrypoint then warns at boot.
- Stacks the agent starts are ordinary containers on the host engine, and the
  bind mounts they declare resolve on the host. That works because every
  workspace lives under `$HOME`, which is mounted at the same path.
- Whoever can reach that socket controls every container on it, which is
  root-equivalent for rootful Docker. That is consistent with this container
  being a dependency sandbox rather than a security boundary, but it is a
  bigger grant than the home mount alone.

The image contains no application user and no `USER` directive — it is
uid-agnostic, and the only writable paths it needs are your home and `/tmp`.

Narrowing the mount to just `~/.cymphony` and `~/.claude` works, but costs you:
`~/.cld` provider rotation, your git identity, and a writable `$HOME` for the
git credential helper (the parent of a bind mount is root-owned in the user
namespace, so `$HOME` itself would not be writable).

## Configuration is yours

There is no env-var config layer. `~/.cymphony/config.json` is your file, and
the entrypoint never creates or rewrites it — it refuses to start with
instructions when it is missing.

**Write it by hand.** The `cymphony setup` wizard exists, but it only asks
Linear and GitHub questions (`Linear project slug`, `GitHub repo URL`) and
writes `linear_*`/`github_repo_url` keys, so for a YouTrack or GitLab project
it produces the wrong shape. The example below is the shape you want.

Because an OTP release's `start` command does not forward arguments,
`CYMPHONY_ARGS` is how CLI commands and flags reach the app:

```bash
podman compose run --rm -e CYMPHONY_ARGS=setup cymphony
podman compose run --rm -e CYMPHONY_ARGS=list cymphony
podman compose run --rm -e CYMPHONY_ARGS='project MySQL cr 3' cymphony
```

Quoting is honoured, so a project name with spaces survives.

### A complete config for YouTrack + GitLab

```json
{
  "dashboard_refresh_seconds": 3,
  "projects": [
    {
      "name": "MySQL",

      "tracker_kind": "youtrack",
      "tracker_endpoint": "https://example.youtrack.cloud",
      "tracker_api_key": "perm-…",
      "tracker_project_slug": "MYSQL",

      "state_field": "State",
      "queued_states": ["Open", "Confirmed", "Reopened"],
      "in_progress_state": "In Progress",
      "review_state": "Review and Testing",
      "merge_state": "",
      "active_states": ["Open", "Confirmed", "Reopened", "In Progress"],
      "terminal_states": [
        "Fixed", "Verified", "Done", "Closed",
        "Duplicate", "Can't reproduce", "Won't Fix", "Obsolete", "Incomplete"
      ],

      "branch_name_template": "{{ issue.identifier }}",

      "forge": "gitlab",
      "forge_token": "$GITLAB_TOKEN",
      "forge_host": "gitlab.harvest.com",
      "repo_url": "git@gitlab.example.com:group/mysql.git",
      "rewrite_ssh_remote": false,

      "claude_bare_mode": false,
      "max_concurrent_agents": 2,
      "server_port": 4000
    }
  ]
}
```

Written to `~/.cymphony/config.json`, mode `0600` (it holds your YouTrack
token). Three entries are easy to get wrong:

- **`active_states` means "keep re-dispatching until the issue leaves this
  set."** `Review and Testing` is deliberately absent — that is what stops
  agents waking on tickets a reviewer already owns. A reviewer requesting
  changes moves the ticket back to `In Progress`, which resumes the agent.
- **`merge_state: ""`** means humans merge. The generated prompt then omits the
  entire land/merge protocol rather than naming a state you do not have.
- **`branch_name_template`** is the branch the agent creates, as a Liquid
  template rendered against the issue. The default is the bare identifier
  (`HC-1`); without it the agent invents a descriptive name per run
  (`HC-1-hello-world-static-page`). Use `{{ issue.branch_name }}` for the
  tracker's own suggestion (Linear populates it, YouTrack does not), or
  something like `"feature/{{ issue.identifier }}"`. The result is sanitized
  into a legal git ref, and a broken template falls back to the identifier
  rather than failing the run.
- **`state_field`** is the custom field holding the workflow state. YouTrack
  projects rename it — `"Stage"` is as common as the stock `"State"` — and
  reading the wrong name yields `state: nil`, which matches no active state and
  so never dispatches. Check yours before anything else:
  `curl -H "Authorization: Bearer $TOKEN" "$URL/api/issues/ABC-1?fields=customFields(name,value(name))"`.
  Each project can differ, so a second project may need its own value.
- **`rewrite_ssh_remote: false`** keeps an `scp`-style remote as written. By
  default Cymphony rewrites `git@host:group/repo.git` to HTTPS, which is right
  when the worker has no key of its own — but running as you, your `~/.ssh` and
  your agent socket are already in the mounted home, so SSH is the path of
  least resistance. Drop this key (and use the `https://` URL) if you would
  rather authenticate git with a token.
- **`claude_bare_mode: false`** is required to authenticate as a Claude Code
  *account*. `claude --bare` (the default) skips credential reads and fails
  with `Not logged in · Please run /login` even with valid credentials. Only
  leave it default if a provider exports an `ANTHROPIC_API_KEY`.

Post-review states (`Awaiting Staging`, `In UAT`, `UAT Complete`) belong in
neither list: Cymphony ignores them, and a dependent issue stays blocked until
its blocker reaches a terminal state.

## Credentials

Nothing is copied into the container; it reads yours.

- **Claude Code** — your real `~/.claude`, mounted read-write, so a refreshed
  OAuth token persists to the host. `claude /login` on the host (or inside,
  they are the same files). `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY`
  are honoured as fallbacks.
- **git transport** — with `rewrite_ssh_remote: false` and an SSH remote, git
  uses your keys and `SSH_AUTH_SOCK`, both already inside the mounted home; the
  agent's own `git push` gets the socket too. For HTTPS instead, add a GitLab
  line to `~/.git-credentials` (your `credential.helper` is already `store`).
- **GitLab API** — `forge_token` and `forge_host` in `config.json` are the
  durable home for these; the agent gets them as `GITLAB_TOKEN`/`GLAB_TOKEN`
  and `GITLAB_HOST` (or `GH_TOKEN`/`GITHUB_TOKEN` when `forge` is `github`).
  A literal works, and so does `"$GITLAB_TOKEN"`, which reads the environment
  variable at load time and keeps the secret out of the file. Leave them out
  entirely and the daemon's own environment is inherited instead, so an
  exported `GITLAB_TOKEN` still works — config just wins when both are set.
  The token needs scope `api` and role Developer (Reporter cannot set the
  `cymphony` label; Maintainer is needed only if you set a `merge_state`).
  Prefer a Project Access Token over your personal one — see
  "Which GitLab permissions the token needs" in the README.
- **GitLab (environment route)** — set `GITLAB_TOKEN` (and `GITLAB_HOST` for self-hosted) in your
  shell before `podman compose up`, or authenticate `glab` on the host so its
  config under `~/.config` is visible. For HTTPS clones you need a git
  credential helper: `glab auth setup-git` on the host writes it to your real
  `~/.gitconfig`, which the container then uses. The entrypoint warns when it
  sees neither, and never edits your git config.
- **Providers** — `~/.cld` works: `zsh` is in the image and `ShellProvider`
  sources your rc files exactly as it does natively, so `c cz1,cv2` rotation is
  available.

## Everyday commands

```bash
podman compose logs -f cymphony                 # boot output and crashes
tail -f ~/.cymphony/daemon.log                  # warnings+, on the host
ls ~/.cymphony/workspaces                       # live workspaces, on the host
curl -s localhost:4000/api/v1/state | jq .
```

Because it is your home, host tools work directly — no `podman compose exec`
needed to look at state.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `no config at …/.cymphony/config.json` | First run — write the config above. The `setup` wizard is Linear/GitHub-only. |
| `failed to connect to the docker API at unix:///run/user/1000/podman/podman.sock` | `podman compose` needs the API socket: `systemctl --user enable --now podman.socket`. |
| `HOME is not writable by uid …` | Missing `--userns=keep-id`, or the home mount is read-only. |
| `short-name resolution enforced` on build | Podman needs fully-qualified images; the Dockerfile pins `docker.io/...`. A local override that drops the registry will hit this. |
| Permission denied writing into the workspace | `:z`/`:Z` was added to the `$HOME` mount, or `keep-id` is missing. |
| `libglib-2.0.so.0: cannot open shared object file`, or the .NET SDK refusing to start | An image built before the shared-library layer; rebuild with `podman compose build`. |
| Agent fails with `Not logged in · Please run /login` | `claude_bare_mode` is not `false`, or `~/.claude` is not mounted. |
| Dashboard not on `localhost:4000` | `server_port` is unset in `config.json`, or `network_mode: host` was replaced by port publishing without setting `server_host` to `0.0.0.0`. |
| `glab` hits gitlab.com on a self-hosted instance | `GITLAB_HOST` is unset. |
| `no container engine socket at /var/run/docker.sock` at boot, or the agent reports `docker: command not found` | An image built before the Docker CLI layer (`podman compose build`), or `CYMPHONY_DOCKER_SOCK` points at something that is not a socket. |
| `/var/run/docker.sock is mounted but not usable` | The `docker` group did not survive keep-id: the `run.oci.keep_original_groups` annotation is missing, the runtime is not crun, or you were added to the group after your login session started. |
