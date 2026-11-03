-- Weekly report over events_clean, not raw analytics.events.
-- Run: docker exec -i clickhouse clickhouse-client --multiquery < weekly-report.sql
-- Same 7-day window in every query so the sections line up.

SELECT
    'summary' AS section,
    uniqExact(session_id) AS sessions,
    count() AS pageviews,
    countIf(event_name = 'affiliate_click') AS affiliate_clicks
FROM analytics.events_clean
WHERE timestamp >= now() - INTERVAL 7 DAY;

SELECT
    channel,
    uniqExact(session_id) AS sessions,
    count() AS pageviews
FROM analytics.events_clean
WHERE timestamp >= now() - INTERVAL 7 DAY
GROUP BY channel
ORDER BY sessions DESC;

SELECT
    pathname,
    uniqExact(session_id) AS sessions,
    count() AS pageviews,
    countIf(event_name = 'affiliate_click') AS affiliate_clicks
FROM analytics.events_clean
WHERE timestamp >= now() - INTERVAL 7 DAY
GROUP BY pathname
ORDER BY sessions DESC
LIMIT 15;

SELECT
    country,
    uniqExact(session_id) AS sessions
FROM analytics.events_clean
WHERE timestamp >= now() - INTERVAL 7 DAY
GROUP BY country
ORDER BY sessions DESC
LIMIT 12;

SELECT
    referrer,
    uniqExact(session_id) AS sessions
FROM analytics.events_clean
WHERE timestamp >= now() - INTERVAL 7 DAY
GROUP BY referrer
ORDER BY sessions DESC
LIMIT 12;
