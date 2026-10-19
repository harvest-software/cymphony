defmodule CymphonyElixir.ForgeEnvTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.ForgeEnv

  test "GitLab gets the token under both names glab reads, and the host" do
    assert ForgeEnv.cli_env("gitlab", "t0ken", "gitlab.example.com") == %{
             "GITLAB_TOKEN" => "t0ken",
             "GLAB_TOKEN" => "t0ken",
             "GITLAB_HOST" => "gitlab.example.com"
           }
  end

  test "GitHub gets the token under both names gh reads, and no host" do
    assert ForgeEnv.cli_env("github", "t0ken", "ignored.example.com") == %{
             "GH_TOKEN" => "t0ken",
             "GITHUB_TOKEN" => "t0ken"
           }
  end

  test "blank or missing values are left out rather than masking the daemon's" do
    assert ForgeEnv.cli_env("gitlab", nil, nil) == %{}
    assert ForgeEnv.cli_env("gitlab", "", "") == %{}
    assert ForgeEnv.cli_env("gitlab", "t0ken", "") == %{"GITLAB_TOKEN" => "t0ken", "GLAB_TOKEN" => "t0ken"}
    assert ForgeEnv.cli_env(nil, nil, nil) == %{}
  end
end
