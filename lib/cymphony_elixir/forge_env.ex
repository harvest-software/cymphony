defmodule CymphonyElixir.ForgeEnv do
  @moduledoc """
  The environment the forge CLIs read their credentials and host from.

  Two callers shell out to `glab`/`gh`: the agent, which opens and updates its
  own review, and the dependency gate, which asks whether a squash-merged
  dependency landed. Both take the token and host from the project's
  `forge_token` / `forge_host`, so they build the environment here and cannot
  drift apart.

  `glab` reads `GITLAB_TOKEN` (or `GLAB_TOKEN`), and `GITLAB_HOST` points it at
  a self-hosted instance; without a host it only knows gitlab.com and answers
  "none of the git remotes configured for this repository point to a known
  GitLab host". `gh` reads `GH_TOKEN` or `GITHUB_TOKEN`. Blank values are left
  out, so an unset key never masks one inherited from the daemon's shell.
  """

  @spec cli_env(String.t() | nil, String.t() | nil, String.t() | nil) :: %{String.t() => String.t()}
  def cli_env("gitlab", token, host) do
    %{}
    |> put("GITLAB_TOKEN", token)
    |> put("GLAB_TOKEN", token)
    |> put("GITLAB_HOST", host)
  end

  def cli_env(_forge, token, _host) do
    %{}
    |> put("GH_TOKEN", token)
    |> put("GITHUB_TOKEN", token)
  end

  defp put(env, name, value) when is_binary(value) and value != "", do: Map.put(env, name, value)
  defp put(env, _name, _value), do: env
end
