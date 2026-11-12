-- Drop datacenter bots, bot_events, repeat-heavy sessions, and the
-- 1280x1200 headless Chrome crawl (empty timezone + country/ASN). Screen
-- size alone is too broad, so the empty timezone is required too.
CREATE OR REPLACE VIEW analytics.events_clean AS
SELECT *
FROM analytics.events
WHERE is_datacenter_asn = 0
  AND session_id NOT IN (SELECT session_id FROM analytics.bot_events)
  AND session_id NOT IN (
    SELECT session_id
    FROM analytics.events
    WHERE screen_width = 1280
      AND screen_height = 1200
      AND timezone = ''
  )
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
