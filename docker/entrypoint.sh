#!/usr/bin/env bash
# Sanity-checks the environment the container was given, then execs the
# orchestrator. It deliberately does almost nothing: the container is a
# dependency sandbox running as you, so `~/.cymphony/config.json`,
# `~/.claude`, `~/.cld` and `~/.gitconfig` are your real files and none of
# them are created, copied or rewritten here.
set -euo pipefail

log() { printf 'cymphony-entrypoint: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

[ -n "${HOME:-}" ] || die "HOME is not set; run with --userns=keep-id and -e HOME=\"\$HOME\""

CYMPHONY_HOME="${HOME}/.cymphony"
CONFIG_PATH="${CYMPHONY_HOME}/config.json"

if [ ! -d "${HOME}" ]; then
  die "${HOME} does not exist in the container; bind-mount your home at the same path"
fi

# The uid comes from the host via keep-id, so a mount that is not writable is
# almost always a missing (or read-only) bind mount rather than a permissions
# bug to repair.
if [ ! -w "${HOME}" ]; then
  die "${HOME} is not writable by uid $(id -u); bind-mount it read-write and use --userns=keep-id"
fi

if [ ! -f "${CONFIG_PATH}" ]; then
  die "no config at ${CONFIG_PATH}.
  Write it by hand — docs/podman.md has a complete example.
  (\`CYMPHONY_ARGS=setup\` runs the wizard, but it only asks Linear/GitHub
  questions, so it is the wrong shape for a YouTrack or GitLab project.)"
fi

# Warn, never fix. Each of these is the operator's own environment and the
# native install would behave the same way.
if [ ! -r "${HOME}/.claude/.credentials.json" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  log "warning: no Claude Code credentials in ${HOME}/.claude; run 'claude /login' on the host, or set CLAUDE_CODE_OAUTH_TOKEN"
fi

if [ -z "${GITLAB_TOKEN:-}" ] && [ -z "${GH_TOKEN:-}" ] && ! git config --get-regexp '^credential\..*\.helper' >/dev/null 2>&1; then
  log "warning: no forge token and no git credential helper configured; cloning a private repo and opening merge requests will fail"
fi

# An agent that needs a compose dev stack silently falls back to host tooling
# without this, so say so at boot rather than in the middle of a run.
if [ ! -S /var/run/docker.sock ]; then
  log "warning: no container engine socket at /var/run/docker.sock; agents cannot run docker/compose (set CYMPHONY_DOCKER_SOCK)"
elif ! docker version >/dev/null 2>&1; then
  log "warning: /var/run/docker.sock is mounted but not usable by uid $(id -u); check the socket's group and the keep_original_groups annotation"
fi

exec "$@"
