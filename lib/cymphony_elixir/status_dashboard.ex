defmodule CymphonyElixir.StatusDashboard do
  @moduledoc """
  Renders a status snapshot for orchestrator and worker activity as a terminal UI.
  """

  use GenServer
  require Logger

  alias CymphonyElixir.{Config, HttpServer, Text}
  alias CymphonyElixir.Cymphony.UrlFile
  alias CymphonyElixir.Orchestrator
  alias CymphonyElixirWeb.ObservabilityPubSub

  @minimum_idle_rerender_ms 1_000
  @throughput_window_ms 5_000
  @throughput_graph_window_ms 10 * 60 * 1000
  @throughput_graph_columns 24
  @sparkline_blocks ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
  # Claude Code `stream-json` event types. They carry {"type": "…"} like
  # Codex's JSONL, so without their own humanizer every Claude event rendered
  # as its bare type ("assistant", "user") and a tool call — `Skill` included —
  # was indistinguishable from any other activity.
  @claude_stream_types ["system", "assistant", "user", "result"]
  @running_id_width 8
  @running_stage_width 14
  @running_pid_width 8
  @running_age_width 12
  @running_tokens_width 10
  @running_session_width 14
  @running_event_default_width 44
  @running_event_min_width 12
  @running_row_chrome_width 10
  @default_terminal_columns 115

  @ansi_reset IO.ANSI.reset()
  @ansi_bold IO.ANSI.bright()
  @ansi_blue IO.ANSI.blue()
  @ansi_cyan IO.ANSI.cyan()
  @ansi_dim IO.ANSI.faint()
  @ansi_green IO.ANSI.green()
  @ansi_red IO.ANSI.red()
  @ansi_orange IO.ANSI.yellow()
  @ansi_yellow IO.ANSI.yellow()
  @ansi_magenta IO.ANSI.magenta()
  @ansi_gray IO.ANSI.light_black()

  defstruct [
    :refresh_ms,
    :enabled,
    :render_interval_ms,
    :refresh_ms_override,
    :enabled_override,
    :render_interval_ms_override,
    :render_fun,
    :token_samples,
    :last_tps_second,
    :last_tps_value,
    :last_rendered_content,
    :last_rendered_at_ms,
    :pending_content,
    :flush_timer_ref,
    :last_snapshot_fingerprint,
    suspended: false
  ]

  @type t :: %__MODULE__{
          refresh_ms: pos_integer(),
          enabled: boolean(),
          render_interval_ms: pos_integer(),
          refresh_ms_override: pos_integer() | nil,
          enabled_override: boolean() | nil,
          render_interval_ms_override: pos_integer() | nil,
          render_fun: (String.t() -> term()),
          token_samples: [{integer(), integer()}],
          last_tps_second: integer() | nil,
          last_tps_value: float() | nil,
          last_rendered_content: String.t() | nil,
          last_rendered_at_ms: integer() | nil,
          pending_content: String.t() | nil,
          flush_timer_ref: reference() | nil,
          last_snapshot_fingerprint: term() | nil,
          suspended: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec notify_update(GenServer.name()) :: :ok
  def notify_update(server \\ __MODULE__) do
    ObservabilityPubSub.broadcast_update()

    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        send(pid, :refresh)
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Stop rendering to the terminal until `resume/1` — used while an interactive
  prompt (onboarding wizard) owns the tty, so the status box doesn't clear
  the screen mid-dialog. No-op when the dashboard isn't running.
  """
  @spec suspend(GenServer.name()) :: :ok
  def suspend(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> GenServer.call(pid, :suspend)
      _ -> :ok
    end
  end

  @doc "Re-enable terminal rendering after `suspend/1`."
  @spec resume(GenServer.name()) :: :ok
  def resume(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> GenServer.call(pid, :resume)
      _ -> :ok
    end
  end

  @spec init(keyword()) :: {:ok, t()}
  def init(opts) do
    refresh_ms_override = keyword_override(opts, :refresh_ms)
    enabled_override = keyword_override(opts, :enabled)
    render_interval_ms_override = keyword_override(opts, :render_interval_ms)
    observability = observability_settings()
    refresh_ms = refresh_ms_override || observability.refresh_ms
    render_interval_ms = render_interval_ms_override || observability.render_interval_ms
    render_fun = Keyword.get(opts, :render_fun, &render_to_terminal/1)
    enabled = resolve_override(enabled_override, observability.dashboard_enabled and dashboard_enabled?())
    schedule_tick(refresh_ms, enabled)

    {:ok,
     %__MODULE__{
       refresh_ms: refresh_ms,
       enabled: enabled,
       render_interval_ms: render_interval_ms,
       refresh_ms_override: refresh_ms_override,
       enabled_override: enabled_override,
       render_interval_ms_override: render_interval_ms_override,
       render_fun: render_fun,
       token_samples: [],
       last_tps_second: nil,
       last_tps_value: nil,
       last_rendered_content: nil,
       last_rendered_at_ms: nil,
       pending_content: nil,
       flush_timer_ref: nil,
       last_snapshot_fingerprint: nil
     }}
  end

  @spec render_offline_status() :: :ok
  def render_offline_status do
    content =
      [
        colorize("╭─ CYMPHONY STATUS", @ansi_bold),
        colorize("│ app_status=offline", @ansi_red),
        closing_border()
      ]
      |> Enum.join("\n")

    render_to_terminal(content)
    :ok
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Failed rendering offline status: #{Exception.message(error)}")
      :ok
  end

  @spec handle_call(:suspend | :resume, GenServer.from(), t()) :: {:reply, :ok, t()}
  def handle_call(:suspend, _from, state) do
    {:reply, :ok, %{state | suspended: true}}
  end

  def handle_call(:resume, _from, state) do
    # Force a repaint on the next render: the prompt owned the screen while
    # we were suspended, so the last-rendered dedup state is stale.
    {:reply, :ok, %{state | suspended: false, last_snapshot_fingerprint: nil, last_rendered_content: nil}}
  end

  @spec handle_info(term(), t()) :: {:noreply, t()}
  def handle_info(:tick, %{enabled: true, suspended: true} = state) do
    schedule_tick(state.refresh_ms, true)
    {:noreply, state}
  end

  def handle_info(:tick, %{enabled: true} = state) do
    state = refresh_runtime_config(state)
    state = maybe_render(state)
    schedule_tick(state.refresh_ms, true)
    {:noreply, state}
  end

  def handle_info(:refresh, %{suspended: true} = state), do: {:noreply, state}
  def handle_info(:refresh, %{enabled: true} = state), do: {:noreply, maybe_render(refresh_runtime_config(state))}
  def handle_info(:refresh, state), do: {:noreply, state}

  def handle_info({:flush_render, timer_ref}, %{suspended: true, flush_timer_ref: timer_ref} = state) do
    {:noreply, %{state | flush_timer_ref: nil, pending_content: nil}}
  end

  def handle_info({:flush_render, timer_ref}, %{enabled: true, flush_timer_ref: timer_ref} = state) do
    now_ms = System.monotonic_time(:millisecond)

    state =
      case state.pending_content do
        nil ->
          %{state | flush_timer_ref: nil}

        content ->
          state
          |> Map.put(:flush_timer_ref, nil)
          |> Map.put(:pending_content, nil)
          |> render_content(content, now_ms)
      end

    {:noreply, state}
  end

  def handle_info({:flush_render, _timer_ref}, state), do: {:noreply, state}
  def handle_info(:tick, state), do: {:noreply, state}

  # Boot-safe: the release supervision tree starts before the CLI points at a
  # workflow file; fall back to schema defaults until config exists.
  defp observability_settings do
    case Config.settings() do
      {:ok, settings} -> settings.observability
      {:error, _reason} -> %CymphonyElixir.Config.Schema.Observability{}
    end
  end

  defp refresh_runtime_config(%__MODULE__{} = state) do
    observability = observability_settings()

    %{
      state
      | enabled: resolve_override(state.enabled_override, observability.dashboard_enabled and dashboard_enabled?()),
        refresh_ms: state.refresh_ms_override || observability.refresh_ms,
        render_interval_ms: state.render_interval_ms_override || observability.render_interval_ms
    }
  end

  defp schedule_tick(refresh_ms, true), do: Process.send_after(self(), :tick, refresh_ms)
  defp schedule_tick(_refresh_ms, false), do: :ok

  defp maybe_render(state) do
    now_ms = System.monotonic_time(:millisecond)
    {snapshot_data, token_samples} = snapshot_with_samples(state.token_samples, now_ms)
    state = Map.put(state, :token_samples, token_samples)

    current_tokens = snapshot_total_tokens(snapshot_data)

    {tps_second, tps} =
      throttled_tps(
        state.last_tps_second,
        state.last_tps_value,
        now_ms,
        token_samples,
        current_tokens
      )

    state =
      state
      |> Map.put(:last_tps_second, tps_second)
      |> Map.put(:last_tps_value, tps)

    if snapshot_data != state.last_snapshot_fingerprint or periodic_rerender_due?(state, now_ms) do
      content =
        format_snapshot_content(snapshot_data, tps)

      state
      |> maybe_update_snapshot_fingerprint(snapshot_data)
      |> maybe_enqueue_render(content, now_ms)
    else
      state
    end
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Failed rendering status dashboard: #{Exception.message(error)}")
      state
  end

  defp maybe_enqueue_render(state, content, now_ms) do
    cond do
      content == state.last_rendered_content ->
        state

      render_now?(state, now_ms) ->
        render_content(state, content, now_ms)

      true ->
        schedule_flush_render(%{state | pending_content: content}, now_ms)
    end
  end

  defp maybe_update_snapshot_fingerprint(state, snapshot_data) do
    if snapshot_data == state.last_snapshot_fingerprint do
      state
    else
      Map.put(state, :last_snapshot_fingerprint, snapshot_data)
    end
  end

  defp periodic_rerender_due?(%{last_rendered_at_ms: nil}, _now_ms), do: true

  defp periodic_rerender_due?(%{last_rendered_at_ms: last_rendered_at_ms}, now_ms)
       when is_integer(last_rendered_at_ms) do
    now_ms - last_rendered_at_ms >= @minimum_idle_rerender_ms
  end

  defp periodic_rerender_due?(_state, _now_ms), do: false

  defp render_now?(%{last_rendered_at_ms: nil, flush_timer_ref: nil}, _now_ms), do: true

  defp render_now?(%{last_rendered_at_ms: last_rendered_at_ms, render_interval_ms: render_interval_ms}, now_ms)
       when is_integer(last_rendered_at_ms) and is_integer(render_interval_ms) do
    now_ms - last_rendered_at_ms >= render_interval_ms
  end

  defp render_now?(_state, _now_ms), do: false

  defp schedule_flush_render(%{flush_timer_ref: timer_ref} = state, _now_ms) when is_reference(timer_ref),
    do: state

  defp schedule_flush_render(state, now_ms) do
    delay_ms = flush_delay_ms(state, now_ms)
    timer_ref = make_ref()
    Process.send_after(self(), {:flush_render, timer_ref}, delay_ms)
    %{state | flush_timer_ref: timer_ref}
  end

  defp flush_delay_ms(%{last_rendered_at_ms: nil}, _now_ms), do: 1

  defp flush_delay_ms(
         %{last_rendered_at_ms: last_rendered_at_ms, render_interval_ms: render_interval_ms},
         now_ms
       ) do
    remaining = render_interval_ms - (now_ms - last_rendered_at_ms)
    max(1, remaining)
  end

  defp render_content(state, content, now_ms) do
    state.render_fun.(content)

    %{
      state
      | last_rendered_content: content,
        last_rendered_at_ms: now_ms,
        pending_content: nil,
        flush_timer_ref: nil
    }
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Failed rendering terminal dashboard frame: #{Exception.message(error)}")
      %{state | pending_content: nil, flush_timer_ref: nil}
  end

  defp snapshot_with_samples(token_samples, now_ms) do
    case snapshot_payload() do
      {:ok, %{running: running, retrying: retrying, token_totals: token_totals} = snapshot} ->
        total_tokens = Map.get(token_totals, :total_tokens, 0)

        {
          {:ok,
           %{
             running: running,
             retrying: retrying,
             token_totals: token_totals,
             rate_limits: Map.get(snapshot, :rate_limits),
             polling: Map.get(snapshot, :polling),
             per_project: Map.get(snapshot, :per_project, [])
           }},
          update_token_samples(token_samples, now_ms, total_tokens)
        }

      :error ->
        {
          :error,
          prune_samples(token_samples, now_ms)
        }
    end
  end

  defp format_snapshot_content(snapshot_data, tps, terminal_columns_override \\ nil, opts \\ []) do
    case snapshot_data do
      {:ok, %{running: running, retrying: retrying, token_totals: token_totals} = snapshot} ->
        rate_limits = Map.get(snapshot, :rate_limits)
        per_project = Map.get(snapshot, :per_project, [])
        project_link_lines = format_project_link_lines(per_project, opts)
        project_refresh_line = format_project_refresh_line(Map.get(snapshot, :polling))
        input_tokens = Map.get(token_totals, :input_tokens, 0)
        output_tokens = Map.get(token_totals, :output_tokens, 0)
        total_tokens = Map.get(token_totals, :total_tokens, 0)
        claude_seconds_running = Map.get(token_totals, :seconds_running, 0)
        agent_count = length(running)
        max_agents = aggregate_max_agents(opts)
        running_event_width = running_event_width(terminal_columns_override)
        running_rows = format_running_rows(running, running_event_width)
        running_to_backoff_spacer = if(running == [], do: [], else: ["│"])
        backoff_rows = format_retry_rows(retrying)
        rate_limits_line = format_rate_limits_line(rate_limits)

        ([
           colorize("╭─ CYMPHONY STATUS", @ansi_bold),
           colorize("│ Agents: ", @ansi_bold) <>
             colorize("#{agent_count}", @ansi_green) <>
             colorize("/", @ansi_gray) <>
             colorize("#{max_agents}", @ansi_gray),
           colorize("│ Throughput: ", @ansi_bold) <> colorize("#{format_tps(tps)} tps", @ansi_cyan),
           colorize("│ Runtime: ", @ansi_bold) <>
             colorize(format_runtime_seconds(claude_seconds_running), @ansi_magenta),
           colorize("│ Tokens: ", @ansi_bold) <>
             colorize("in #{format_count(input_tokens)}", @ansi_yellow) <>
             colorize(" | ", @ansi_gray) <>
             colorize("out #{format_count(output_tokens)}", @ansi_yellow) <>
             colorize(" | ", @ansi_gray) <>
             colorize("total #{format_count(total_tokens)}", @ansi_yellow),
           rate_limits_line,
           project_link_lines,
           project_refresh_line,
           colorize("├─ Running", @ansi_bold),
           "│"
         ] ++
           running_rows ++
           running_to_backoff_spacer ++
           [colorize("├─ Backoff queue", @ansi_bold), "│"] ++
           backoff_rows ++
           [closing_border()])
        |> List.flatten()
        |> Enum.join("\n")

      :error ->
        [
          colorize("╭─ CYMPHONY STATUS", @ansi_bold),
          colorize("│ Orchestrator snapshot unavailable", @ansi_red),
          colorize("│ Throughput: ", @ansi_bold) <> colorize("#{format_tps(tps)} tps", @ansi_cyan),
          format_project_link_lines([], opts),
          format_project_refresh_line(nil),
          closing_border()
        ]
        |> List.flatten()
        |> Enum.join("\n")
    end
  end

  defp format_project_link_lines(per_project, opts) do
    project_lines = format_multi_project_lines(per_project, opts)

    case dashboard_url(opts) do
      url when is_binary(url) ->
        project_lines ++ [colorize("│ Dashboard: ", @ansi_bold) <> colorize(url, @ansi_cyan)]

      _ ->
        project_lines
    end
  end

  defp format_multi_project_lines(per_project, opts) do
    project_names =
      if hermetic_snapshot?(opts) do
        []
      else
        CymphonyElixir.ProjectSupervisor.list_project_names()
      end

    case project_names do
      [] ->
        # Legacy single-project mode
        project_part =
          try do
            case Config.settings!().tracker.project_slug do
              project_slug when is_binary(project_slug) and project_slug != "" ->
                colorize(linear_project_url(project_slug), @ansi_cyan)

              _ ->
                colorize("n/a", @ansi_gray)
            end
          rescue
            _ -> colorize("n/a", @ansi_gray)
          end

        [colorize("│ Project: ", @ansi_bold) <> project_part]

      _names ->
        format_per_project_meta_lines(per_project)
    end
  end

  defp format_per_project_meta_lines([]) do
    [colorize("│ Projects: ", @ansi_bold) <> colorize("(loading…)", @ansi_gray)]
  end

  defp format_per_project_meta_lines(per_project) do
    sorted = Enum.sort_by(per_project, & &1.name)
    name_width = sorted |> Enum.map(&String.length(&1.name)) |> Enum.max(fn -> 0 end)

    header = colorize("│ Projects:", @ansi_bold)

    rows =
      Enum.map(sorted, fn p ->
        name_cell = String.pad_trailing(p.name, name_width)

        cr_cell =
          colorize("Concurrency ", @ansi_dim) <>
            colorize("#{p.running_count}", @ansi_green) <>
            colorize("/", @ansi_gray) <>
            colorize("#{p.max_concurrent_agents || "?"}", @ansi_gray)

        claude_cell =
          colorize("claude ", @ansi_dim) <>
            colorize(p.claude_command || "claude", @ansi_yellow)

        providers_cell =
          case p.providers do
            [] ->
              ""

            list ->
              colorize(" · ", @ansi_gray) <>
                colorize("providers ", @ansi_dim) <>
                colorize(Enum.join(list, ", "), @ansi_cyan)
          end

        paused_cell =
          if p.paused, do: colorize(" · ", @ansi_gray) <> colorize("paused", @ansi_red), else: ""

        "│   " <>
          colorize(name_cell, @ansi_cyan) <>
          colorize(" · ", @ansi_gray) <>
          cr_cell <>
          colorize(" · ", @ansi_gray) <>
          claude_cell <>
          providers_cell <>
          paused_cell
      end)

    [header | rows]
  end

  defp format_rate_limits_line(nil), do: []
  defp format_rate_limits_line(rate_limits) when is_map(rate_limits) and map_size(rate_limits) == 0, do: []

  defp format_rate_limits_line(rate_limits) do
    colorize("│ Rate Limits: ", @ansi_bold) <> format_rate_limits(rate_limits)
  end

  defp format_project_refresh_line(%{checking?: true}) do
    colorize("│ Next refresh: ", @ansi_bold) <> colorize("checking now…", @ansi_cyan)
  end

  defp format_project_refresh_line(%{next_poll_in_ms: due_in_ms}) when is_integer(due_in_ms) do
    due_in_ms = max(due_in_ms, 0)
    seconds = div(due_in_ms + 999, 1000)
    colorize("│ Next refresh: ", @ansi_bold) <> colorize("#{seconds}s", @ansi_cyan)
  end

  defp format_project_refresh_line(_) do
    colorize("│ Next refresh: ", @ansi_bold) <> colorize("n/a", @ansi_gray)
  end

  defp linear_project_url(project_slug), do: "https://linear.app/project/#{project_slug}/issues"

  defp dashboard_url(opts) do
    host =
      case Config.settings() do
        {:ok, settings} -> settings.server.host
        {:error, _reason} -> "127.0.0.1"
      end

    bound_port = if hermetic_snapshot?(opts), do: nil, else: HttpServer.bound_port()
    url = dashboard_url(host, Config.server_port(), bound_port)

    if is_binary(url) and not hermetic_snapshot?(opts) do
      maybe_persist_dashboard_url(url)
    end

    url
  end

  defp dashboard_url(_host, nil, _bound_port), do: nil

  defp dashboard_url(host, configured_port, bound_port) do
    port = bound_port || configured_port

    if is_integer(port) and port > 0 do
      "http://#{dashboard_url_host(host)}:#{port}/"
    else
      nil
    end
  end

  # Write the dashboard URL to ~/.cymphony/dashboard.url so `cymphony webui`
  # (a separate CLI process) can find it. Idempotent; only writes when the
  # value would change.
  defp maybe_persist_dashboard_url(url) do
    path = UrlFile.path()

    case File.read(path) do
      {:ok, ^url} -> :ok
      _ -> UrlFile.write(url)
    end
  end

  defp dashboard_url_host(host) when host in ["0.0.0.0", "::", "[::]", ""], do: "127.0.0.1"

  defp dashboard_url_host(host) when is_binary(host) do
    trimmed_host = String.trim(host)

    cond do
      trimmed_host in ["0.0.0.0", "::", "[::]", ""] ->
        "127.0.0.1"

      String.starts_with?(trimmed_host, "[") and String.ends_with?(trimmed_host, "]") ->
        trimmed_host

      String.contains?(trimmed_host, ":") ->
        "[#{trimmed_host}]"

      true ->
        trimmed_host
    end
  end

  defp render_to_terminal(content) do
    IO.write([
      IO.ANSI.home(),
      IO.ANSI.clear(),
      normalize_status_lines(content),
      "\n"
    ])
  end

  defp update_token_samples(samples, now_ms, total_tokens) do
    prune_graph_samples([{now_ms, total_tokens} | samples], now_ms)
  end

  defp prune_samples(samples, now_ms) do
    min_timestamp = now_ms - @throughput_window_ms
    Enum.filter(samples, fn {timestamp, _} -> timestamp >= min_timestamp end)
  end

  defp prune_graph_samples(samples, now_ms) do
    min_timestamp = now_ms - max(@throughput_window_ms, @throughput_graph_window_ms)
    Enum.filter(samples, fn {timestamp, _} -> timestamp >= min_timestamp end)
  end

  @doc false
  @spec rolling_tps([{integer(), integer()}], integer(), integer()) :: float()
  def rolling_tps(samples, now_ms, current_tokens) do
    samples = [{now_ms, current_tokens} | samples]
    samples = prune_samples(samples, now_ms)

    case samples do
      [] ->
        0.0

      [_one] ->
        0.0

      _ ->
        first = List.last(samples)
        {start_ms, start_tokens} = first
        elapsed_ms = now_ms - start_ms
        delta_tokens = max(0, current_tokens - start_tokens)

        if elapsed_ms <= 0 do
          0.0
        else
          delta_tokens / (elapsed_ms / 1000.0)
        end
    end
  end

  @doc false
  @spec throttled_tps(integer() | nil, float() | nil, integer(), [{integer(), integer()}], integer()) ::
          {integer(), float()}
  def throttled_tps(last_second, last_value, now_ms, token_samples, current_tokens) do
    second = div(now_ms, 1000)

    if is_integer(last_second) and last_second == second and is_number(last_value) do
      {second, last_value}
    else
      {second, rolling_tps(token_samples, now_ms, current_tokens)}
    end
  end

  @doc false
  @spec format_timestamp_for_test(DateTime.t()) :: String.t()
  def format_timestamp_for_test(%DateTime{} = datetime), do: format_timestamp(datetime)

  @doc false
  @spec format_snapshot_content_for_test(term(), number()) :: String.t()
  def format_snapshot_content_for_test(snapshot_data, tps),
    do: format_snapshot_content(snapshot_data, tps, nil, hermetic: true)

  @doc false
  @spec format_snapshot_content_for_test(term(), number(), integer() | nil) :: String.t()
  def format_snapshot_content_for_test(snapshot_data, tps, terminal_columns),
    do: format_snapshot_content(snapshot_data, tps, terminal_columns, hermetic: true)

  @doc false
  @spec dashboard_url_for_test(String.t(), non_neg_integer() | nil, non_neg_integer() | nil) ::
          String.t() | nil
  def dashboard_url_for_test(host, configured_port, bound_port),
    do: dashboard_url(host, configured_port, bound_port)

  defp snapshot_payload do
    case aggregate_project_snapshots() do
      [] -> legacy_snapshot_payload()
      snapshots -> {:ok, merge_project_snapshots(snapshots)}
    end
  end

  defp legacy_snapshot_payload do
    if Process.whereis(Orchestrator) do
      orchestrator_snapshot_payload(Orchestrator.snapshot())
    else
      :error
    end
  end

  defp orchestrator_snapshot_payload(
         %{
           running: running,
           retrying: retrying,
           token_totals: token_totals
         } = snapshot
       )
       when is_list(running) and is_list(retrying) do
    {:ok,
     %{
       running: running,
       retrying: retrying,
       token_totals: token_totals,
       rate_limits: Map.get(snapshot, :rate_limits),
       polling: Map.get(snapshot, :polling)
     }}
  end

  defp orchestrator_snapshot_payload(_snapshot), do: :error

  defp aggregate_project_snapshots do
    alias CymphonyElixir.ProjectSupervisor

    ProjectSupervisor.list_orchestrators()
    |> Enum.flat_map(fn {project_name, pid} ->
      try do
        case Orchestrator.snapshot(pid, 5_000) do
          %{} = snapshot ->
            [%{project_name: project_name, snapshot: snapshot}]

          _ ->
            []
        end
      catch
        :exit, _ -> []
      end
    end)
  end

  defp merge_project_snapshots(snapshots) do
    all_running =
      snapshots
      |> Enum.flat_map(fn %{project_name: project_name, snapshot: snap} ->
        Enum.map(snap.running, &Map.put(&1, :project_name, project_name))
      end)

    all_retrying =
      snapshots
      |> Enum.flat_map(fn %{project_name: project_name, snapshot: snap} ->
        Enum.map(snap.retrying, &Map.put(&1, :project_name, project_name))
      end)

    merged_totals =
      snapshots
      |> Enum.reduce(%{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}, fn %{snapshot: snap}, acc ->
        totals = Map.get(snap, :token_totals, %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0})

        %{
          input_tokens: acc.input_tokens + Map.get(totals, :input_tokens, 0),
          output_tokens: acc.output_tokens + Map.get(totals, :output_tokens, 0),
          total_tokens: acc.total_tokens + Map.get(totals, :total_tokens, 0),
          seconds_running: acc.seconds_running + Map.get(totals, :seconds_running, 0)
        }
      end)

    # Use first snapshot's rate_limits and polling as representative
    first_snap = hd(snapshots).snapshot

    per_project =
      Enum.map(snapshots, fn %{project_name: name, snapshot: snap} ->
        polling = Map.get(snap, :polling, %{})

        %{
          name: name,
          max_concurrent_agents: Map.get(polling, :max_concurrent_agents),
          paused: Map.get(polling, :paused, false),
          running_count: length(Map.get(snap, :running, [])),
          claude_command: Map.get(snap, :claude_command),
          providers: Map.get(snap, :providers, [])
        }
      end)

    %{
      running: all_running,
      retrying: all_retrying,
      token_totals: merged_totals,
      rate_limits: Map.get(first_snap, :rate_limits),
      polling: Map.get(first_snap, :polling),
      per_project: per_project
    }
  end

  defp hermetic_snapshot?(opts), do: Keyword.get(opts, :hermetic, false)

  defp aggregate_max_agents(opts) do
    if hermetic_snapshot?(opts) do
      hermetic_max_agents()
    else
      live_max_agents()
    end
  end

  defp hermetic_max_agents do
    Config.settings!().agent.max_concurrent_agents
  rescue
    _ -> 10
  end

  defp live_max_agents do
    case CymphonyElixir.ProjectSupervisor.list_project_names() do
      [] ->
        # Legacy single-project mode: use global config
        Config.settings!().agent.max_concurrent_agents

      names ->
        # Multi-project: sum max_concurrent_agents from each project's config
        Enum.reduce(names, 0, &add_project_max_agents/2)
    end
  rescue
    _ -> 10
  catch
    :exit, _ -> 10
  end

  defp add_project_max_agents(project_name, acc) do
    case CymphonyElixir.ProjectSupervisor.lookup(project_name, :workflow_store) do
      nil -> acc
      store_pid -> acc + project_max_agents(store_pid)
    end
  end

  defp project_max_agents(store_pid) do
    case CymphonyElixir.WorkflowStore.current(store_pid) do
      {:ok, %{config: raw_config}} when is_map(raw_config) -> parsed_max_agents(raw_config)
      _ -> 0
    end
  end

  defp parsed_max_agents(raw_config) do
    case Config.Schema.parse(raw_config) do
      {:ok, settings} -> settings.agent.max_concurrent_agents
      {:error, _} -> 0
    end
  end

  defp format_running_rows(running, running_event_width) do
    if running == [] do
      [
        "│  " <> colorize("No active agents", @ansi_gray),
        "│"
      ]
    else
      groups = grouped_status_rows(running)
      single_project? = length(groups) <= 1

      Enum.flat_map(groups, fn {project_name, rows} ->
        running_group_rows(project_name, rows, running_event_width, single_project?)
      end)
    end
  end

  defp running_group_rows(project_name, rows, running_event_width, single_project?) do
    rows = Enum.sort_by(rows, & &1.identifier)
    header = [running_table_header_row(running_event_width), running_table_separator_row(running_event_width)]
    body = Enum.map(rows, &format_running_summary(&1, running_event_width))
    maybe_project_group(project_name, header ++ body, single_project?)
  end

  defp project_subheader(name) do
    label = name || "(unassigned)"
    "│ " <> colorize("── #{label} ──", @ansi_bold)
  end

  # credo:disable-for-next-line
  defp format_running_summary(running_entry, running_event_width) do
    issue = format_cell(running_entry.identifier || "unknown", @running_id_width)
    state = running_entry.state || "unknown"
    state_display = format_cell(to_string(state), @running_stage_width)
    session = running_entry.session_id |> compact_session_id() |> format_cell(@running_session_width)
    pid = format_cell(running_entry.agent_os_pid || "n/a", @running_pid_width)
    total_tokens = running_entry.total_tokens || 0
    runtime_seconds = running_entry.runtime_seconds || 0
    turn_count = Map.get(running_entry, :turn_count, 0)
    age = format_cell(format_runtime_and_turns(runtime_seconds, turn_count), @running_age_width)
    event = running_entry.last_agent_event || "none"
    event_label = format_cell(summarize_message(running_entry.last_agent_message), running_event_width)

    tokens = format_count(total_tokens) |> format_cell(@running_tokens_width, :right)

    status_color =
      case event do
        :none -> @ansi_red
        "claude/event/token_count" -> @ansi_yellow
        "claude/event/task_started" -> @ansi_green
        "turn_completed" -> @ansi_magenta
        _ -> @ansi_blue
      end

    [
      "│ ",
      status_dot(status_color),
      " ",
      colorize(issue, @ansi_cyan),
      " ",
      colorize(state_display, status_color),
      " ",
      colorize(pid, @ansi_yellow),
      " ",
      colorize(age, @ansi_magenta),
      " ",
      colorize(tokens, @ansi_yellow),
      " ",
      colorize(session, @ansi_cyan),
      " ",
      colorize(event_label, status_color)
    ]
    |> Enum.join("")
  end

  @doc false
  @spec format_running_summary_for_test(map(), integer() | nil) :: String.t()
  def format_running_summary_for_test(running_entry, terminal_columns \\ nil),
    do: format_running_summary(running_entry, running_event_width(terminal_columns))

  @doc false
  @spec format_tps_for_test(number()) :: String.t()
  def format_tps_for_test(value), do: format_tps(value)

  @doc false
  @spec tps_graph_for_test([{integer(), integer()}], integer(), integer()) :: String.t()
  def tps_graph_for_test(samples, now_ms, current_tokens), do: tps_graph(samples, now_ms, current_tokens)

  defp format_retry_rows(retrying) do
    if retrying == [] do
      ["│  " <> colorize("No queued retries", @ansi_gray)]
    else
      groups = grouped_status_rows(retrying)
      single_project? = length(groups) <= 1

      Enum.flat_map(groups, fn {project_name, rows} ->
        retry_group_rows(project_name, rows, single_project?)
      end)
    end
  end

  defp grouped_status_rows(entries) do
    entries
    |> Enum.group_by(&Map.get(&1, :project_name))
    |> Enum.sort_by(fn {name, _} -> name || "" end)
  end

  defp retry_group_rows(project_name, rows, single_project?) do
    body =
      rows
      |> Enum.sort_by(& &1.due_in_ms)
      |> Enum.map(&format_retry_summary/1)

    maybe_project_group(project_name, body, single_project?)
  end

  defp maybe_project_group(_project_name, rows, true), do: rows

  defp maybe_project_group(project_name, rows, false) do
    [project_subheader(project_name) | rows] ++ ["│"]
  end

  defp format_retry_summary(retry_entry) do
    issue_id = retry_entry.issue_id || "unknown"
    identifier = retry_entry.identifier || issue_id
    attempt = retry_entry.attempt || 0
    error = format_retry_error(retry_entry.error)

    "│  #{colorize("↻", @ansi_orange)} " <>
      colorize("#{identifier}", @ansi_red) <>
      " " <>
      colorize("attempt=#{attempt}", @ansi_yellow) <>
      retry_due_text(retry_entry) <>
      error
  end

  # A held entry is parked until dispatch resumes; its `due_in_ms` is clamped
  # to 0 for the whole pause, so "in 0.000s" would read as due right now.
  defp retry_due_text(%{held: true}), do: colorize(" held", @ansi_dim)

  defp retry_due_text(retry_entry) do
    colorize(" in ", @ansi_dim) <> colorize(next_in_words(retry_entry.due_in_ms || 0), @ansi_cyan)
  end

  defp next_in_words(due_in_ms) when is_integer(due_in_ms) do
    secs = div(due_in_ms, 1000)
    millis = rem(due_in_ms, 1000)
    "#{secs}.#{String.pad_leading(to_string(millis), 3, "0")}s"
  end

  defp next_in_words(_), do: "n/a"

  defp format_retry_error(error) when is_binary(error) do
    sanitized =
      error
      |> String.replace("\\r\\n", " ")
      |> String.replace("\\r", " ")
      |> String.replace("\\n", " ")
      |> String.replace("\r\n", " ")
      |> String.replace("\r", " ")
      |> String.replace("\n", " ")
      |> String.replace(Regex.compile!("\\s+"), " ")
      |> String.trim()

    if sanitized == "" do
      ""
    else
      " " <> colorize("error=#{truncate(sanitized, 96)}", @ansi_dim)
    end
  end

  defp format_retry_error(_), do: ""

  defp format_runtime_seconds(seconds) when is_integer(seconds) do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp format_runtime_seconds(seconds) when is_binary(seconds), do: seconds
  defp format_runtime_seconds(_), do: "0m 0s"

  defp format_runtime_and_turns(seconds, turn_count) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(seconds)} / #{turn_count}"
  end

  defp format_runtime_and_turns(seconds, _turn_count), do: format_runtime_seconds(seconds)

  defp format_count(nil), do: "0"

  defp format_count(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> group_thousands()
  end

  defp format_count(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {number, ""} -> group_thousands(Integer.to_string(number))
      _ -> value
    end
  end

  defp format_count(value), do: to_string(value)

  defp running_table_header_row(running_event_width) do
    header =
      [
        format_cell("ID", @running_id_width),
        format_cell("STAGE", @running_stage_width),
        format_cell("PID", @running_pid_width),
        format_cell("AGE / TURN", @running_age_width),
        format_cell("TOKENS", @running_tokens_width),
        format_cell("SESSION", @running_session_width),
        format_cell("EVENT", running_event_width)
      ]
      |> Enum.join(" ")

    "│   " <> colorize(header, @ansi_gray)
  end

  defp running_table_separator_row(running_event_width) do
    separator_width =
      @running_id_width +
        @running_stage_width +
        @running_pid_width +
        @running_age_width +
        @running_tokens_width +
        @running_session_width +
        running_event_width + 6

    "│   " <> colorize(String.duplicate("─", separator_width), @ansi_gray)
  end

  defp running_event_width(terminal_columns) do
    terminal_columns = terminal_columns || terminal_columns()

    max(
      @running_event_min_width,
      terminal_columns - fixed_running_width() - @running_row_chrome_width
    )
  end

  defp fixed_running_width do
    @running_id_width +
      @running_stage_width +
      @running_pid_width +
      @running_age_width +
      @running_tokens_width +
      @running_session_width
  end

  defp terminal_columns do
    case :io.columns() do
      {:ok, columns} when is_integer(columns) and columns > 0 ->
        columns

      _ ->
        terminal_columns_from_env()
    end
  end

  defp terminal_columns_from_env do
    case System.get_env("COLUMNS") do
      nil ->
        fixed_running_width() + @running_row_chrome_width + @running_event_default_width

      value ->
        case Integer.parse(String.trim(value)) do
          {columns, ""} when columns > 0 -> columns
          _ -> @default_terminal_columns
        end
    end
  end

  defp format_cell(value, width, align \\ :left) do
    value =
      value
      |> to_string()
      |> String.replace("\n", " ")
      |> String.replace(Regex.compile!("\\s+"), " ")
      |> String.trim()
      |> truncate_plain(width)

    case align do
      :right -> String.pad_leading(value, width)
      _ -> String.pad_trailing(value, width)
    end
  end

  defp truncate_plain(value, width) do
    if byte_size(value) <= width do
      value
    else
      String.slice(value, 0, width - 3) <> "..."
    end
  end

  defp compact_session_id(nil), do: "n/a"
  defp compact_session_id(session_id) when not is_binary(session_id), do: "n/a"

  defp compact_session_id(session_id) do
    if String.length(session_id) > 10 do
      String.slice(session_id, 0, 4) <> "..." <> String.slice(session_id, -6, 6)
    else
      session_id
    end
  end

  defp group_thousands(value) when is_binary(value) do
    sign = if String.starts_with?(value, "-"), do: "-", else: ""
    unsigned = if sign == "", do: value, else: String.slice(value, 1, String.length(value) - 1)

    unsigned
    |> String.reverse()
    |> String.replace(Regex.compile!("(\\d{3})(?=\\d)"), "\\1,")
    |> String.reverse()
    |> prepend(sign)
  end

  defp prepend("", value), do: value
  defp prepend(prefix, value), do: prefix <> value

  defp format_tps(value) when is_number(value) do
    value
    |> trunc()
    |> Integer.to_string()
    |> group_thousands()
  end

  defp tps_graph(samples, now_ms, current_tokens) do
    bucket_ms = div(@throughput_graph_window_ms, @throughput_graph_columns)
    active_bucket_start = div(now_ms, bucket_ms) * bucket_ms
    graph_window_start = active_bucket_start - (@throughput_graph_columns - 1) * bucket_ms

    rates =
      [{now_ms, current_tokens} | samples]
      |> prune_graph_samples(now_ms)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{start_ms, start_tokens}, {end_ms, end_tokens}] ->
        elapsed_ms = end_ms - start_ms
        delta_tokens = max(0, end_tokens - start_tokens)
        tps = if elapsed_ms <= 0, do: 0.0, else: delta_tokens / (elapsed_ms / 1000.0)
        {end_ms, tps}
      end)

    bucketed_tps =
      0..(@throughput_graph_columns - 1)
      |> Enum.map(fn bucket_idx ->
        bucket_start = graph_window_start + bucket_idx * bucket_ms
        bucket_end = bucket_start + bucket_ms
        last_bucket? = bucket_idx == @throughput_graph_columns - 1

        values =
          rates
          |> Enum.filter(fn {timestamp, _tps} ->
            in_bucket?(timestamp, bucket_start, bucket_end, last_bucket?)
          end)
          |> Enum.map(fn {_timestamp, tps} -> tps end)

        if values == [] do
          0.0
        else
          Enum.sum(values) / length(values)
        end
      end)

    max_tps = Enum.max(bucketed_tps, fn -> 0.0 end)

    bucketed_tps
    |> Enum.map_join(fn value ->
      index =
        if max_tps <= 0 do
          0
        else
          round(value / max_tps * (length(@sparkline_blocks) - 1))
        end

      Enum.at(@sparkline_blocks, index, "▁")
    end)
  end

  defp in_bucket?(timestamp, bucket_start, bucket_end, true),
    do: timestamp >= bucket_start and timestamp <= bucket_end

  defp in_bucket?(timestamp, bucket_start, bucket_end, false),
    do: timestamp >= bucket_start and timestamp < bucket_end

  defp format_rate_limits(nil), do: colorize("unavailable", @ansi_gray)

  defp format_rate_limits(rate_limits) when is_map(rate_limits) do
    limit_id =
      map_value(rate_limits, ["limit_id", :limit_id, "limit_name", :limit_name]) ||
        "unknown"

    primary = format_rate_limit_bucket(map_value(rate_limits, ["primary", :primary]))
    secondary = format_rate_limit_bucket(map_value(rate_limits, ["secondary", :secondary]))
    credits = format_rate_limit_credits(map_value(rate_limits, ["credits", :credits]))

    colorize(to_string(limit_id), @ansi_yellow) <>
      colorize(" | ", @ansi_gray) <>
      colorize("primary #{primary}", @ansi_cyan) <>
      colorize(" | ", @ansi_gray) <>
      colorize("secondary #{secondary}", @ansi_cyan) <>
      colorize(" | ", @ansi_gray) <>
      colorize(credits, @ansi_green)
  end

  defp format_rate_limits(other) do
    other
    |> inspect(limit: 10)
    |> truncate(80)
    |> colorize(@ansi_gray)
  end

  defp format_rate_limit_bucket(nil), do: "n/a"

  defp format_rate_limit_bucket(bucket) when is_map(bucket) do
    remaining = map_value(bucket, ["remaining", :remaining])
    limit = map_value(bucket, ["limit", :limit])

    reset_value =
      map_value(bucket, [
        "reset_in_seconds",
        :reset_in_seconds,
        "resetInSeconds",
        :resetInSeconds,
        "reset_at",
        :reset_at,
        "resetAt",
        :resetAt,
        "resets_at",
        :resets_at,
        "resetsAt",
        :resetsAt
      ])

    base =
      cond do
        integer_like?(remaining) and integer_like?(limit) ->
          "#{format_count(remaining)}/#{format_count(limit)}"

        integer_like?(remaining) ->
          "remaining #{format_count(remaining)}"

        integer_like?(limit) ->
          "limit #{format_count(limit)}"

        map_size(bucket) == 0 ->
          "n/a"

        true ->
          bucket |> inspect(limit: 6) |> truncate(40)
      end

    if is_nil(reset_value) do
      base
    else
      "#{base} reset #{format_reset_value(reset_value)}"
    end
  end

  defp format_rate_limit_bucket(other), do: to_string(other)

  defp format_rate_limit_credits(nil), do: "credits n/a"

  defp format_rate_limit_credits(credits) when is_map(credits) do
    unlimited = map_value(credits, ["unlimited", :unlimited]) == true
    has_credits = map_value(credits, ["has_credits", :has_credits]) == true
    balance = map_value(credits, ["balance", :balance])

    cond do
      unlimited ->
        "credits unlimited"

      has_credits and is_number(balance) ->
        "credits #{format_number(balance)}"

      has_credits ->
        "credits available"

      true ->
        "credits none"
    end
  end

  defp format_rate_limit_credits(other), do: "credits #{to_string(other)}"

  defp format_reset_value(value) when is_integer(value), do: "#{format_count(value)}s"
  defp format_reset_value(value) when is_binary(value), do: value
  defp format_reset_value(value), do: to_string(value)

  defp format_number(value) when is_integer(value), do: format_count(value)

  defp format_number(value) when is_float(value) do
    value
    |> Float.round(2)
    |> :erlang.float_to_binary(decimals: 2)
  end

  defp map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp map_value(_map, _keys), do: nil

  defp integer_like?(value) when is_integer(value), do: true
  defp integer_like?(_value), do: false

  defp status_dot(color_code) do
    colorize("●", color_code)
  end

  defp snapshot_total_tokens({:ok, %{token_totals: token_totals}}) when is_map(token_totals) do
    Map.get(token_totals, :total_tokens, 0)
  end

  defp snapshot_total_tokens(_snapshot_data), do: 0

  defp format_timestamp(datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_string()
  end

  defp normalize_status_lines(content) do
    content
  end

  defp closing_border, do: "╰─"

  defp colorize(value, code) do
    "#{code}#{value}#{@ansi_reset}"
  end

  @doc false
  @spec humanize_agent_message(term()) :: String.t()
  def humanize_agent_message(nil), do: "no claude message yet"

  def humanize_agent_message(%{event: event}) when event in [:harness_stdout, :harness_heartbeat] do
    "harness"
  end

  def humanize_agent_message(%{event: event, message: message}) do
    payload = unwrap_agent_message_payload(message)

    (humanize_agent_event(event, message, payload) || humanize_agent_payload(payload))
    |> truncate(140)
  end

  def humanize_agent_message(%{message: message}) do
    message
    |> unwrap_agent_message_payload()
    |> humanize_agent_payload()
    |> truncate(140)
  end

  def humanize_agent_message(message) do
    message
    |> unwrap_agent_message_payload()
    |> humanize_agent_payload()
    |> truncate(140)
  end

  defp summarize_message(message), do: humanize_agent_message(message)

  defp humanize_agent_event(:session_started, _message, payload) do
    session_id = map_value(payload, ["session_id", :session_id])

    if is_binary(session_id) do
      "session started (#{session_id})"
    else
      "session started"
    end
  end

  defp humanize_agent_event(:turn_input_required, _message, _payload), do: "turn blocked: waiting for user input"

  defp humanize_agent_event(:approval_auto_approved, message, payload) do
    method =
      map_value(payload, ["method", :method]) ||
        map_path(message, ["payload", "method"]) ||
        map_path(message, [:payload, :method])

    decision = map_value(message, ["decision", :decision])

    base =
      if is_binary(method) do
        "#{humanize_agent_method(method, payload)} (auto-approved)"
      else
        "approval request auto-approved"
      end

    if is_binary(decision), do: "#{base}: #{decision}", else: base
  end

  defp humanize_agent_event(:tool_input_auto_answered, message, payload) do
    answer = map_value(message, ["answer", :answer])

    base =
      case humanize_agent_method("item/tool/requestUserInput", payload) do
        nil -> "tool input auto-answered"
        text -> "#{text} (auto-answered)"
      end

    if is_binary(answer), do: "#{base}: #{inline_text(answer)}", else: base
  end

  defp humanize_agent_event(:tool_call_completed, _message, payload),
    do: humanize_dynamic_tool_event("dynamic tool call completed", payload)

  defp humanize_agent_event(:tool_call_failed, _message, payload),
    do: humanize_dynamic_tool_event("dynamic tool call failed", payload)

  defp humanize_agent_event(:unsupported_tool_call, _message, payload),
    do: humanize_dynamic_tool_event("unsupported dynamic tool call rejected", payload)

  defp humanize_agent_event(:turn_ended_with_error, message, _payload), do: "turn ended with error: #{format_reason(message)}"
  defp humanize_agent_event(:startup_failed, message, _payload), do: "startup failed: #{format_reason(message)}"
  defp humanize_agent_event(:turn_failed, _message, payload), do: humanize_agent_method("turn/failed", payload)
  defp humanize_agent_event(:turn_cancelled, _message, _payload), do: "turn cancelled"
  defp humanize_agent_event(:malformed, _message, _payload), do: "malformed JSON event from claude"
  defp humanize_agent_event(event, _message, _payload) when event in [:harness_stdout, :harness_heartbeat], do: "harness"
  defp humanize_agent_event(_event, _message, _payload), do: nil

  defp unwrap_agent_message_payload(%{} = message) do
    cond do
      is_binary(map_value(message, ["method", :method])) -> message
      is_binary(map_value(message, ["event", :event])) -> message
      is_binary(map_value(message, ["session_id", :session_id])) -> message
      is_binary(map_value(message, ["reason", :reason])) -> message
      true -> map_value(message, ["payload", :payload]) || message
    end
  end

  defp unwrap_agent_message_payload(message), do: message

  defp humanize_agent_payload(%{} = payload) do
    case {map_value(payload, ["event", :event]), map_value(payload, ["method", :method]), map_value(payload, ["type", :type])} do
      {event, _, _} when is_binary(event) ->
        humanize_antigravity_event(event, payload)

      {_, method, _} when is_binary(method) ->
        humanize_agent_method(method, payload)

      {_, _, type} when type in @claude_stream_types ->
        humanize_claude_event(type, payload)

      {_, _, type} when is_binary(type) ->
        humanize_codex_event(type, payload)

      _ ->
        humanize_agent_payload_fallback(payload)
    end
  end

  defp humanize_agent_payload(payload) when is_binary(payload) do
    payload
    |> String.replace("\n", " ")
    |> sanitize_ansi_and_control_bytes()
    |> String.trim()
  end

  defp humanize_agent_payload(payload) do
    payload
    |> inspect(pretty: true, limit: 20)
    |> String.replace("\n", " ")
    |> sanitize_ansi_and_control_bytes()
    |> String.trim()
  end

  defp humanize_agent_payload_fallback(payload) do
    cond do
      is_binary(map_value(payload, ["session_id", :session_id])) ->
        "session started (#{map_value(payload, ["session_id", :session_id])})"

      match?(%{"error" => _}, payload) ->
        "error: #{format_error_value(Map.get(payload, "error"))}"

      true ->
        payload
        |> inspect(pretty: true, limit: 30)
        |> String.replace("\n", " ")
        |> sanitize_ansi_and_control_bytes()
        |> String.trim()
    end
  end

  defp humanize_claude_event("system", payload) do
    case map_value(payload, ["subtype", :subtype]) do
      "init" ->
        skills = map_value(payload, ["skills", :skills])
        model = map_value(payload, ["model", :model])

        [
          if(is_binary(model), do: model),
          if(is_list(skills), do: "#{length(skills)} skills")
        ]
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> "session init"
          parts -> "session init (#{Enum.join(parts, ", ")})"
        end

      subtype when is_binary(subtype) ->
        "system: #{subtype}"

      _ ->
        "system"
    end
  end

  defp humanize_claude_event("assistant", payload) do
    payload
    |> claude_content_blocks()
    |> Enum.map(&humanize_claude_assistant_block/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "assistant"
      parts -> Enum.join(parts, "; ")
    end
  end

  defp humanize_claude_event("user", payload) do
    blocks = claude_content_blocks(payload)
    results = Enum.filter(blocks, &(map_value(&1, ["type", :type]) == "tool_result"))

    cond do
      results == [] ->
        "user message"

      error = Enum.find(results, &(map_value(&1, ["is_error", :is_error]) == true)) ->
        case claude_block_text(map_value(error, ["content", :content])) do
          "" -> "tool error"
          text -> "tool error: #{inline_text(text)}"
        end

      true ->
        "tool result"
    end
  end

  defp humanize_claude_event("result", payload) do
    turns = map_value(payload, ["num_turns", :num_turns])
    suffix = if is_integer(turns), do: " (#{turns} turns)", else: ""

    case {map_value(payload, ["subtype", :subtype]), map_value(payload, ["is_error", :is_error])} do
      {"success", is_error} when is_error != true -> "result: success" <> suffix
      {subtype, _} when is_binary(subtype) -> "result: #{subtype}" <> suffix
      _ -> "result" <> suffix
    end
  end

  defp claude_content_blocks(payload) do
    case map_path(payload, ["message", "content"]) || map_path(payload, [:message, :content]) do
      blocks when is_list(blocks) -> Enum.filter(blocks, &is_map/1)
      _ -> []
    end
  end

  defp humanize_claude_assistant_block(block) do
    case map_value(block, ["type", :type]) do
      "tool_use" ->
        humanize_claude_tool_use(block)

      "text" ->
        case map_value(block, ["text", :text]) do
          text when is_binary(text) and text != "" -> inline_text(text)
          _ -> nil
        end

      "thinking" ->
        "thinking"

      _ ->
        nil
    end
  end

  defp humanize_claude_tool_use(block) do
    name = map_value(block, ["name", :name]) || "tool"
    input = map_value(block, ["input", :input]) || %{}

    case claude_tool_detail(name, input) do
      detail when is_binary(detail) and detail != "" -> "#{name}: #{inline_text(detail)}"
      _ -> name
    end
  end

  # The one argument that says what the call is *for*: the skill name for
  # `Skill`, the operator-facing description (else the command) for `Bash`,
  # the path for file tools, the pattern for search tools.
  defp claude_tool_detail("Skill", input), do: map_value(input, ["skill", :skill])
  defp claude_tool_detail("Bash", input), do: map_value(input, ["description", :description, "command", :command])

  defp claude_tool_detail(name, input) when name in ["Read", "Edit", "Write", "NotebookEdit"],
    do: map_value(input, ["file_path", :file_path, "notebook_path", :notebook_path])

  defp claude_tool_detail(name, input) when name in ["Grep", "Glob"], do: map_value(input, ["pattern", :pattern])

  defp claude_tool_detail(name, input) when name in ["Task", "Agent"],
    do: map_value(input, ["description", :description])

  defp claude_tool_detail(_name, input), do: map_value(input, ["description", :description])

  defp claude_block_text(content) when is_binary(content), do: content

  defp claude_block_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{} = part -> map_value(part, ["text", :text])
      text when is_binary(text) -> text
      _ -> nil
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end

  defp claude_block_text(_content), do: ""

  # Codex `exec --json` events carry {"type": "…"} (dot-separated) rather than
  # the {"method": "…"} shape of the app-server protocol above.
  defp humanize_codex_event("thread.started", payload) do
    case map_value(payload, ["thread_id", :thread_id]) do
      thread_id when is_binary(thread_id) -> "thread started (#{short_id(thread_id)})"
      _ -> "thread started"
    end
  end

  defp humanize_codex_event("turn.started", _payload), do: "turn started"

  defp humanize_codex_event("turn.completed", payload) do
    case map_value(payload, ["usage", :usage]) do
      %{} = usage ->
        input = map_value(usage, ["input_tokens", :input_tokens]) || 0
        output = map_value(usage, ["output_tokens", :output_tokens]) || 0
        "turn completed (tokens in #{input} / out #{output})"

      _ ->
        "turn completed"
    end
  end

  defp humanize_codex_event("turn.failed", payload) do
    reason =
      map_path(payload, ["error", "message"]) ||
        map_path(payload, [:error, :message]) ||
        "unknown error"

    "turn failed: #{reason}"
  end

  defp humanize_codex_event("item." <> lifecycle, payload) do
    item = map_value(payload, ["item", :item]) || %{}
    item_type = map_value(item, ["type", :type])

    detail =
      case item_type do
        "agent_message" -> map_value(item, ["text", :text])
        "command_execution" -> map_value(item, ["command", :command])
        "reasoning" -> map_value(item, ["text", :text])
        _ -> nil
      end

    base = "item #{lifecycle}: #{humanize_item_type(item_type)}"
    if is_binary(detail) and detail != "", do: "#{base} — #{truncate(detail, 80)}", else: base
  end

  defp humanize_codex_event(type, _payload), do: type

  defp humanize_antigravity_event("init", payload) do
    conversation_id =
      map_value(payload, ["conversation_id", :conversation_id]) ||
        map_path(payload, ["init", "conversation_id"]) ||
        map_path(payload, [:init, :conversation_id])

    case short_id(conversation_id) do
      id when is_binary(id) and id != "" -> "antigravity init (" <> id <> ")"
      _ -> "antigravity init"
    end
  end

  defp humanize_antigravity_event("step_update", payload) do
    step = antigravity_step_update(payload)

    antigravity_step_summary(
      map_value(step, ["tool_name", :tool_name]),
      map_value(step, ["step_type", :step_type]),
      map_value(step, ["state", :state]),
      map_value(step, ["text_delta", :text_delta])
    )
  end

  defp humanize_antigravity_event("result", payload) do
    completed =
      case map_value(payload, ["result", :result]) do
        %{} = result -> result
        _ -> payload
      end

    status = map_value(completed, ["status", :status]) || map_value(payload, ["status", :status])
    usage = map_value(completed, ["usage", :usage]) || map_value(payload, ["usage", :usage])

    base =
      if is_binary(status) and status != "" do
        "result " <> status
      else
        "result"
      end

    case format_usage_counts(usage) do
      nil -> base
      usage_text -> base <> " (#{usage_text})"
    end
  end

  defp humanize_antigravity_event(event, _payload) when event in ["harness_stdout", "harness_heartbeat"] do
    "harness"
  end

  defp humanize_antigravity_event(event, _payload) when is_binary(event), do: event

  defp antigravity_step_summary(tool_name, step_type, state, text_delta) do
    append_antigravity_text_delta(antigravity_step_base(tool_name, step_type, state), text_delta)
  end

  defp antigravity_step_base(tool_name, step_type, state) do
    cond do
      present_trimmed?(tool_name) -> "tool #{tool_name}"
      is_binary(step_type) and is_binary(state) -> "#{step_type} #{state}"
      is_binary(step_type) -> step_type
      is_binary(state) -> state
      true -> "step_update"
    end
  end

  defp append_antigravity_text_delta(base, text_delta) do
    if present_trimmed?(text_delta) do
      "#{base} #{truncate(text_delta, 80)}"
    else
      base
    end
  end

  defp present_trimmed?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_trimmed?(_value), do: false

  defp antigravity_step_update(payload) do
    case map_value(payload, ["step_update", :step_update]) do
      %{} = step -> step
      _ -> payload
    end
  end

  defp sanitize_ansi_and_control_bytes(value) when is_binary(value) do
    Text.strip_ansi_and_control(value)
  end

  defp humanize_agent_method("thread/started", payload) do
    thread_id = map_path(payload, ["params", "thread", "id"]) || map_path(payload, [:params, :thread, :id])

    if is_binary(thread_id) do
      "thread started (#{thread_id})"
    else
      "thread started"
    end
  end

  defp humanize_agent_method("turn/started", payload) do
    turn_id = map_path(payload, ["params", "turn", "id"]) || map_path(payload, [:params, :turn, :id])

    if is_binary(turn_id) do
      "turn started (#{turn_id})"
    else
      "turn started"
    end
  end

  defp humanize_agent_method("turn/completed", payload) do
    status =
      map_path(payload, ["params", "turn", "status"]) ||
        map_path(payload, [:params, :turn, :status]) ||
        "completed"

    usage =
      map_path(payload, ["params", "usage"]) ||
        map_path(payload, [:params, :usage]) ||
        map_path(payload, ["params", "tokenUsage"]) ||
        map_path(payload, [:params, :tokenUsage]) ||
        map_value(payload, ["usage", :usage])

    usage_suffix =
      case format_usage_counts(usage) do
        nil -> ""
        usage_text -> " (#{usage_text})"
      end

    "turn completed (#{status})#{usage_suffix}"
  end

  defp humanize_agent_method("turn/failed", payload) do
    error_message =
      map_path(payload, ["params", "error", "message"]) ||
        map_path(payload, [:params, :error, :message])

    if is_binary(error_message), do: "turn failed: #{error_message}", else: "turn failed"
  end

  defp humanize_agent_method("turn/cancelled", _payload), do: "turn cancelled"

  defp humanize_agent_method("turn/diff/updated", payload) do
    diff =
      map_path(payload, ["params", "diff"]) ||
        map_path(payload, [:params, :diff]) ||
        ""

    if is_binary(diff) and diff != "" do
      line_count = diff |> String.split("\n", trim: true) |> length()
      "turn diff updated (#{line_count} lines)"
    else
      "turn diff updated"
    end
  end

  defp humanize_agent_method("turn/plan/updated", payload) do
    plan_entries =
      map_path(payload, ["params", "plan"]) ||
        map_path(payload, [:params, :plan]) ||
        map_path(payload, ["params", "steps"]) ||
        map_path(payload, [:params, :steps]) ||
        map_path(payload, ["params", "items"]) ||
        map_path(payload, [:params, :items]) ||
        []

    if is_list(plan_entries) do
      "plan updated (#{length(plan_entries)} steps)"
    else
      "plan updated"
    end
  end

  defp humanize_agent_method("thread/tokenUsage/updated", payload) do
    usage =
      map_path(payload, ["params", "tokenUsage", "total"]) ||
        map_path(payload, [:params, :tokenUsage, :total]) ||
        map_value(payload, ["usage", :usage])

    case format_usage_counts(usage) do
      nil -> "thread token usage updated"
      usage_text -> "thread token usage updated (#{usage_text})"
    end
  end

  defp humanize_agent_method("item/started", payload), do: humanize_item_lifecycle("started", payload)
  defp humanize_agent_method("item/completed", payload), do: humanize_item_lifecycle("completed", payload)

  defp humanize_agent_method("item/agentMessage/delta", payload),
    do: humanize_streaming_event("agent message streaming", payload)

  defp humanize_agent_method("item/plan/delta", payload),
    do: humanize_streaming_event("plan streaming", payload)

  defp humanize_agent_method("item/reasoning/summaryTextDelta", payload),
    do: humanize_streaming_event("reasoning summary streaming", payload)

  defp humanize_agent_method("item/reasoning/summaryPartAdded", payload),
    do: humanize_streaming_event("reasoning summary section added", payload)

  defp humanize_agent_method("item/reasoning/textDelta", payload),
    do: humanize_streaming_event("reasoning text streaming", payload)

  defp humanize_agent_method("item/commandExecution/outputDelta", payload),
    do: humanize_streaming_event("command output streaming", payload)

  defp humanize_agent_method("item/fileChange/outputDelta", payload),
    do: humanize_streaming_event("file change output streaming", payload)

  defp humanize_agent_method("item/commandExecution/requestApproval", payload) do
    command = extract_command(payload)

    if is_binary(command) do
      "command approval requested (#{command})"
    else
      "command approval requested"
    end
  end

  defp humanize_agent_method("item/fileChange/requestApproval", payload) do
    change_count = map_path(payload, ["params", "fileChangeCount"]) || map_path(payload, ["params", "changeCount"])

    if is_integer(change_count) and change_count > 0 do
      "file change approval requested (#{change_count} files)"
    else
      "file change approval requested"
    end
  end

  defp humanize_agent_method("item/tool/requestUserInput", payload) do
    question =
      map_path(payload, ["params", "question"]) ||
        map_path(payload, ["params", "prompt"]) ||
        map_path(payload, [:params, :question]) ||
        map_path(payload, [:params, :prompt])

    if is_binary(question) and String.trim(question) != "" do
      "tool requires user input: #{inline_text(question)}"
    else
      "tool requires user input"
    end
  end

  defp humanize_agent_method("tool/requestUserInput", payload),
    do: humanize_agent_method("item/tool/requestUserInput", payload)

  defp humanize_agent_method("account/updated", payload) do
    auth_mode =
      map_path(payload, ["params", "authMode"]) ||
        map_path(payload, [:params, :authMode]) ||
        "unknown"

    "account updated (auth #{auth_mode})"
  end

  defp humanize_agent_method("account/rateLimits/updated", payload) do
    rate_limits =
      map_path(payload, ["params", "rateLimits"]) ||
        map_path(payload, [:params, :rateLimits])

    "rate limits updated: #{format_rate_limits_summary(rate_limits)}"
  end

  defp humanize_agent_method("account/chatgptAuthTokens/refresh", _payload), do: "account auth token refresh requested"

  defp humanize_agent_method("item/tool/call", payload) do
    tool = dynamic_tool_name(payload)

    if is_binary(tool) and String.trim(tool) != "" do
      "dynamic tool call requested (#{tool})"
    else
      "dynamic tool call requested"
    end
  end

  defp humanize_agent_method(<<"claude/event/", suffix::binary>>, payload) do
    humanize_agent_wrapper_event(suffix, payload)
  end

  defp humanize_agent_method(method, payload) do
    msg_type =
      map_path(payload, ["params", "msg", "type"]) ||
        map_path(payload, [:params, :msg, :type])

    if is_binary(msg_type) do
      "#{method} (#{msg_type})"
    else
      method
    end
  end

  defp humanize_dynamic_tool_event(base, payload) do
    case dynamic_tool_name(payload) do
      tool when is_binary(tool) ->
        trimmed = String.trim(tool)

        if trimmed == "" do
          base
        else
          "#{base} (#{trimmed})"
        end

      _ ->
        base
    end
  end

  defp dynamic_tool_name(payload) do
    map_path(payload, ["params", "tool"]) ||
      map_path(payload, ["params", "name"]) ||
      map_path(payload, [:params, :tool]) ||
      map_path(payload, [:params, :name])
  end

  defp humanize_item_lifecycle(state, payload) do
    item =
      map_path(payload, ["params", "item"]) ||
        map_path(payload, [:params, :item]) ||
        %{}

    item_type = item |> map_value(["type", :type]) |> humanize_item_type()
    item_status = map_value(item, ["status", :status])
    item_id = map_value(item, ["id", :id])

    details =
      []
      |> append_if_present(short_id(item_id))
      |> append_if_present(humanize_status(item_status))

    detail_suffix = if details == [], do: "", else: " (#{Enum.join(details, ", ")})"
    "item #{state}: #{item_type}#{detail_suffix}"
  end

  defp humanize_agent_wrapper_event("mcp_startup_update", payload) do
    server =
      map_path(payload, ["params", "msg", "server"]) ||
        map_path(payload, [:params, :msg, :server]) ||
        "mcp"

    state =
      map_path(payload, ["params", "msg", "status", "state"]) ||
        map_path(payload, [:params, :msg, :status, :state]) ||
        "updated"

    "mcp startup: #{server} #{state}"
  end

  defp humanize_agent_wrapper_event("mcp_startup_complete", _payload), do: "mcp startup complete"
  defp humanize_agent_wrapper_event("task_started", _payload), do: "task started"
  defp humanize_agent_wrapper_event("user_message", _payload), do: "user message received"

  defp humanize_agent_wrapper_event("item_started", payload) do
    case wrapper_payload_type(payload) do
      "token_count" -> humanize_agent_wrapper_event("token_count", payload)
      type when is_binary(type) -> "item started (#{humanize_item_type(type)})"
      _ -> "item started"
    end
  end

  defp humanize_agent_wrapper_event("item_completed", payload) do
    case wrapper_payload_type(payload) do
      "token_count" -> humanize_agent_wrapper_event("token_count", payload)
      type when is_binary(type) -> "item completed (#{humanize_item_type(type)})"
      _ -> "item completed"
    end
  end

  defp humanize_agent_wrapper_event("agent_message_delta", payload),
    do: humanize_streaming_event("agent message streaming", payload)

  defp humanize_agent_wrapper_event("agent_message_content_delta", payload),
    do: humanize_streaming_event("agent message content streaming", payload)

  defp humanize_agent_wrapper_event("agent_reasoning_delta", payload),
    do: humanize_streaming_event("reasoning streaming", payload)

  defp humanize_agent_wrapper_event("reasoning_content_delta", payload),
    do: humanize_streaming_event("reasoning content streaming", payload)

  defp humanize_agent_wrapper_event("agent_reasoning_section_break", _payload), do: "reasoning section break"
  defp humanize_agent_wrapper_event("agent_reasoning", payload), do: humanize_reasoning_update(payload)
  defp humanize_agent_wrapper_event("turn_diff", _payload), do: "turn diff updated"
  defp humanize_agent_wrapper_event("exec_command_begin", payload), do: humanize_exec_command_begin(payload)
  defp humanize_agent_wrapper_event("exec_command_end", payload), do: humanize_exec_command_end(payload)
  defp humanize_agent_wrapper_event("exec_command_output_delta", _payload), do: "command output streaming"
  defp humanize_agent_wrapper_event("mcp_tool_call_begin", _payload), do: "mcp tool call started"
  defp humanize_agent_wrapper_event("mcp_tool_call_end", _payload), do: "mcp tool call completed"

  defp humanize_agent_wrapper_event("token_count", payload) do
    usage = extract_first_path(payload, token_usage_paths())

    case format_usage_counts(usage) do
      nil -> "token count update"
      usage_text -> "token count update (#{usage_text})"
    end
  end

  defp humanize_agent_wrapper_event(other, payload) do
    msg_type =
      map_path(payload, ["params", "msg", "type"]) ||
        map_path(payload, [:params, :msg, :type])

    if is_binary(msg_type) do
      "#{other} (#{msg_type})"
    else
      other
    end
  end

  defp humanize_exec_command_begin(payload) do
    command =
      map_path(payload, ["params", "msg", "command"]) ||
        map_path(payload, [:params, :msg, :command]) ||
        map_path(payload, ["params", "msg", "parsed_cmd"]) ||
        map_path(payload, [:params, :msg, :parsed_cmd])

    command = normalize_command(command)

    if is_binary(command) do
      command
    else
      "command started"
    end
  end

  defp humanize_exec_command_end(payload) do
    exit_code =
      map_path(payload, ["params", "msg", "exit_code"]) ||
        map_path(payload, [:params, :msg, :exit_code]) ||
        map_path(payload, ["params", "msg", "exitCode"]) ||
        map_path(payload, [:params, :msg, :exitCode])

    if is_integer(exit_code) do
      "command completed (exit #{exit_code})"
    else
      "command completed"
    end
  end

  defp format_usage_counts(usage) when is_map(usage) do
    input =
      parse_integer(
        map_value(usage, [
          "input_tokens",
          :input_tokens,
          "prompt_tokens",
          :prompt_tokens,
          "inputTokens",
          :inputTokens,
          "promptTokens",
          :promptTokens
        ])
      )

    output =
      parse_integer(
        map_value(usage, [
          "output_tokens",
          :output_tokens,
          "completion_tokens",
          :completion_tokens,
          "outputTokens",
          :outputTokens,
          "completionTokens",
          :completionTokens
        ])
      )

    total =
      parse_integer(
        map_value(usage, [
          "total_tokens",
          :total_tokens,
          "total",
          :total,
          "totalTokens",
          :totalTokens
        ])
      )

    parts =
      []
      |> append_usage_part("in", input)
      |> append_usage_part("out", output)
      |> append_usage_part("total", total)

    case parts do
      [] -> nil
      _ -> Enum.join(parts, ", ")
    end
  end

  defp format_usage_counts(_usage), do: nil

  defp append_usage_part(parts, _label, value) when not is_integer(value), do: parts
  defp append_usage_part(parts, label, value), do: parts ++ ["#{label} #{format_count(value)}"]

  defp format_rate_limits_summary(nil), do: "n/a"

  defp format_rate_limits_summary(rate_limits) when is_map(rate_limits) do
    primary = map_value(rate_limits, ["primary", :primary])
    secondary = map_value(rate_limits, ["secondary", :secondary])

    primary_text = format_rate_limit_bucket_summary(primary)
    secondary_text = format_rate_limit_bucket_summary(secondary)

    cond do
      primary_text != nil and secondary_text != nil -> "primary #{primary_text}; secondary #{secondary_text}"
      primary_text != nil -> "primary #{primary_text}"
      secondary_text != nil -> "secondary #{secondary_text}"
      true -> "n/a"
    end
  end

  defp format_rate_limits_summary(_rate_limits), do: "n/a"

  defp format_rate_limit_bucket_summary(bucket) when is_map(bucket) do
    used_percent = map_value(bucket, ["usedPercent", :usedPercent])
    window_mins = map_value(bucket, ["windowDurationMins", :windowDurationMins])

    cond do
      is_number(used_percent) and is_integer(window_mins) ->
        "#{used_percent}% / #{window_mins}m"

      is_number(used_percent) ->
        "#{used_percent}% used"

      true ->
        nil
    end
  end

  defp format_rate_limit_bucket_summary(_bucket), do: nil

  defp format_error_value(%{"message" => message}) when is_binary(message), do: message
  defp format_error_value(%{message: message}) when is_binary(message), do: message
  defp format_error_value(error), do: inspect(error, limit: 10)

  defp format_reason(message) when is_map(message) do
    case map_value(message, ["reason", :reason]) do
      nil ->
        message
        |> inspect(limit: 10)
        |> inline_text()

      reason ->
        format_error_value(reason)
    end
  end

  defp format_reason(other), do: format_error_value(other)

  defp humanize_streaming_event(label, payload) do
    case extract_delta_preview(payload) do
      nil -> label
      preview -> "#{label}: #{preview}"
    end
  end

  defp humanize_reasoning_update(payload) do
    case extract_reasoning_focus(payload) do
      nil -> "reasoning update"
      focus -> "reasoning update: #{focus}"
    end
  end

  defp extract_reasoning_focus(payload) do
    value = extract_first_path(payload, reasoning_focus_paths())

    if is_binary(value) do
      trimmed = String.trim(value)
      if trimmed == "", do: nil, else: inline_text(trimmed)
    else
      nil
    end
  end

  defp extract_delta_preview(payload) do
    delta = extract_first_path(payload, delta_paths())

    case delta do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: inline_text(trimmed)

      _ ->
        nil
    end
  end

  defp extract_command(payload) do
    payload
    |> map_path(["params", "parsedCmd"])
    |> fallback_command(payload)
    |> normalize_command()
  end

  defp fallback_command(nil, payload) do
    map_path(payload, ["params", "command"]) ||
      map_path(payload, ["params", "cmd"]) ||
      map_path(payload, ["params", "argv"]) ||
      map_path(payload, ["params", "args"])
  end

  defp fallback_command(command, _payload), do: command

  defp normalize_command(%{} = command) do
    binary_command = map_value(command, ["parsedCmd", :parsedCmd, "command", :command, "cmd", :cmd])
    args = map_value(command, ["args", :args, "argv", :argv])

    if is_binary(binary_command) and is_list(args) do
      normalize_command([binary_command | args])
    else
      normalize_command(binary_command || args)
    end
  end

  defp normalize_command(command) when is_binary(command), do: inline_text(command)

  defp normalize_command(command) when is_list(command) do
    if Enum.all?(command, &is_binary/1) do
      command
      |> Enum.join(" ")
      |> inline_text()
    else
      nil
    end
  end

  defp normalize_command(_command), do: nil

  defp humanize_item_type(nil), do: "item"

  defp humanize_item_type(type) when is_binary(type) do
    type
    |> String.replace(Regex.compile!("([a-z0-9])([A-Z])"), "\\1 \\2")
    |> String.replace("_", " ")
    |> String.replace("/", " ")
    |> String.downcase()
    |> String.trim()
  end

  defp humanize_item_type(type), do: to_string(type)

  defp humanize_status(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.replace("-", " ")
    |> String.downcase()
    |> String.trim()
  end

  defp humanize_status(_status), do: nil

  defp short_id(id) when is_binary(id) and byte_size(id) > 12, do: String.slice(id, 0, 12)
  defp short_id(id) when is_binary(id), do: id
  defp short_id(_id), do: nil

  defp append_if_present(list, value) when is_binary(value) and value != "", do: list ++ [value]
  defp append_if_present(list, _value), do: list

  defp wrapper_payload_type(payload) do
    map_path(payload, ["params", "msg", "payload", "type"]) ||
      map_path(payload, [:params, :msg, :payload, :type])
  end

  defp inline_text(text) when is_binary(text) do
    text
    |> String.replace("\n", " ")
    |> String.replace(Regex.compile!("\\s+"), " ")
    |> String.trim()
    |> truncate(80)
  end

  defp inline_text(other), do: other |> to_string() |> inline_text()

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp token_usage_paths do
    [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total]
    ]
  end

  defp delta_paths do
    [
      ["params", "delta"],
      [:params, :delta],
      ["params", "msg", "delta"],
      [:params, :msg, :delta],
      ["params", "textDelta"],
      [:params, :textDelta],
      ["params", "msg", "textDelta"],
      [:params, :msg, :textDelta],
      ["params", "outputDelta"],
      [:params, :outputDelta],
      ["params", "msg", "outputDelta"],
      [:params, :msg, :outputDelta],
      ["params", "text"],
      [:params, :text],
      ["params", "msg", "text"],
      [:params, :msg, :text],
      ["params", "summaryText"],
      [:params, :summaryText],
      ["params", "msg", "summaryText"],
      [:params, :msg, :summaryText],
      ["params", "msg", "content"],
      [:params, :msg, :content],
      ["params", "msg", "payload", "delta"],
      [:params, :msg, :payload, :delta],
      ["params", "msg", "payload", "textDelta"],
      [:params, :msg, :payload, :textDelta],
      ["params", "msg", "payload", "outputDelta"],
      [:params, :msg, :payload, :outputDelta],
      ["params", "msg", "payload", "text"],
      [:params, :msg, :payload, :text],
      ["params", "msg", "payload", "summaryText"],
      [:params, :msg, :payload, :summaryText],
      ["params", "msg", "payload", "content"],
      [:params, :msg, :payload, :content]
    ]
  end

  defp reasoning_focus_paths do
    [
      ["params", "reason"],
      [:params, :reason],
      ["params", "summaryText"],
      [:params, :summaryText],
      ["params", "summary"],
      [:params, :summary],
      ["params", "text"],
      [:params, :text],
      ["params", "msg", "reason"],
      [:params, :msg, :reason],
      ["params", "msg", "summaryText"],
      [:params, :msg, :summaryText],
      ["params", "msg", "summary"],
      [:params, :msg, :summary],
      ["params", "msg", "text"],
      [:params, :msg, :text],
      ["params", "msg", "payload", "reason"],
      [:params, :msg, :payload, :reason],
      ["params", "msg", "payload", "summaryText"],
      [:params, :msg, :payload, :summaryText],
      ["params", "msg", "payload", "summary"],
      [:params, :msg, :payload, :summary],
      ["params", "msg", "payload", "text"],
      [:params, :msg, :payload, :text]
    ]
  end

  defp extract_first_path(payload, paths) do
    Enum.find_value(paths, fn path ->
      map_path(payload, path)
    end)
  end

  defp map_path(data, [key | rest]) when is_map(data) do
    case fetch_map_key(data, key) do
      {:ok, value} when rest == [] -> value
      {:ok, value} -> map_path(value, rest)
      :error -> nil
    end
  end

  defp map_path(_data, _path), do: nil

  defp fetch_map_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        alternate = alternate_key(key)

        if alternate == key do
          :error
        else
          Map.fetch(map, alternate)
        end
    end
  end

  defp alternate_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp alternate_key(key) when is_atom(key), do: Atom.to_string(key)
  defp alternate_key(key), do: key

  defp truncate(value, max) when byte_size(value) > max do
    value |> String.slice(0, max) |> Kernel.<>("...")
  end

  defp truncate(value, _max), do: value

  defp dashboard_enabled? do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      try do
        Mix.env() != :test
      rescue
        _ -> true
      end
    else
      true
    end
  end

  defp keyword_override(opts, key) do
    if Keyword.has_key?(opts, key), do: Keyword.fetch!(opts, key), else: nil
  end

  defp resolve_override(nil, default), do: default
  defp resolve_override(override, _default), do: override
end
