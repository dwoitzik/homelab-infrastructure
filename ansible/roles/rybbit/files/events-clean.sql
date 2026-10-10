-- Bot-filtered view: drop residential headless bots that re-hit paths
-- (Rybbit's bot_events excluded separately; this catches repeat-heavy sessions)
CREATE OR REPLACE VIEW analytics.events_clean AS
SELECT *
FROM analytics.events
WHERE is_datacenter_asn = 0
  AND session_id NOT IN (SELECT session_id FROM analytics.bot_events)
  AND session_id NOT IN (
    SELECT session_id
    FROM (
      SELECT session_id, count() AS pv, max(cnt) AS max_path_hits
      FROM (
        SELECT session_id, pathname, count() AS cnt
        FROM analytics.events
        GROUP BY session_id, pathname
      )
      GROUP BY session_id
    )
    WHERE pv >= 20 OR max_path_hits >= 5
  );
