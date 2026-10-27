-- LMB / Inline Viewed + Clicked by day × platform × usertype
-- Coverage = clicked / viewed (7d distinct or Σ daily)

SELECT
  CAST(uue.__time AS DATE) AS event_date,
  uue.event_src,
  CASE
    WHEN UPPER(TRIM(COALESCE(uue.usertype, ''))) = 'GUEST' THEN 'GUEST'
    WHEN UPPER(TRIM(COALESCE(uue.usertype, ''))) = 'NEW' THEN 'NEW'
    WHEN UPPER(TRIM(COALESCE(uue.usertype, ''))) = 'RETURNING' THEN 'RETURNING'
    ELSE 'OTHER'
  END AS usertype_norm,
  uue.event_name,
  uue.event_value,
  COUNT(DISTINCT uue.mri_session_id) AS session_count
FROM user_interaction.ui_ux_events AS uue
WHERE
  uue.__time >= CAST('2026-08-04 00:00:00' AS TIMESTAMP)
  AND uue.__time < CAST('2026-08-11 00:00:00' AS TIMESTAMP)
  AND uue.header_country = 'IND'
  AND uue.event_src IN ('Android', 'iOS')
  AND uue.header_bu = 'BUS'
  AND uue.selected_country = 'India'
  AND uue.event_group = 'srp_filter_event'
  AND uue.event_name IN ('LMB', 'inline', 'Inline')
  AND uue.event_value IN ('Viewed', 'Clicked')
  AND (
    (uue.event_src = 'Android' AND uue.app_version IN ('82.3.0', '82.3.1', '82.3.5', '82.3.6', '82.4.0-IB1'))
    OR (uue.event_src = 'iOS' AND uue.app_version IN ('8.6.7.10', '8.7.0.1', '8.6.9.2', '8.6.8.1'))
  )
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1, 2, 3, 4, 5
LIMIT 500;

-- Inline RTC chips (Clicked filter_applied) — run separately:
-- SELECT event_src, filter_applied, COUNT(DISTINCT mri_session_id) AS sessions
-- WHERE event_name IN ('inline','Inline') AND event_value = 'Clicked'
-- GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 40;
