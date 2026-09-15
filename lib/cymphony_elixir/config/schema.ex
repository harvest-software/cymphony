defmodule CymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule ExtraArgs do
    @moduledoc false
    # Per-kind pass-through CLI flags. Historically a single opaque string that
    # adapters append unescaped; the config store generates a list of strings so
    # each argument is escaped individually. Both shapes stay valid so a
    # hand-authored `WORKFLOW.md` written against the string form keeps parsing.
    use Ecto.Type

    @impl true
    def type, do: :any

    @impl true
    def cast(nil), do: {:ok, nil}
    def cast(value) when is_binary(value), do: {:ok, value}

    def cast(value) when is_list(value) do
      if Enum.all?(value, &is_binary/1), do: {:ok, value}, else: :error
    end

    def cast(_value), do: :error

    @impl true
    def load(value), do: {:ok, value}

    @impl true
    def dump(value), do: {:ok, value}
  end

  defmodule LenientBoolean do
    @moduledoc false
    # A boolean that refuses to take a project down over a typo. `true`/`false`
    # and the spellings Ecto's own `:boolean` accepts (`"true"`, `"false"`,
    # `"1"`, `"0"`) cast normally; anything else (`0`, `"no"`, `"off"`, `"yes"`)
    # is logged and cast to `nil`, which leaves the reader on its default rather
    # than failing `Schema.parse/1` and taking the whole project with it. Same
    # philosophy as `stall_timeout_ms` and `extra_args` in the config store.
    use Ecto.Type

    require Logger

    @true_values ["true", "1"]
    @false_values ["false", "0"]

    @impl true
    def type, do: :boolean

    @impl true
    def cast(value) when is_boolean(value), do: {:ok, value}
    def cast(nil), do: {:ok, nil}

    def cast(value) when is_binary(value) do
      downcased = String.downcase(value)

      cond do
        downcased in @true_values -> {:ok, true}
        downcased in @false_values -> {:ok, false}
        true -> ignore(value)
      end
    end

    def cast(value), do: ignore(value)

    @impl true
    def load(value), do: {:ok, value}

    @impl true
    def dump(value), do: {:ok, value}

    defp ignore(value) do
      Logger.warning("Ignoring invalid boolean in workflow config (expected true or false), got #{inspect(value)}")

      {:ok, nil}
    end
  end

  defmodule Forge do
    @moduledoc false
    # Which code-hosting platform the repository lives on. Drives the prompt's
    # vocabulary and CLI (`gh` + pull request vs `glab` + merge request) and
    # the SSH -> HTTPS clone-URL rewrite. Same philosophy as `LenientBoolean`:
    # an unrecognized value is logged and treated as unset rather than failing
    # `Schema.parse/1` and taking the project down over a typo.
    use Ecto.Type

    require Logger

    @kinds ["github", "gitlab"]

    @spec kinds() :: [String.t()]
    def kinds, do: @kinds

    @impl true
    def type, do: :string

    @impl true
    def cast(nil), do: {:ok, nil}

    def cast(value) when is_binary(value) do
      case value |> String.trim() |> String.downcase() do
        "" -> {:ok, nil}
        kind when kind in @kinds -> {:ok, kind}
        _ -> ignore(value)
      end
    end

    def cast(value), do: ignore(value)

    @impl true
    def load(value), do: {:ok, value}

    @impl true
    def dump(value), do: {:ok, value}

    defp ignore(value) do
      Logger.warning("Ignoring unknown forge in workflow config (expected one of #{Enum.join(@kinds, ", ")}), got #{inspect(value)}")

      {:ok, nil}
    end
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      # YouTrack keeps the workflow state in a *custom field*, and projects
      # rename it: the stock name is "State", but "Stage" is just as common.
      # Reading the wrong name yields `state: nil`, which silently never
      # dispatches, so it has to be configurable rather than assumed.
      field(:state_field, :string, default: "State")
      # The subset of `active_states` that means "queued, not started". The
      # dispatch transition and the blocker gate key off these, so a tracker
      # whose workflow does not use the word "Todo" (YouTrack ships
      # Open/In Progress/Fixed) can still be driven without renaming its
      # states. Defaults keep Linear's vocabulary.
      field(:queued_states, {:array, :string}, default: ["Todo"])
      # State to move an issue to when a run is dispatched. `nil`/blank skips
      # the transition entirely.
      field(:in_progress_state, :string, default: "In Progress")
      # Where the agent hands work to a human once the change is published.
      # Must NOT be in `active_states`, or agents re-dispatch onto issues that
      # are waiting on a reviewer.
      field(:review_state, :string, default: "Human Review")
      # The state meaning "approved, go merge". Blank means humans merge and
      # the agent's job ends at `review_state`; the prompt then omits the whole
      # land/merge protocol.
      field(:merge_state, :string, default: "Merging")
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
      # Restricts polling to one issue and its descendants, at any depth. The
      # root is included, so a leaf id scopes the run to that single issue.
      # Blank (the default) polls the whole project.
      field(:scope_issue, :string)
      # Tag/label marking an issue as a *container* for a feature branch rather
      # than work in its own right. Such an issue is never dispatched, and its
      # children cut their branches from it instead of from `base_branch`.
      # Blank disables both behaviours.
      field(:feature_branch_label, :string, default: "Feature Branch")
      # Custom field holding the release version, and the value of it that means
      # "branch off my parent". A second, explicit opt-in for a child whose
      # parent carries no container tag. YouTrack only; Linear has no
      # equivalent field and leaves it unset.
      field(:version_field, :string, default: "Version")
      field(:merge_to_parent_version, :string, default: "Merge to Parent Feature Branch")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :kind,
          :endpoint,
          :api_key,
          :project_slug,
          :assignee,
          :state_field,
          :queued_states,
          :in_progress_state,
          :review_state,
          :merge_state,
          :active_states,
          :terminal_states,
          :scope_issue,
          :feature_branch_label,
          :version_field,
          :merge_to_parent_version
        ],
        empty_values: []
      )
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "cymphony_workspaces"))
      field(:retention_days, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root, :retention_days], empty_values: [])
      |> validate_number(:retention_days, greater_than: 0)
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias CymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:kind, :string, default: "claude")
      field(:model, :string)
      field(:effort, :string)
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_retry_attempts, :integer, default: 30)
      field(:failure_state, :string)
      field(:max_concurrent_agents_by_state, :map, default: %{})
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :kind,
          :model,
          :effort,
          :max_concurrent_agents,
          :max_turns,
          :max_retry_backoff_ms,
          :max_retry_attempts,
          :failure_state,
          :max_concurrent_agents_by_state,
          :turn_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_inclusion(:kind, CymphonyElixir.Agent.known_kinds())
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> validate_number(:max_retry_attempts, greater_than: 0)
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Claude do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "claude")
      field(:permission_mode, :string, default: "acceptEdits")
      # Wider than the work-limiting `Bash,Read,Edit` this used to be: the
      # prompt asks the agent to create files and update its ticket, and under
      # headless `-p` an ungranted tool is not a prompt but a
      # `permission_denied`. Generated projects override this with a
      # tracker-aware list (`Cymphony.Defaults.claude_allowed_tools/1`); the
      # default here is for hand-authored WORKFLOW.md files, which cannot be
      # tracker-aware.
      field(:allowed_tools, :string, default: "Bash,Read,Edit,Write,Glob,Grep")
      field(:output_format, :string, default: "stream-json")
      field(:fallback_model, :string)
      field(:max_turns, :integer)
      field(:max_budget_usd, :decimal)
      field(:bare_mode, :boolean, default: true)
      field(:extra_args, CymphonyElixir.Config.Schema.ExtraArgs)
      field(:provider, :string)
      field(:providers, {:array, :string}, default: [])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :permission_mode,
          :allowed_tools,
          :output_format,
          :fallback_model,
          :max_turns,
          :max_budget_usd,
          :bare_mode,
          :extra_args,
          :provider,
          :providers
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_inclusion(:permission_mode, [
        "default",
        "acceptEdits",
        "plan",
        "auto",
        "dontAsk",
        "bypassPermissions"
      ])
      |> validate_inclusion(:output_format, ["text", "json", "stream-json"])
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex")
      field(:sandbox, :string, default: "workspace-write")
      field(:network_access, :boolean, default: true)
      field(:extra_args, CymphonyElixir.Config.Schema.ExtraArgs)
      field(:provider, :string)
      field(:providers, {:array, :string}, default: [])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:command, :sandbox, :network_access, :extra_args, :provider, :providers], empty_values: [])
      |> validate_required([:command])
      |> validate_inclusion(:sandbox, ["read-only", "workspace-write", "danger-full-access"])
    end
  end

  defmodule Antigravity do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "agy")
      field(:output_format, :string, default: "stream-json")
      field(:extra_args, CymphonyElixir.Config.Schema.ExtraArgs)
      field(:skip_permissions, :boolean, default: true)
      field(:sandbox, :boolean, default: false)
      field(:new_project, CymphonyElixir.Config.Schema.LenientBoolean, default: true)
      field(:print_timeout, :string)
      field(:provider, :string)
      field(:providers, {:array, :string}, default: [])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :output_format,
          :extra_args,
          :skip_permissions,
          :sandbox,
          :new_project,
          :print_timeout,
          :provider,
          :providers
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_inclusion(:output_format, ["text", "json", "stream-json"])
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  embedded_schema do
    # Top-level rather than a section of its own: one repository has one forge,
    # and both the prompt and the clone hook need it.
    field(:forge, Forge, default: "github")
    # Branch the agent creates for a run. A Liquid template rendered against
    # the issue, so `{{ issue.identifier }}` yields `HC-1`. Without an explicit
    # rule the agent invents a name every run ("HC-1-hello-world-static-page"),
    # which is neither predictable nor greppable.
    field(:branch_name_template, :string, default: "{{ issue.identifier }}")
    # Branch a run is cut from, and the branch its review targets, when the
    # issue has no parent. An issue *with* a parent branches off the parent's
    # branch instead — one level up only, so the chain composes as each parent
    # does the same. The prompt renders this as `origin/{{ base_branch }}`,
    # which used to be a hardcoded `origin/main` in six places.
    field(:base_branch, :string, default: "main")
    # Whether a review is opened set to squash-merge. GitLab only: squash is an
    # attribute of the merge request, set when it is opened, while GitHub picks
    # it at merge time (`gh pr merge --squash`) and has nothing to set. `false`
    # drops every squash instruction from the prompt and leaves the project's
    # own default alone. Lenient, like `new_project`: a typo must not take the
    # project down, and must not silently stop squashing either.
    field(:squash_merge, LenientBoolean, default: true)
    # Forge credentials, so the agent can drive `glab`/`gh`. The tracker's
    # credential already lives in config; the forge's had been shell-env only,
    # which meant it silently vanished whenever the daemon was started from a
    # shell that had not exported it. May be a literal or `$VAR_NAME`; falls
    # back to the environment variable the CLI itself reads.
    field(:forge_token, :string)
    # Instance host for a self-hosted forge, e.g. `gitlab.example.com`.
    # Without it `glab` talks to gitlab.com.
    field(:forge_host, :string)
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:claude, Claude, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:antigravity, Antigravity, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  @top_level_fields [:forge, :branch_name_template, :base_branch, :squash_merge, :forge_token, :forge_host]

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @top_level_fields, empty_values: [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:claude, with: &Claude.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:antigravity, with: &Antigravity.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
  end

  defp finalize_settings(settings) do
    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "cymphony_workspaces"))
    }

    # `Forge.cast/1` maps an unrecognized value to nil (logged, not fatal), and
    # a cast nil overwrites the field default — so the fallback lands here
    # rather than in the field definition.
    forge = settings.forge || "github"

    # No environment fallback here, deliberately. `Agent.Runner` already
    # inherits GH_TOKEN/GITHUB_TOKEN/GITLAB_TOKEN/GITLAB_HOST from the daemon
    # and overlays these on top, so a nil means "whatever the environment
    # says". Defaulting the field from the environment instead would collapse
    # independently-exported GH_TOKEN and GITHUB_TOKEN into one value. A
    # `$VAR_NAME` indirection still resolves.
    forge_token = resolve_secret_setting(settings.forge_token, nil)
    forge_host = resolve_secret_setting(settings.forge_host, nil)

    %{
      settings
      | tracker: tracker,
        workspace: workspace,
        forge: forge,
        forge_token: forge_token,
        forge_host: forge_host
    }
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, Regex.compile!("^[A-Za-z_][A-Za-z0-9_]*$")) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
