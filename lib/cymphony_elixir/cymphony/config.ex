defmodule CymphonyElixir.Cymphony.Config do
  @moduledoc false

  require Logger

  alias CymphonyElixir.Agent
  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Cymphony.Defaults

  @config_dir "~/.cymphony"
  # Tracker backends a generated `WORKFLOW.md` may name. "memory" is the test
  # adapter and deliberately not offered here.
  @tracker_kinds ["linear", "youtrack"]
  @config_file "config.json"
  @default_dashboard_refresh_seconds 3
  # Owner read/write only: config.json carries the Linear API key in cleartext.
  @file_mode 0o600

  @spec config_dir() :: String.t()
  def config_dir do
    case Application.get_env(:cymphony_elixir, :config_dir_override) do
      override when is_binary(override) -> override
      _ -> Path.expand(@config_dir)
    end
  end

  @spec config_path() :: String.t()
  def config_path, do: Path.join(config_dir(), @config_file)

  @spec exists?() :: boolean()
  def exists?, do: File.regular?(config_path())

  @spec load() :: {:ok, map()} | {:error, term()}
  def load do
    case File.read(config_path()) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, parsed} -> {:ok, normalize(parsed)}
          {:error, reason} -> {:error, "Invalid JSON in #{config_path()}: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to read #{config_path()}: #{inspect(reason)}"}
    end
  end

  @doc """
  Normalizes a config map into the multi-project format.

  Old flat format (no "projects" key) is converted to a single-element
  projects array with name derived from the linear_project_slug.
  """
  @spec normalize(map()) :: map()
  def normalize(%{"projects" => [_ | _]} = config), do: config

  def normalize(config) when is_map(config) do
    if Map.has_key?(config, "projects") do
      config
    else
      name = Map.get(config, "linear_project_slug", "default")
      project = Map.put(config, "name", name)
      Map.put(%{}, "projects", [project])
    end
  end

  @doc """
  Extracts the list of project configs from a normalized config map.
  """
  @spec projects(map()) :: [map()]
  def projects(%{"projects" => projects}) when is_list(projects), do: projects
  def projects(_config), do: []

  @doc """
  Finds a single project by name from a normalized config map.
  """
  @spec find_project(map(), String.t()) :: {:ok, map()} | {:error, :project_not_found}
  def find_project(config, project_name) when is_binary(project_name) do
    case Enum.find(projects(config), &(&1["name"] == project_name)) do
      nil -> {:error, :project_not_found}
      project -> {:ok, project}
    end
  end

  @doc """
  Resolves the shared Linear API key.

  Prefers a non-empty `config["linear_api_key"]`, then the first non-empty
  project `linear_api_key`, then `LINEAR_API_KEY`.
  """
  @spec resolve_linear_api_key(map() | nil) :: String.t() | nil
  def resolve_linear_api_key(nil), do: env_linear_api_key()

  def resolve_linear_api_key(config) when is_map(config) do
    file_linear_api_key(config) || env_linear_api_key()
  end

  @doc """
  Masks a Linear API key as `••••` plus the last 4 characters.

  Keys shorter than 4 characters (after trim) are entirely `••••` so the
  mask never encodes the key length.
  """
  @spec mask_linear_api_key(String.t()) :: String.t()
  def mask_linear_api_key(key) when is_binary(key) do
    trimmed = String.trim(key)

    if String.length(trimmed) < 4 do
      "••••"
    else
      "••••" <> String.slice(trimmed, -4, 4)
    end
  end

  @doc """
  Where `resolve_linear_api_key/1` would get a key from: the config file,
  the process environment, or nowhere.
  """
  @spec linear_key_source(map() | nil) :: :config | :env | nil
  def linear_key_source(nil) do
    if is_binary(env_linear_api_key()), do: :env, else: nil
  end

  def linear_key_source(config) when is_map(config) do
    cond do
      is_binary(file_linear_api_key(config)) -> :config
      is_binary(env_linear_api_key()) -> :env
      true -> nil
    end
  end

  @doc """
  Persists a shared Linear API key to `config.json` (created if missing).

  Sets the top-level `linear_api_key` and stamps the same value onto every
  `projects[]` entry. `save/1` keeps the file mode at `0o600`.
  """
  @spec put_linear_api_key(String.t()) :: {:ok, map()} | {:error, :empty | term()}
  def put_linear_api_key(key) when is_binary(key) do
    case String.trim(key) do
      "" -> {:error, :empty}
      trimmed -> persist_linear_api_key(trimmed)
    end
  end

  @doc """
  Appends a project to `config.json`, inheriting the shared Linear API key.
  """
  @spec add_project(map()) ::
          {:ok, map()}
          | {:error, :duplicate_name | :duplicate_slug | :not_connected | :invalid_project | term()}
  def add_project(attrs) when is_map(attrs) do
    with_write_lock(fn ->
      with {:ok, name} <- required_project_string(attrs, "name"),
           {:ok, slug} <- required_project_string(attrs, "linear_project_slug"),
           {:ok, config} <- load_or_empty_config(),
           {:ok, api_key} <- connected_linear_api_key(config),
           :ok <- reject_duplicate_project(config, name, slug) do
        project = build_added_project(attrs, name, slug, api_key)
        persist_added_project(config, project)
      end
    end)
  end

  defp persist_linear_api_key(key) do
    with_write_lock(fn ->
      with {:ok, config} <- load_or_empty_config() do
        save_stamped_linear_api_key(config, key)
      end
    end)
  end

  defp save_stamped_linear_api_key(config, key) do
    updated = stamp_linear_api_key(config, key)

    case save(updated) do
      :ok -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_added_project(config, project) do
    updated = Map.put(config, "projects", projects(config) ++ [project])

    case save(updated) do
      :ok -> {:ok, project}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_or_empty_config do
    case load() do
      {:ok, config} ->
        {:ok, config}

      {:error, reason} ->
        if exists?() do
          {:error, reason}
        else
          {:ok, %{"projects" => []}}
        end
    end
  end

  defp stamp_linear_api_key(config, key) do
    config
    |> Map.put("linear_api_key", key)
    |> stamp_projects_linear_key(key)
  end

  defp stamp_projects_linear_key(%{"projects" => projects} = config, key) when is_list(projects) do
    Map.put(config, "projects", Enum.map(projects, &Map.put(&1, "linear_api_key", key)))
  end

  defp stamp_projects_linear_key(config, _key), do: config

  defp file_linear_api_key(config) when is_map(config) do
    case present_string(Map.get(config, "linear_api_key")) do
      nil -> first_project_linear_api_key(projects(config))
      key -> key
    end
  end

  defp first_project_linear_api_key(project_list) do
    Enum.find_value(project_list, fn project ->
      present_string(Map.get(project, "linear_api_key"))
    end)
  end

  defp env_linear_api_key, do: present_string(System.get_env("LINEAR_API_KEY"))

  defp connected_linear_api_key(config) do
    case resolve_linear_api_key(config) do
      key when is_binary(key) -> {:ok, key}
      _ -> {:error, :not_connected}
    end
  end

  defp required_project_string(attrs, key) do
    case present_string(Map.get(attrs, key)) do
      nil -> {:error, :invalid_project}
      value -> {:ok, value}
    end
  end

  defp reject_duplicate_project(config, name, slug) do
    existing = projects(config)

    cond do
      Enum.any?(existing, &(present_string(&1["name"]) == name)) ->
        {:error, :duplicate_name}

      Enum.any?(existing, &(present_string(&1["linear_project_slug"]) == slug)) ->
        {:error, :duplicate_slug}

      true ->
        :ok
    end
  end

  defp build_added_project(attrs, name, slug, api_key) do
    %{
      "name" => name,
      "linear_project_slug" => slug,
      "linear_api_key" => api_key,
      "workspace_root" => added_workspace_root(attrs, name),
      "polling_interval_ms" => added_polling_interval_ms(attrs)
    }
    |> maybe_put_repo_url(attrs)
    |> maybe_put_agent(attrs)
    |> maybe_put_copied(attrs, "forge")
    |> maybe_put_copied(attrs, "model")
    |> maybe_put_copied(attrs, "effort")
    |> maybe_put_copied(attrs, "provider")
  end

  defp added_workspace_root(attrs, name) do
    case present_string(Map.get(attrs, "workspace_root")) do
      nil -> Path.join(Defaults.workspace_root(), name)
      root -> root
    end
  end

  defp added_polling_interval_ms(attrs) do
    case Map.get(attrs, "polling_interval_ms") do
      n when is_integer(n) and n > 0 -> n
      _ -> Defaults.polling_interval_ms()
    end
  end

  # Persist under the current key when the caller used it, and leave a
  # `github_repo_url`-only caller (the dashboard form, older API clients)
  # writing the legacy key it already writes. `repo_url/1` reads both.
  defp maybe_put_repo_url(map, attrs) do
    case present_string(Map.get(attrs, "repo_url")) do
      nil -> maybe_put_copied(map, attrs, "github_repo_url")
      value -> Map.put(map, "repo_url", value)
    end
  end

  defp maybe_put_copied(map, attrs, key) do
    case present_string(Map.get(attrs, key)) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp maybe_put_agent(map, attrs) do
    case present_string(Map.get(attrs, "agent")) do
      nil ->
        map

      kind ->
        if Agent.known_kind?(kind), do: Map.put(map, "agent", kind), else: map
    end
  end

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_value), do: nil

  @doc """
  Updates `max_concurrent_agents` for the named project (or for the entire
  legacy single-project config if `project_name` is `nil`) and persists to
  disk. Returns `{:ok, updated_config}` or an error tuple.
  """
  @spec update_concurrency(String.t() | nil, pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def update_concurrency(project_name, n) when is_integer(n) and n > 0 do
    with_write_lock(fn ->
      with {:ok, config} <- load(),
           {:ok, updated} <- apply_concurrency(config, project_name, n),
           :ok <- save(updated) do
        {:ok, updated}
      end
    end)
  end

  defp apply_concurrency(%{"projects" => projects} = config, project_name, n)
       when is_list(projects) do
    updated_projects =
      Enum.map(projects, fn project ->
        cond do
          is_nil(project_name) ->
            Map.put(project, "max_concurrent_agents", n)

          project["name"] == project_name ->
            Map.put(project, "max_concurrent_agents", n)

          true ->
            project
        end
      end)

    {:ok, Map.put(config, "projects", updated_projects)}
  end

  defp apply_concurrency(config, _project_name, n) when is_map(config) do
    {:ok, Map.put(config, "max_concurrent_agents", n)}
  end

  @doc """
  Persists the dispatch-pause flag for the named project (every project when
  `project_name` is `nil`) and saves to disk.

  Stored as the per-project boolean `"dispatch_paused"` so a paused project
  stays paused across a daemon restart — `Orchestrator.init/1` reads it back
  before the first poll tick. Returns `{:ok, updated_config}` or an error tuple.
  """
  @spec update_dispatch_paused(String.t() | nil, boolean()) ::
          {:ok, map()} | {:error, term()}
  def update_dispatch_paused(project_name, paused?) when is_boolean(paused?) do
    with_write_lock(fn ->
      with {:ok, config} <- load(),
           {:ok, updated} <- apply_dispatch_paused(config, project_name, paused?),
           :ok <- save(updated) do
        {:ok, updated}
      end
    end)
  end

  defp apply_dispatch_paused(%{"projects" => projects} = config, project_name, paused?)
       when is_list(projects) do
    updated_projects =
      Enum.map(projects, fn project ->
        if is_nil(project_name) or project["name"] == project_name do
          Map.put(project, "dispatch_paused", paused?)
        else
          project
        end
      end)

    {:ok, Map.put(config, "projects", updated_projects)}
  end

  defp apply_dispatch_paused(config, _project_name, paused?) when is_map(config) do
    {:ok, Map.put(config, "dispatch_paused", paused?)}
  end

  @doc """
  Reads back the persisted dispatch-pause flag for a project.

  Prefers the named project's `"dispatch_paused"` (or the sole project's when
  `project_name` is `nil`), falling back to the top-level key for a legacy flat
  config. Anything other than a stored `true` is `false`.
  """
  @spec dispatch_paused?(map(), String.t() | nil) :: boolean()
  def dispatch_paused?(config, project_name) when is_map(config) do
    case dispatch_paused_project(config, project_name) do
      {:ok, project} -> Map.get(project, "dispatch_paused") == true
      :error -> Map.get(config, "dispatch_paused") == true
    end
  end

  defp dispatch_paused_project(config, project_name) when is_binary(project_name) do
    case find_project(config, project_name) do
      {:ok, project} -> {:ok, project}
      {:error, :project_not_found} -> :error
    end
  end

  defp dispatch_paused_project(config, _project_name) do
    case projects(config) do
      [project] when is_map(project) -> {:ok, project}
      _ -> :error
    end
  end

  @doc """
  Dashboard payload refresh interval in seconds.

  Loads `config.json` and returns a positive integer. Missing or unreadable
  files, and any non-positive stored value, fall back to `3`.
  """
  @spec dashboard_refresh_seconds() :: pos_integer()
  def dashboard_refresh_seconds do
    case load() do
      {:ok, config} -> dashboard_refresh_seconds(config)
      _ -> @default_dashboard_refresh_seconds
    end
  end

  @doc """
  Normalizes a stored or in-memory refresh interval.

  A positive integer is returned as-is. A config map uses its top-level
  `dashboard_refresh_seconds` key. Anything else (including `0`, negatives,
  strings, and a missing key) is `3`.
  """
  @spec dashboard_refresh_seconds(term()) :: pos_integer()
  def dashboard_refresh_seconds(n) when is_integer(n) and n > 0, do: n

  def dashboard_refresh_seconds(config) when is_map(config) do
    dashboard_refresh_seconds(Map.get(config, "dashboard_refresh_seconds"))
  end

  def dashboard_refresh_seconds(_value), do: @default_dashboard_refresh_seconds

  @doc """
  Persists the daemon-wide dashboard payload refresh interval as a top-level
  `config.json` key (beside `projects`, never inside a project map).

  Requires an existing readable file, same as the other `update_*` helpers.
  Rejects non-positive values. Does not write `polling_interval_ms` or
  rewrite `WORKFLOW.md`.
  """
  @spec update_dashboard_refresh_seconds(term()) :: {:ok, map()} | {:error, term()}
  def update_dashboard_refresh_seconds(n) when is_integer(n) and n > 0 do
    with_write_lock(fn ->
      with {:ok, config} <- load(),
           updated = Map.put(config, "dashboard_refresh_seconds", n),
           :ok <- save(updated) do
        {:ok, updated}
      end
    end)
  end

  def update_dashboard_refresh_seconds(_n), do: {:error, :invalid_refresh_interval}

  @doc """
  Updates `provider` (head) and `providers` (full list) for the named project
  (or for all projects if `project_name` is `nil`) and persists to disk.
  Returns `{:ok, updated_config}` or an error tuple.
  """
  @spec update_providers(String.t() | nil, [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def update_providers(project_name, providers)
      when is_list(providers) and providers != [] do
    with_write_lock(fn ->
      with {:ok, config} <- load(),
           {:ok, updated} <- apply_providers(config, project_name, providers),
           :ok <- save(updated) do
        {:ok, updated}
      end
    end)
  end

  def update_providers(_project_name, _providers), do: {:error, :invalid_providers}

  defp apply_providers(%{"projects" => projects} = config, project_name, providers)
       when is_list(projects) do
    updated_projects =
      Enum.map(projects, fn project ->
        cond do
          is_nil(project_name) ->
            put_providers(project, providers)

          project["name"] == project_name ->
            put_providers(project, providers)

          true ->
            project
        end
      end)

    {:ok, Map.put(config, "projects", updated_projects)}
  end

  defp apply_providers(config, _project_name, providers) when is_map(config) do
    {:ok, put_providers(config, providers)}
  end

  defp put_providers(map, providers) do
    map
    |> Map.put("provider", hd(providers))
    |> Map.put("providers", providers)
  end

  @agent_setting_keys ["agent", "model", "effort"]

  @doc """
  Merges agent settings (`"agent"`, `"model"`, `"effort"`) onto the named
  project (or all projects when `project_name` is nil) and saves. Keys absent
  from `settings` are untouched; empty-string values delete the key.
  """
  @spec update_agent_settings(String.t() | nil, map()) ::
          :ok | {:error, :invalid_agent_kind | term()}
  def update_agent_settings(project_name, settings) when is_map(settings) do
    with_write_lock(fn ->
      with :ok <- validate_agent_kind(Map.get(settings, "agent")),
           {:ok, config} <- load(),
           {:ok, updated} <- apply_agent_settings(config, project_name, settings) do
        save(updated)
      end
    end)
  end

  defp validate_agent_kind(nil), do: :ok

  defp validate_agent_kind(kind) do
    if kind in Agent.known_kinds(), do: :ok, else: {:error, :invalid_agent_kind}
  end

  defp apply_agent_settings(%{"projects" => projects} = config, project_name, settings)
       when is_list(projects) do
    updated_projects =
      Enum.map(projects, fn project ->
        if project_name == nil or Map.get(project, "name") == project_name do
          merge_agent_settings(project, settings)
        else
          project
        end
      end)

    {:ok, Map.put(config, "projects", updated_projects)}
  end

  defp apply_agent_settings(config, _project_name, settings) when is_map(config) do
    {:ok, merge_agent_settings(config, settings)}
  end

  defp merge_agent_settings(map, settings) do
    Enum.reduce(@agent_setting_keys, map, fn key, acc ->
      case Map.fetch(settings, key) do
        {:ok, ""} -> Map.delete(acc, key)
        {:ok, value} when is_binary(value) -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  @queue_attr_keys ["queue_order", "queue_pins", "queue_priority_seen"]
  @queue_pin_field_keys ["agent_kind", "model", "effort"]

  @doc """
  Merges per-project dispatch-queue keys onto `config.json` and `save/1`s.

  Accepts any of `"queue_order"` (list of identifier binaries), `"queue_pins"`
  (identifier => `%{"agent_kind"|"model"|"effort" => binary}`), and
  `"queue_priority_seen"` (identifier => integer | nil). Empty pin fields and
  empty pin entries are dropped. Provided keys replace the stored value
  (`queue_pins` is the full map, not a per-id patch).

  `project_name` nil updates every `projects[]` entry (and a legacy flat map
  when `projects` is not a list). Does not rewrite `WORKFLOW.md` or touch
  `dashboard_refresh_seconds`.
  """
  @spec update_project_queue(String.t() | nil, map()) ::
          {:ok, map()} | {:error, :invalid_queue | term()}
  def update_project_queue(project_name, attrs)
      when (is_binary(project_name) or is_nil(project_name)) and is_map(attrs) do
    with_write_lock(fn ->
      with {:ok, sanitized} <- sanitize_queue_attrs(attrs),
           {:ok, config} <- load(),
           {:ok, updated} <- apply_project_queue(config, project_name, sanitized),
           :ok <- save(updated) do
        {:ok, updated}
      end
    end)
  end

  def update_project_queue(_project_name, _attrs), do: {:error, :invalid_queue}

  defp sanitize_queue_attrs(attrs) do
    Enum.reduce_while(@queue_attr_keys, {:ok, %{}}, &sanitize_queue_attr_step(&1, &2, attrs))
  end

  defp sanitize_queue_attr_step(key, {:ok, acc}, attrs) do
    case Map.fetch(attrs, key) do
      :error -> {:cont, {:ok, acc}}
      {:ok, value} -> put_sanitized_queue_attr(acc, key, value)
    end
  end

  defp put_sanitized_queue_attr(acc, key, value) do
    case sanitize_queue_attr(key, value) do
      {:ok, sanitized} -> {:cont, {:ok, Map.put(acc, key, sanitized)}}
      :error -> {:halt, {:error, :invalid_queue}}
    end
  end

  defp sanitize_queue_attr("queue_order", value), do: sanitize_queue_order(value)
  defp sanitize_queue_attr("queue_pins", value), do: sanitize_queue_pins(value)
  defp sanitize_queue_attr("queue_priority_seen", value), do: sanitize_queue_priority_seen(value)

  defp sanitize_queue_order(order) when is_list(order), do: collect_queue_ids(order)
  defp sanitize_queue_order(_order), do: :error

  defp sanitize_queue_pins(pins) when is_map(pins) do
    Enum.reduce_while(pins, {:ok, %{}}, &sanitize_queue_pin_step/2)
  end

  defp sanitize_queue_pins(_pins), do: :error

  defp sanitize_queue_pin_step({key, pin}, {:ok, acc}) do
    with {:ok, id} <- sanitize_queue_id(key),
         {:ok, fields} <- sanitize_pin_fields(pin) do
      {:cont, {:ok, put_present_pin(acc, id, fields)}}
    else
      :error -> {:halt, :error}
    end
  end

  defp put_present_pin(acc, _id, fields) when map_size(fields) == 0, do: acc
  defp put_present_pin(acc, id, fields), do: Map.put(acc, id, fields)

  defp sanitize_queue_priority_seen(seen) when is_map(seen) do
    Enum.reduce_while(seen, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, id} <- sanitize_queue_id(key),
           {:ok, priority} <- sanitize_seen_priority(value) do
        {:cont, {:ok, Map.put(acc, id, priority)}}
      else
        :error -> {:halt, :error}
      end
    end)
  end

  defp sanitize_queue_priority_seen(_seen), do: :error

  defp collect_queue_ids(values) do
    values
    |> Enum.reduce_while({:ok, []}, &collect_queue_id_step/2)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      :error -> :error
    end
  end

  defp collect_queue_id_step(value, {:ok, acc}) do
    case sanitize_queue_id(value) do
      {:ok, id} -> {:cont, {:ok, [id | acc]}}
      :error -> skip_or_halt_queue_id(value, acc)
    end
  end

  # A blank entry is dropped rather than rejecting the whole order, so a stray
  # empty string in `config.json` cannot make the queue unloadable.
  defp skip_or_halt_queue_id(value, acc) do
    if blank_queue_id?(value), do: {:cont, {:ok, acc}}, else: {:halt, :error}
  end

  defp blank_queue_id?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_queue_id?(_value), do: false

  defp sanitize_queue_id(key) when is_binary(key) do
    case String.trim(key) do
      "" -> :error
      trimmed -> {:ok, trimmed}
    end
  end

  defp sanitize_queue_id(_key), do: :error

  defp sanitize_pin_fields(pin) when is_map(pin) do
    fields =
      Enum.reduce(@queue_pin_field_keys, %{}, fn key, acc ->
        case pin_field_value(pin, key) do
          value when is_binary(value) -> put_present_pin_field(acc, key, value)
          _ -> acc
        end
      end)

    {:ok, fields}
  end

  defp sanitize_pin_fields(_pin), do: :error

  defp pin_field_value(pin, "agent_kind") do
    binary_pin_value(pin, ["agent_kind", :agent_kind, "kind", :kind])
  end

  defp pin_field_value(pin, "model"), do: binary_pin_value(pin, ["model", :model])
  defp pin_field_value(pin, "effort"), do: binary_pin_value(pin, ["effort", :effort])

  defp binary_pin_value(pin, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(pin, key) do
        value when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp put_present_pin_field(acc, key, value) do
    case String.trim(value) do
      "" -> acc
      "keep" -> acc
      trimmed -> Map.put(acc, key, trimmed)
    end
  end

  defp sanitize_seen_priority(value) when is_integer(value) or is_nil(value), do: {:ok, value}
  defp sanitize_seen_priority(_value), do: :error

  defp apply_project_queue(%{"projects" => projects} = config, project_name, attrs)
       when is_list(projects) do
    updated_projects =
      Enum.map(projects, fn project ->
        cond do
          is_nil(project_name) ->
            put_queue_attrs(project, attrs)

          project["name"] == project_name ->
            put_queue_attrs(project, attrs)

          true ->
            project
        end
      end)

    {:ok, Map.put(config, "projects", updated_projects)}
  end

  defp apply_project_queue(config, _project_name, attrs) when is_map(config) do
    {:ok, put_queue_attrs(config, attrs)}
  end

  defp put_queue_attrs(project, attrs) do
    Enum.reduce(attrs, project, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end

  @doc """
  Parses a comma-separated provider list into a normalized list of names.
  Trims whitespace and drops empty segments. Returns `{:error, :empty}` if no
  non-empty segments remain.
  """
  @spec parse_providers_csv(String.t()) :: {:ok, [String.t()]} | {:error, :empty}
  def parse_providers_csv(value) when is_binary(value) do
    list =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if list == [], do: {:error, :empty}, else: {:ok, list}
  end

  def parse_providers_csv(_), do: {:error, :empty}

  @doc """
  Writes `config` to `config.json` at mode `0600`.

  Staged through a sibling temp file that is chmod'd while still empty and then
  renamed over the target, the same treatment `WorkflowGenerator.write/2` gives
  the generated `WORKFLOW.md`:

    * the Linear API key the file carries in cleartext is never on disk under a
      umask-derived mode, not even for the width of one `File.write/2`;
    * the rename is atomic, so a concurrent reader (`Orchestrator.init/1`
      seeding its persisted pause flag, another `update_*` load) never observes
      a truncated or half-written config, and a failed write leaves the
      previous file intact.
  """
  @spec save(map()) :: :ok | {:error, term()}
  def save(config) do
    dir = config_dir()

    with :ok <- File.mkdir_p(dir),
         {:ok, json} <- Jason.encode(config, pretty: true) do
      write_atomically(config_path(), json)
    end
  end

  # Serializes one `load → modify → save` against every other one on the node.
  #
  # The writers do not share a process: the dashboard LiveView, the JSON API
  # controller, and each project's Orchestrator (which persists `queue_order` /
  # `queue_priority_seen` from its poll tick whenever the waiting set moves) all
  # run the sequence themselves. Interleaved, the later `save/1` writes back a
  # config it loaded before the earlier one — silently dropping a freshly
  # persisted `dispatch_paused` (the daemon stays paused in memory, so nothing
  # looks wrong until the next restart resumes it) or a drag-reordered queue.
  #
  # `:global.trans/2` retries forever rather than returning `:aborted`, and
  # `:global` drops the locks of a process that dies holding one, so the only
  # outcome is the wrapped function's own result.
  defp with_write_lock(fun) do
    :global.trans({{__MODULE__, :config_write}, self()}, fun)
  end

  defp write_atomically(path, json) do
    staged = "#{path}.tmp-#{:erlang.unique_integer([:positive])}"

    with :ok <- File.write(staged, ""),
         :ok <- File.chmod(staged, @file_mode),
         :ok <- File.write(staged, json),
         :ok <- File.rename(staged, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(staged)
        {:error, "Failed to write #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Builds the Schema-shaped (nested, string-keyed) runtime config map for a
  project from its flat `config.json` representation, applying `Defaults`.

  This is the structured replacement for the old hand-built YAML string: the
  generator serializes this map (as JSON, which is valid YAML) into the
  `WORKFLOW.md` front matter, so values containing YAML metacharacters (`:`,
  `#`, quotes, newlines) round-trip safely and missing keys get explicit
  defaults rather than silently becoming Schema fallbacks.
  """
  @spec to_schema_map(map()) :: map()
  def to_schema_map(config) when is_map(config) do
    base = %{
      "tracker" => tracker_map(config),
      "polling" => %{
        "interval_ms" => Map.get(config, "polling_interval_ms", Defaults.polling_interval_ms())
      },
      "workspace" => %{
        "root" => Map.get(config, "workspace_root", Defaults.workspace_root())
      },
      "agent" => %{
        "kind" => agent_kind(config),
        "model" => Map.get(config, "model"),
        "effort" => Map.get(config, "effort"),
        "max_concurrent_agents" => Map.get(config, "max_concurrent_agents", Defaults.max_concurrent_agents()),
        "max_turns" => Defaults.max_turns(),
        "stall_timeout_ms" => stall_timeout_ms(config)
      },
      "claude" => agent_section_map(config, "claude"),
      "codex" => agent_section_map(config, "codex"),
      "antigravity" => agent_section_map(config, "antigravity")
    }

    base
    |> Map.put("forge", forge(config))
    |> Map.put("branch_name_template", tracker_state(config, "branch_name_template", Defaults.branch_name_template()))
    |> Map.put("base_branch", tracker_state(config, "base_branch", Defaults.base_branch()))
    |> maybe_put_squash_merge(config)
    |> maybe_put_string(config, "forge_token", "forge_token")
    |> maybe_put_string(config, "forge_host", "forge_host")
    |> maybe_put_server(config)
    |> maybe_put_observability(config)
    |> maybe_put_hooks(config)
  end

  # The status TUI repaints the whole terminal on its tick, which is right for
  # a daemon an operator is watching and wrong for anything reading stdout as
  # a log stream (a container, a systemd unit). Only an explicit `false`
  # disables it, so a typo cannot silently take the TUI away.
  defp maybe_put_observability(base, config) do
    case Map.get(config, "status_dashboard_enabled") do
      false -> Map.put(base, "observability", %{"dashboard_enabled" => false})
      _ -> base
    end
  end

  # The tracker section stays Linear-shaped by default so every existing
  # `config.json` generates byte-identical front matter. A project only leaves
  # that shape when it explicitly names another `tracker_kind`.
  defp tracker_map(config) do
    %{
      "kind" => tracker_kind(config),
      "api_key" => tracker_string(config, "tracker_api_key", "linear_api_key"),
      "project_slug" => tracker_string(config, "tracker_project_slug", "linear_project_slug"),
      "state_field" => tracker_state(config, "state_field", Defaults.state_field()),
      "queued_states" => state_list(config, "queued_states", Defaults.queued_states()),
      "in_progress_state" => tracker_state(config, "in_progress_state", Defaults.in_progress_state()),
      "review_state" => tracker_state(config, "review_state", Defaults.review_state()),
      "merge_state" => tracker_state(config, "merge_state", Defaults.merge_state()),
      "active_states" => state_list(config, "active_states", Defaults.active_states()),
      "terminal_states" => state_list(config, "terminal_states", Defaults.terminal_states()),
      # `tracker_state/3` and not `maybe_put_string/4`: a blank value here is
      # meaningful (it switches the container rule off) and must survive into
      # the front matter rather than being dropped back to the default.
      "feature_branch_label" => tracker_state(config, "feature_branch_label", Defaults.feature_branch_label()),
      "version_field" => tracker_state(config, "version_field", Defaults.version_field()),
      "merge_to_parent_version" => tracker_state(config, "merge_to_parent_version", Defaults.merge_to_parent_version())
    }
    |> maybe_put_string(config, "endpoint", "tracker_endpoint")
    |> maybe_put_string(config, "assignee", "tracker_assignee")
    |> maybe_put_string(config, "scope_issue", "scope_issue")
  end

  # Which code-hosting platform the repo lives on. Drives the prompt's CLI and
  # vocabulary (`gh`/pull request vs `glab`/merge request). An unknown value
  # warns and falls back rather than generating front matter that would fail
  # `Schema.parse/1`; the schema is lenient about it too, but a typo caught
  # here names the file the operator actually edits.
  defp forge(config) do
    case Map.get(config, "forge") do
      nil ->
        Defaults.forge()

      value when is_binary(value) ->
        normalized = value |> String.trim() |> String.downcase()

        if normalized in Schema.Forge.kinds() do
          normalized
        else
          warn_unknown_forge(value)
        end

      other ->
        warn_unknown_forge(other)
    end
  end

  defp warn_unknown_forge(value) do
    Logger.warning("Ignoring unknown forge in config.json: #{inspect(value)} (using #{Defaults.forge()})")

    Defaults.forge()
  end

  # An unknown kind falls back to Linear *and says so*: unlike a numeric typo
  # this one is otherwise invisible, and a silently-Linear project polls the
  # wrong tracker forever.
  defp tracker_kind(config) do
    case Map.get(config, "tracker_kind") do
      nil ->
        "linear"

      kind when kind in @tracker_kinds ->
        kind

      other ->
        Logger.warning("Ignoring unknown tracker_kind in config.json: #{inspect(other)} (using \"linear\")")

        "linear"
    end
  end

  # Workflow state names are tracker-specific — YouTrack's stock workflow is
  # Submitted/Open/In Progress/Fixed, nothing like Linear's Todo/In Progress —
  # so a project must be able to name its own. Only a non-empty list of
  # non-blank strings is honored; anything else warns and keeps the default,
  # because a mistyped state list either polls nothing or (for
  # `terminal_states`) treats finished work as still running.
  defp state_list(config, key, default) do
    case Map.get(config, key) do
      nil ->
        default

      value ->
        case normalize_state_list(value) do
          [] ->
            Logger.warning("Ignoring invalid #{key} in config.json: #{inspect(value)}")

            default

          states ->
            states
        end
    end
  end

  # An explicit empty string is meaningful for all three: it turns off the
  # dispatch transition, the review handoff, or the agent-merge flow for a
  # workflow that has no such state. Any non-string falls back to the default.
  defp tracker_state(config, key, default) do
    case Map.get(config, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> default
    end
  end

  defp normalize_state_list(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      value |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
    else
      []
    end
  end

  defp normalize_state_list(_value), do: []

  defp tracker_string(config, key, legacy_key) do
    case Map.get(config, key) do
      value when is_binary(value) and value != "" -> value
      _ -> Map.get(config, legacy_key, "")
    end
  end

  # Bind address for the dashboard/API. The Schema default (`127.0.0.1`) is
  # right for a daemon on a laptop and wrong inside a container, where the
  # port has to be reachable from outside the network namespace — so this is
  # emitted only when a project asks for it.
  defp maybe_put_server(base, config) do
    server =
      %{}
      |> maybe_put_string(config, "host", "server_host")
      |> maybe_put_port(config)

    if server == %{}, do: base, else: Map.put(base, "server", server)
  end

  defp maybe_put_port(server, config) do
    case Map.get(config, "server_port") do
      value when is_integer(value) and value >= 0 -> Map.put(server, "port", value)
      _ -> server
    end
  end

  defp maybe_put_string(section, config, field, key) do
    case Map.get(config, key) do
      value when is_binary(value) -> put_trimmed(section, field, String.trim(value))
      _ -> section
    end
  end

  defp put_trimmed(section, _field, ""), do: section
  defp put_trimmed(section, field, value), do: Map.put(section, field, value)

  defp agent_kind(config) do
    kind = Map.get(config, "agent")
    if kind in Agent.known_kinds(), do: kind, else: Defaults.agent_kind()
  end

  # Only a positive integer is honored. A missing key, `0`, a negative number, a
  # float or a stringified number falls back to the schema default rather than
  # generating an out-of-range front-matter value: a typo must not silently
  # disable the stall watchdog (`stall_timeout_ms <= 0` turns it off) or fail
  # `Schema.parse/1` and take the whole project down.
  defp stall_timeout_ms(config) do
    case Map.get(config, "stall_timeout_ms") do
      value when is_integer(value) and value > 0 -> value
      _ -> Defaults.stall_timeout_ms()
    end
  end

  defp agent_section_map(config, "claude") do
    %{
      "command" => Defaults.claude_command(),
      "output_format" => Defaults.output_format(),
      "allowed_tools" => allowed_tools(config),
      "permission_mode" => permission_mode(config)
    }
    |> maybe_put_bare_mode(config)
    |> maybe_put_provider_keys(config, "claude")
    |> maybe_put_extra_args(config, "claude")
  end

  # `--allowedTools`. Emitted rather than left to the Schema default because
  # the default cannot know the tracker: an agent required by its prompt to
  # update a ticket needs that tracker's MCP tools granted, and under `-p`
  # there is no one to approve them interactively — the call just returns
  # `permission_denied` and the run works around it with shell, spending turns.
  #
  # A `projects[]` entry may override with a list or a comma-separated string.
  # Anything else is ignored and warned about, like `extra_args`: a mistyped
  # grant is invisible until an agent is silently refused a tool.
  defp allowed_tools(config) do
    case Map.get(config, "allowed_tools") do
      nil ->
        Enum.join(Defaults.claude_allowed_tools(tracker_kind(config)), ",")

      value when is_binary(value) ->
        if String.trim(value) == "",
          do: Enum.join(Defaults.claude_allowed_tools(tracker_kind(config)), ","),
          else: value

      value when is_list(value) ->
        if Enum.all?(value, &is_binary/1) do
          Enum.join(value, ",")
        else
          warn_invalid("allowed_tools", value)
          Enum.join(Defaults.claude_allowed_tools(tracker_kind(config)), ",")
        end

      value ->
        warn_invalid("allowed_tools", value)
        Enum.join(Defaults.claude_allowed_tools(tracker_kind(config)), ",")
    end
  end

  defp permission_mode(config) do
    case Map.get(config, "permission_mode") do
      value when is_binary(value) ->
        if String.trim(value) == "", do: Defaults.claude_permission_mode(), else: value

      nil ->
        Defaults.claude_permission_mode()

      value ->
        warn_invalid("permission_mode", value)
        Defaults.claude_permission_mode()
    end
  end

  defp warn_invalid(key, value) do
    Logger.warning("Ignoring invalid #{key} in config.json: #{inspect(value)}")
  end

  defp agent_section_map(config, "codex") do
    %{"command" => Defaults.codex_command(), "sandbox" => Defaults.codex_sandbox()}
    |> maybe_put_provider_keys(config, "codex")
    |> maybe_put_extra_args(config, "codex")
  end

  defp agent_section_map(config, "antigravity") do
    %{
      "command" => Defaults.antigravity_command(),
      "output_format" => "stream-json",
      "skip_permissions" => true
    }
    |> maybe_put_new_project(config)
    |> maybe_put_provider_keys(config, "antigravity")
    |> maybe_put_extra_args(config, "antigravity")
  end

  # `claude --bare` skips "keychain reads" among other things, so a session
  # authenticated as a Claude Code *account* (rather than by an
  # `ANTHROPIC_API_KEY` a provider exports) fails with
  # "Not logged in · Please run /login". `bare_mode` is on by the schema
  # default, so account auth needs an explicit `false` — and only an explicit
  # `false`, so a typo cannot silently take the fast path away from every
  # API-key project.
  defp maybe_put_bare_mode(section, config) do
    case Map.get(config, "claude_bare_mode") do
      false -> Map.put(section, "bare_mode", false)
      _ -> section
    end
  end

  # Squashing is on by default, so only an explicit `false` needs to reach the
  # front matter. Anything else (missing, `"false"`, `0`) keeps squashing: a
  # typo here silently lands every sub-task as a string of commits on its
  # parent branch, which is exactly what the epic workflow is trying to avoid.
  defp maybe_put_squash_merge(base, config) do
    case Map.get(config, "squash_merge") do
      false -> Map.put(base, "squash_merge", false)
      _ -> base
    end
  end

  # `--new-project` is on by default in the adapter, so only an explicit `false`
  # needs to reach the front matter. Anything else (missing, `"false"`, `0`)
  # keeps the default rather than silently sandboxing agy back into
  # ~/.gemini/antigravity-cli/scratch.
  defp maybe_put_new_project(section, config) do
    case Map.get(config, "new_project") do
      false -> Map.put(section, "new_project", false)
      _ -> section
    end
  end

  # Providers are auth aliases for a specific backend: they belong to the
  # active kind's section only.
  defp maybe_put_provider_keys(section, config, kind) do
    if agent_kind(config) == kind do
      providers = Map.get(config, "providers", [])
      provider = Map.get(config, "provider")

      cond do
        is_list(providers) and providers != [] ->
          section
          |> Map.put("providers", providers)
          |> Map.put("provider", hd(providers))

        is_binary(provider) and provider != "" ->
          Map.put(section, "provider", provider)

        true ->
          section
      end
    else
      section
    end
  end

  # Extra CLI args are per-kind pass-through flags, so — like providers — they
  # belong to the active kind's section only: a project pinned to `codex` must
  # not inherit the `antigravity` list.
  #
  # Two accepted shapes on a `projects[]` entry:
  #
  #   "extra_args": {"antigravity": ["--new-project"], "codex": ["--full-auto"]}
  #   "extra_args": ["--new-project"]      # convenience form, active kind
  #
  # Only a list of strings is honored. Mirroring `stall_timeout_ms`, anything
  # else is ignored rather than written into front matter that would fail
  # `Schema.parse/1` and take the whole project down — but unlike a numeric
  # typo, a mistyped escape hatch is invisible, so it is logged.
  defp maybe_put_extra_args(section, config, kind) do
    if agent_kind(config) == kind do
      case extra_args(config, kind) do
        [] -> section
        args -> Map.put(section, "extra_args", args)
      end
    else
      section
    end
  end

  defp extra_args(config, kind) do
    case Map.get(config, "extra_args") do
      nil -> []
      by_kind when is_map(by_kind) -> by_kind |> Map.get(kind) |> kind_extra_args()
      value -> string_list_or_warn(value)
    end
  end

  # A map with no entry for the active kind is the normal case, not a mistake.
  defp kind_extra_args(nil), do: []
  defp kind_extra_args(value), do: string_list_or_warn(value)

  defp string_list_or_warn(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: value, else: warn_invalid_extra_args(value)
  end

  defp string_list_or_warn(value), do: warn_invalid_extra_args(value)

  defp warn_invalid_extra_args(value) do
    Logger.warning(
      "Ignoring invalid extra_args in config.json: expected a list of strings, " <>
        "or a map of agent kind to list of strings, got #{inspect(value)}"
    )

    []
  end

  defp maybe_put_hooks(base, config) do
    clone = clone_hook(config)
    operator = operator_hooks(config)

    hooks =
      operator
      |> Map.delete("after_create")
      |> maybe_put_after_create(clone, Map.get(operator, "after_create"))

    if hooks == %{}, do: base, else: Map.put(base, "hooks", hooks)
  end

  defp clone_hook(config) do
    case repo_url(config) do
      "" ->
        nil

      repo ->
        clone_url = if rewrite_ssh_remote?(config), do: https_clone_url(repo), else: repo
        clone_command(clone_url)
    end
  end

  # An operator `after_create` runs *after* the generated clone and only when
  # the clone succeeded: it is there to prepare a checkout, and there is no
  # checkout to prepare until the clone has populated the workspace.
  defp maybe_put_after_create(hooks, nil, nil), do: hooks
  defp maybe_put_after_create(hooks, clone, nil), do: Map.put(hooks, "after_create", clone)
  defp maybe_put_after_create(hooks, nil, extra), do: Map.put(hooks, "after_create", extra)

  defp maybe_put_after_create(hooks, clone, extra) do
    Map.put(hooks, "after_create", "{\n#{clone}} && {\n#{extra}\n}\n")
  end

  @hook_commands ~w(after_create before_run after_run before_remove)

  # `hooks` on a `projects[]` entry, hand-edited like `extra_args`:
  #
  #   "hooks": {"before_run": "bash scripts/agent-stack.sh prepare",
  #             "before_remove": "bash scripts/agent-stack.sh remove",
  #             "timeout_ms": 600000}
  #
  # Commands must be non-blank strings and `timeout_ms` a positive integer.
  # Anything else — including an unknown key — is dropped and warned about: a
  # mistyped hook otherwise never runs and nothing says why, and an invalid
  # value written into the front matter would fail `Schema.parse/1` and take
  # the project down.
  defp operator_hooks(config) do
    case Map.get(config, "hooks") do
      nil ->
        %{}

      hooks when is_map(hooks) ->
        Enum.reduce(hooks, %{}, fn {key, value}, acc -> put_operator_hook(acc, key, value) end)

      other ->
        Logger.warning("Ignoring invalid hooks in config.json: expected an object, got #{inspect(other)}")
        %{}
    end
  end

  defp put_operator_hook(acc, key, value) when key in @hook_commands do
    if is_binary(value) and String.trim(value) != "" do
      Map.put(acc, key, value)
    else
      warn_invalid_hook(key, value)
      acc
    end
  end

  defp put_operator_hook(acc, "timeout_ms", value) when is_integer(value) and value > 0 do
    Map.put(acc, "timeout_ms", value)
  end

  defp put_operator_hook(acc, key, value) do
    warn_invalid_hook(key, value)
    acc
  end

  defp warn_invalid_hook(key, value) do
    Logger.warning("Ignoring invalid hooks.#{key} in config.json: #{inspect(value)}")
  end

  # The base branch is per *issue* (an issue branches off its parent's branch)
  # while this hook is generated per *project*, so it cannot be interpolated
  # here — `Workspace` exports it to the hook as `CYMPHONY_BASE_BRANCH`.
  #
  # The `||` fallback covers a parent branch that does not exist on the remote
  # yet, which is the normal state of affairs for the first sub-task of a new
  # parent: clone the default branch instead and let the prompt tell the agent
  # to create and push the base branch.
  defp clone_command(clone_url) do
    """
    if [ -n "${CYMPHONY_BASE_BRANCH:-}" ]; then
      git clone --depth 1 --branch "$CYMPHONY_BASE_BRANCH" #{clone_url} . || git clone --depth 1 #{clone_url} .
    else
      git clone --depth 1 #{clone_url} .
    fi
    """
  end

  @doc """
  The project's repository URL: `repo_url`, else the legacy `github_repo_url`.

  The key was named for GitHub before GitLab was supported; both are read so
  existing `config.json` files keep working and neither the dashboard's
  add-project form nor `POST /api/v1/projects` has to change.
  """
  @spec repo_url(map()) :: String.t()
  def repo_url(config) when is_map(config) do
    ["repo_url", "github_repo_url"]
    |> Enum.find_value("", fn key ->
      case Map.get(config, key) do
        value when is_binary(value) -> nonblank(String.trim(value))
        _ -> nil
      end
    end)
  end

  defp nonblank(""), do: nil
  defp nonblank(value), do: value

  # Rewriting an scp-style remote to HTTPS is right when the worker has no key
  # of its own (a host SSH key is often a deploy key for a different repo), and
  # wrong when the worker *is* the operator — a rootless-podman run mounts the
  # invoker's `~/.ssh` and agent socket, so an SSH remote is the path of least
  # resistance and forcing HTTPS demands a token they may not have. Only an
  # explicit `false` opts out, matching `new_project` and `claude_bare_mode`.
  defp rewrite_ssh_remote?(config), do: Map.get(config, "rewrite_ssh_remote") != false

  @doc """
  The project's tracker slug: `tracker_project_slug`, else `linear_project_slug`.

  Same legacy pairing as `repo_url/1` — the key was named for Linear before
  YouTrack was supported.
  """
  @spec project_slug(map()) :: String.t()
  def project_slug(config) when is_map(config) do
    ["tracker_project_slug", "linear_project_slug"]
    |> Enum.find_value("", fn key ->
      case Map.get(config, key) do
        value when is_binary(value) -> nonblank(String.trim(value))
        _ -> nil
      end
    end)
  end

  @doc """
  Rewrites an `scp`-style SSH remote to its HTTPS equivalent.

  Prefer HTTPS so the clone uses `gh`/`glab` credentials or the git credential
  helper. A host SSH key is often a deploy key for a different repository; the
  forge then reports "Repository not found" and the workspace stays empty.

  Host-agnostic on purpose — `git@gitlab.example.com:group/subgroup/repo.git`
  is as valid a remote as `git@github.com:owner/repo.git`, and self-hosted
  GitLab is the common case. Anything that is not scp-style (an `https://` or
  `ssh://` URL, a local path) is passed through untouched.
  """
  @spec https_clone_url(String.t()) :: String.t()
  def https_clone_url(repo) when is_binary(repo) do
    trimmed = String.trim(repo)

    case Regex.run(Regex.compile!("^git@([A-Za-z0-9._-]+):(.+?)(?:\\.git)?$"), trimmed) do
      [_, host, path] -> "https://#{host}/#{path}.git"
      _ -> trimmed
    end
  end
end
