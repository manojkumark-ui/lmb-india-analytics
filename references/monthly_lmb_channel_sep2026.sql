-- Sep 2026 IST: Session LMB vs Non_LMB — SRP sessions + transactions by channel.
-- Window: 2026-08-31 18:30 UTC → 2026-09-30 18:30 UTC.
-- transactions = COUNT(DISTINCT tin) confirmed tickets (event_type 101, event_class 2).
-- Non_LMB = every session that is not Session LMB (Except LMB grain).

WITH srd AS (
  SELECT mri_session_id, __time, doj, channel, os
  FROM user_interaction.search_route_details
  WHERE __time >= TIMESTAMP '2026-08-31 18:30:00'
    AND __time < TIMESTAMP '2026-09-30 18:30:00'
    AND country = 'IND'
    AND channel IN ('MOBILE_APP', 'MOBILE_WEB', 'WEB_DIRECT')
    AND (akamai_bot IS NULL OR akamai_bot = '')
),
first_search AS (
  SELECT
    mri_session_id,
    CASE WHEN dbd = 0 AND hr BETWEEN 17 AND 23 THEN 'LMB' ELSE 'Non_LMB' END AS segment,
    channel_cut
  FROM (
    SELECT
      mri_session_id,
      DATE_DIFF('day', CAST(AT_TIMEZONE(__time, 'Asia/Kolkata') AS DATE), CAST(doj AS DATE)) AS dbd,
      EXTRACT(HOUR FROM AT_TIMEZONE(__time, 'Asia/Kolkata')) AS hr,
      CASE
        WHEN channel = 'MOBILE_APP' AND os = 'Android' THEN 'Android'
        WHEN channel = 'MOBILE_APP' AND os = 'iOS' THEN 'iOS'
        ELSE 'Others'
      END AS channel_cut,
      ROW_NUMBER() OVER (PARTITION BY mri_session_id ORDER BY __time ASC) AS rn
    FROM srd
  )
  WHERE rn = 1
),
orders AS (
  SELECT mri_session_id, COUNT(DISTINCT tin) AS transactions
  FROM transaction.bus_ticket_events
  WHERE country_code = 'IND'
    AND event_type = 101
    AND event_class = 2
    AND tin IS NOT NULL
    AND time_of_event >= TIMESTAMP '2026-08-31 18:30:00'
    AND time_of_event < TIMESTAMP '2026-09-30 18:30:00'
  GROUP BY 1
)
SELECT
  segment,
  channel_cut,
  COUNT(*) AS srp,
  SUM(COALESCE(o.transactions, 0)) AS transactions
FROM first_search f
LEFT JOIN orders o ON f.mri_session_id = o.mri_session_id
GROUP BY 1, 2
ORDER BY 1, 2
