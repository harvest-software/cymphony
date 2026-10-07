defmodule CymphonyElixir.Agent.StreamSignals do
  @moduledoc """
  Reads the two facts the orchestrator needs from a coding-agent CLI's stdout
  *while it is still running*, one line at a time:

    * the agent's own session id, so an interrupted run can be resumed with
      `--resume` / `exec resume` / `--conversation` instead of starting a fresh
      conversation. Adapters only report it from `parse_output/3`, which runs
      after a clean exit — a run that is killed, stalls, or dies on an API
      error never got that far, and those are exactly the runs worth resuming.
    * a usage-limit rejection ("You've hit your session limit · resets 1am"),
      so the run is parked until the window resets instead of being retried
      every few minutes as an ordinary crash until it is abandoned.

  Every check starts with a substring test, because the runner calls this for
  every stdout line and a stream-json line can be a megabyte: only a line that
  can possibly match is ever JSON-decoded.
  """

  @type usage_limit :: %{resets_at: integer() | nil, limit_type: String.t() | nil, message: String.t()}

  @limit_text_pattern "hit your (?:[a-z-]+ ){0,2}limit\\b"
  @resets_pattern "resets\\s+(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)\\s*\\(UTC\\)"
  @message_max 200

  @doc """
  The session id carried by `line`, for the given agent kind, or `nil`.

  Claude stamps `session_id` on every stream-json event; Codex announces a
  `thread.started` event with `thread_id`; Antigravity carries
  `conversation_id` on its events (top-level or inside `init`).
  """
  @spec session_id(String.t(), String.t()) :: String.t() | nil
  def session_id("claude", line) when is_binary(line) do
    with true <- String.contains?(line, "\"session_id\""),
         %{"session_id" => id} <- decode(line) do
      nonblank(id)
    else
      _ -> nil
    end
  end

  def session_id("codex", line) when is_binary(line) do
    with true <- String.contains?(line, "\"thread_id\""),
         %{"thread_id" => id} <- decode(line) do
      nonblank(id)
    else
      _ -> nil
    end
  end

  def session_id("antigravity", line) when is_binary(line) do
    with true <- String.contains?(line, "\"conversation_id\""),
         %{} = event <- decode(line) do
      nonblank(event["conversation_id"]) || nested_conversation_id(event["init"])
    else
      _ -> nil
    end
  end

  def session_id(_kind, _line), do: nil

  @doc """
  A usage-limit rejection carried by `line`, or `nil`.

  The authoritative signal is Claude's `rate_limit_event` with
  `status: "rejected"`, whose `resetsAt` is a unix timestamp. The text form
  ("You've hit your session limit · resets 12:30am (UTC)") is the fallback for
  a CLI or proxy that prints only the message; its reset time is read only
  when it is stated in UTC, otherwise `resets_at` is `nil` and the caller
  picks a conservative wait.
  """
  @spec usage_limit(String.t(), integer()) :: usage_limit() | nil
  def usage_limit(line, now_unix) when is_binary(line) and is_integer(now_unix) do
    cond do
      String.contains?(line, "\"rate_limit_event\"") -> rate_limit_event(line)
      String.contains?(line, "limit") and String.contains?(line, "hit your") -> limit_text(line, now_unix)
      true -> nil
    end
  end

  def usage_limit(_line, _now_unix), do: nil

  defp rate_limit_event(line) do
    case decode(line) do
      %{"type" => "rate_limit_event", "rate_limit_info" => %{"status" => "rejected"} = info} ->
        %{
          resets_at: positive_integer(info["resetsAt"]),
          limit_type: nonblank(info["rateLimitType"]),
          message: "usage limit reached" <> limit_suffix(info["rateLimitType"])
        }

      _ ->
        nil
    end
  end

  defp limit_text(line, now_unix) do
    text = Regex.compile!(@limit_text_pattern, "i")

    case Regex.run(text, line, return: :index) do
      [{start, _length} | _] ->
        message = line |> binary_part(start, byte_size(line) - start) |> message_excerpt()
        %{resets_at: text_reset_time(message, now_unix), limit_type: nil, message: "You've " <> message}

      nil ->
        nil
    end
  end

  # "resets 12:30am (UTC)" names a wall-clock time, not a date: the reset is
  # the next time the clock reads that, which is today unless it already has.
  defp text_reset_time(message, now_unix) do
    case Regex.run(Regex.compile!(@resets_pattern, "i"), message) do
      [_, hour, minute, meridiem] -> next_utc_occurrence(hour, minute, meridiem, now_unix)
      _ -> nil
    end
  end

  defp next_utc_occurrence(hour, minute, meridiem, now_unix) do
    hour = String.to_integer(hour)
    # An absent `:MM` group comes back as "" from `Regex.run/2`.
    minute = if minute == "", do: 0, else: String.to_integer(minute)

    if hour in 1..12 and minute in 0..59 do
      hour24 = rem(hour, 12) + if(String.downcase(meridiem) == "pm", do: 12, else: 0)
      today = now_unix |> DateTime.from_unix!() |> DateTime.to_date()
      candidate = today |> DateTime.new!(Time.new!(hour24, minute, 0)) |> DateTime.to_unix()
      if candidate > now_unix, do: candidate, else: candidate + 86_400
    end
  end

  # The text sits inside a JSON string (often escaped twice inside a result
  # payload), so stop at the first quote or backslash and keep it short.
  defp message_excerpt(rest) do
    rest
    |> String.split(["\"", "\\"], parts: 2)
    |> hd()
    |> String.trim()
    |> String.slice(0, @message_max)
  end

  defp limit_suffix(type) when is_binary(type) and type != "", do: " (#{type})"
  defp limit_suffix(_type), do: ""

  defp nested_conversation_id(%{"conversation_id" => id}), do: nonblank(id)
  defp nested_conversation_id(_init), do: nil

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, %{} = event} -> event
      _ -> nil
    end
  end

  defp nonblank(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp nonblank(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(value) when is_float(value) and value > 0, do: trunc(value)
  defp positive_integer(_value), do: nil
end
