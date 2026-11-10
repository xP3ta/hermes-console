-- F0 of the fluidity plan (REPORT-AUDITORIA-FLUIDEZ §4): what the chat's
-- streaming path did during a trace. Needs a qa build run with
-- --dart-define=HERMES_CHAT_STREAM_TRACE=true (lib/core/services/
-- chat_stream_trace.dart): it emits instant events named
-- hermes.chat.stream.{flush,reveal,tail_build,turn_end,highlight}, with
-- character counts only (never text).
--
-- Per point: how many, first and last timestamp, and the mean gap between
-- two in a row (the real cadence on this device, against the 33 ms timers).
-- Frame jank for the same window comes from frame_process_metrics.sql.
WITH target_process AS (
  SELECT upid
  FROM process
  WHERE pid = @TARGET_PID@
), stream AS (
  SELECT s.ts, s.name
  FROM slice s
  JOIN thread_track tt ON s.track_id = tt.id
  JOIN thread t USING (utid)
  WHERE t.upid IN (SELECT upid FROM target_process)
    AND s.name GLOB 'hermes.chat.stream.*'
), gaps AS (
  SELECT
    name,
    ts - LAG(ts) OVER (PARTITION BY name ORDER BY ts) AS gap
  FROM stream
)
SELECT
  stream.name,
  COUNT(*) AS events,
  MIN(stream.ts) AS first_ts,
  MAX(stream.ts) AS last_ts,
  (SELECT AVG(gap) / 1e6 FROM gaps WHERE gaps.name = stream.name) AS mean_gap_ms
FROM stream
GROUP BY stream.name
ORDER BY stream.name;
