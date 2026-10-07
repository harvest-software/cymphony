defmodule CymphonyElixir.Agent.StreamSignalsTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Agent.StreamSignals

  # Captured from a real Claude Code run that hit its five-hour window
  # (2026-10-06, HFE-6662), session id kept, everything else unchanged.
  @rejected ~s({"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1791333000,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":1,"resetsAt":1791333000},"seven_day":{"utilization":0.45,"resetsAt":1791608400}}},"uuid":"6849cdb5-2e86-46da-9535-c84336c4061f","session_id":"4cc90afd-14ea-43c4-ba96-91c87787f747"})

  # 2026-10-06T22:46:36Z, when that run was refused.
  @now 1_791_326_796

  describe "session_id/2" do
    test "reads Claude's session_id from any stream-json event" do
      assert StreamSignals.session_id("claude", ~s({"type":"system","subtype":"init","session_id":"abc-123"})) == "abc-123"
      assert StreamSignals.session_id("claude", @rejected) == "4cc90afd-14ea-43c4-ba96-91c87787f747"
    end

    test "ignores Claude lines without a usable session id" do
      assert StreamSignals.session_id("claude", ~s({"type":"assistant"})) == nil
      assert StreamSignals.session_id("claude", ~s({"type":"x","session_id":""})) == nil
      assert StreamSignals.session_id("claude", ~s({"type":"x","session_id":42})) == nil
      assert StreamSignals.session_id("claude", ~s(not json but mentions "session_id")) == nil
      assert StreamSignals.session_id("claude", ~s(["session_id"])) == nil
    end

    test "reads the Codex thread id" do
      assert StreamSignals.session_id("codex", ~s({"type":"thread.started","thread_id":"th-1"})) == "th-1"
      assert StreamSignals.session_id("codex", ~s({"type":"turn.started"})) == nil
      assert StreamSignals.session_id("codex", ~s({"type":"x","thread_id":"  "})) == nil
    end

    test "reads the Antigravity conversation id, top-level or inside init" do
      assert StreamSignals.session_id("antigravity", ~s({"conversation_id":"conv-1"})) == "conv-1"
      assert StreamSignals.session_id("antigravity", ~s({"type":"init","init":{"conversation_id":"conv-2"}})) == "conv-2"
      assert StreamSignals.session_id("antigravity", ~s({"type":"init","init":"conversation_id"})) == nil
      assert StreamSignals.session_id("antigravity", ~s({"type":"x"})) == nil
    end

    test "an unknown kind or a non-binary line never matches" do
      assert StreamSignals.session_id("other", ~s({"session_id":"abc"})) == nil
      assert StreamSignals.session_id("claude", nil) == nil
    end
  end

  describe "usage_limit/2" do
    test "a rejected rate_limit_event carries its exact reset time" do
      assert %{resets_at: 1_791_333_000, limit_type: "five_hour", message: "usage limit reached (five_hour)"} =
               StreamSignals.usage_limit(@rejected, @now)
    end

    test "an allowed rate_limit_event is not a limit" do
      allowed = String.replace(@rejected, ~s("status":"rejected"), ~s("status":"allowed_warning"))
      assert StreamSignals.usage_limit(allowed, @now) == nil
      assert StreamSignals.usage_limit(~s({"type":"rate_limit_event"}), @now) == nil
    end

    test "a rejection without a reset time or type still counts" do
      line = ~s({"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":"soon"}})
      assert %{resets_at: nil, limit_type: nil, message: "usage limit reached"} = StreamSignals.usage_limit(line, @now)

      float = ~s({"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1791333000.5}})
      assert %{resets_at: 1_791_333_000} = StreamSignals.usage_limit(float, @now)
    end

    test "falls back to the CLI's message text, reading a UTC reset time" do
      line = ~s|{"type":"assistant","message":{"content":[{"type":"text","text":"You've hit your session limit · resets 12:30am (UTC)"}]}}|

      assert %{resets_at: resets_at, limit_type: nil, message: "You've hit your session limit · resets 12:30am (UTC)"} =
               StreamSignals.usage_limit(line, @now)

      assert DateTime.from_unix!(resets_at) == ~U[2026-10-07 00:30:00Z]
    end

    test "a reset time later today is today; pm hours and bare hours parse" do
      line = "Claude AI usage limit: You've hit your limit · resets 11pm (UTC)"
      assert %{resets_at: resets_at} = StreamSignals.usage_limit(line, @now)
      assert DateTime.from_unix!(resets_at) == ~U[2026-10-06 23:00:00Z]

      noon = "You've hit your weekly usage limit · resets 12pm (UTC)"
      assert %{resets_at: noon_at} = StreamSignals.usage_limit(noon, @now)
      assert DateTime.from_unix!(noon_at) == ~U[2026-10-07 12:00:00Z]
    end

    test "an unparseable or non-UTC reset time leaves resets_at nil" do
      assert %{resets_at: nil} = StreamSignals.usage_limit("You've hit your session limit · resets 1am (Pacific/Auckland)", @now)
      assert %{resets_at: nil} = StreamSignals.usage_limit("You've hit your session limit · resets 13am (UTC)", @now)
      assert %{resets_at: nil} = StreamSignals.usage_limit("You've hit your session limit · resets 1:75am (UTC)", @now)
      assert %{resets_at: nil} = StreamSignals.usage_limit("You've hit your session limit", @now)
    end

    test "ordinary output is not a limit" do
      assert StreamSignals.usage_limit(~s({"type":"assistant"}), @now) == nil
      assert StreamSignals.usage_limit("I hit your rate limiter code path; the limit is fine", @now) == nil
      assert StreamSignals.usage_limit(nil, @now) == nil
    end
  end
end
