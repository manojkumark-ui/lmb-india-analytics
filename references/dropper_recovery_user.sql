WITH seg AS (
  SELECT
    mri_session_id,
    CASE WHEN hr BETWEEN 17 AND 23 THEN 'LMB' ELSE 'DBD0_WITHOUT_LMB' END AS segment,
    user_key
  FROM (
    SELECT
      mri_session_id,
      EXTRACT(HOUR FROM AT_TIMEZONE(__time, 'Asia/Kolkata')) AS hr,
      DATE_DIFF('day', CAST(AT_TIMEZONE(__time, 'Asia/Kolkata') AS DATE), CAST(doj AS DATE)) AS dbd,
      COALESCE(NULLIF(CAST(rb_user_id AS VARCHAR), '0'), mri_client_id) AS user_key,
      ROW_NUMBER() OVER (PARTITION BY mri_session_id ORDER BY __time ASC) AS rn
    FROM user_interaction.search_details
    WHERE
      __time >= CAST('2026-09-06 18:30:00' AS TIMESTAMP)
      AND __time < CAST('2026-09-20 18:30:00' AS TIMESTAMP)
      AND country = 'IND'
      AND os = 'Android'
  )
  WHERE
    rn = 1
    AND dbd = 0
    AND NOT user_key IS NULL
),
srp AS (
  SELECT
    CAST(DATE_TRUNC('day', AT_TIMEZONE(s.__time, 'Asia/Kolkata')) AS DATE) AS doi,
    s.os,
    g.segment,
    COUNT(DISTINCT g.user_key) AS srp_users
  FROM user_interaction.search_route_details AS s
  INNER JOIN seg AS g
    ON s.mri_session_id = g.mri_session_id
  WHERE
    s.__time >= CAST('2026-09-06 18:30:00' AS TIMESTAMP)
    AND s.__time < CAST('2026-09-20 18:30:00' AS TIMESTAMP)
    AND s.country = 'IND'
    AND s.os = 'Android'
  GROUP BY 1, 2, 3
),
pp_sessions AS (
  SELECT
    o.mri_session_id,
    o.os,
    g.segment,
    CAST(DATE_TRUNC('day', AT_TIMEZONE(MIN(o.__time), 'Asia/Kolkata')) AS DATE) AS doi,
    MAX(o.__time) AS last_pp_time,
    COALESCE(
      NULLIF(CAST(MAX(o.rb_user_id) AS VARCHAR), '0'),
      MAX(o.mri_client_id),
      MAX(g.user_key)
    ) AS user_key
  FROM user_interaction.order_info_details AS o
  INNER JOIN seg AS g
    ON o.mri_session_id = g.mri_session_id
  WHERE
    o.__time >= CAST('2026-09-06 18:30:00' AS TIMESTAMP)
    AND o.__time < CAST('2026-09-20 18:30:00' AS TIMESTAMP)
    AND o.country = 'IND'
    AND o.os = 'Android'
  GROUP BY
    o.mri_session_id,
    o.os,
    g.segment
),
pp_daily AS (
  SELECT doi, os, segment, COUNT(DISTINCT user_key) AS payment_page_users
  FROM pp_sessions
  WHERE NOT user_key IS NULL
  GROUP BY 1, 2, 3
),
confirmed_sessions AS (
  SELECT DISTINCT mri_session_id
  FROM transaction.bus_ticket_events
  WHERE
    country_code = 'IND'
    AND event_type = 101
    AND event_class = 2
    AND NOT tin IS NULL
    AND time_of_event >= CAST('2026-09-06 18:30:00' AS TIMESTAMP)
    AND time_of_event < CAST('2026-09-22 18:30:00' AS TIMESTAMP)
),
session_droppers AS (
  SELECT
    p.doi,
    p.os,
    p.segment,
    p.mri_session_id,
    p.last_pp_time AS drop_time,
    p.user_key
  FROM pp_sessions AS p
  LEFT JOIN confirmed_sessions AS c
    ON p.mri_session_id = c.mri_session_id
  WHERE
    c.mri_session_id IS NULL
    AND NOT p.user_key IS NULL
),
droppers AS (
  SELECT
    doi,
    os,
    segment,
    user_key,
    MIN(drop_time) AS drop_time
  FROM session_droppers
  GROUP BY 1, 2, 3, 4
),
tickets AS (
  SELECT
    tin,
    mri_session_id,
    time_of_event,
    COALESCE(NULLIF(CAST(rb_user_id AS VARCHAR), '0'), mri_client_id) AS user_key
  FROM transaction.bus_ticket_events
  WHERE
    country_code = 'IND'
    AND event_type = 101
    AND event_class = 2
    AND NOT tin IS NULL
    AND time_of_event >= CAST('2026-09-06 18:30:00' AS TIMESTAMP)
    AND time_of_event < CAST('2026-09-22 18:30:00' AS TIMESTAMP)
),
offer_sessions AS (
  SELECT DISTINCT mri_session_id
  FROM user_interaction.order_info_details
  WHERE
    __time >= CAST('2026-09-06 18:30:00' AS TIMESTAMP)
    AND __time < CAST('2026-09-22 18:30:00' AS TIMESTAMP)
    AND country = 'IND'
    AND os = 'Android'
    AND offer_status = 200.0
),
ranked_recovery AS (
  SELECT
    d.doi,
    d.os,
    d.segment,
    d.user_key,
    t.tin,
    t.mri_session_id AS txn_session_id,
    DATE_DIFF('hour', d.drop_time, t.time_of_event) AS hours_to_txn,
    ROW_NUMBER() OVER (
      PARTITION BY d.doi, d.os, d.segment, d.user_key
      ORDER BY t.time_of_event
    ) AS rn
  FROM droppers AS d
  INNER JOIN tickets AS t
    ON d.user_key = t.user_key
    AND t.time_of_event > d.drop_time
    AND t.time_of_event <= d.drop_time + INTERVAL '48' HOUR
),
first_recovery AS (
  SELECT
    r.doi,
    r.os,
    r.segment,
    r.user_key,
    r.hours_to_txn,
    CASE WHEN NOT o.mri_session_id IS NULL THEN 1 ELSE 0 END AS with_offer
  FROM ranked_recovery AS r
  LEFT JOIN offer_sessions AS o
    ON r.txn_session_id = o.mri_session_id
  WHERE r.rn = 1
),
daily AS (
  SELECT
    COALESCE(s.doi, p.doi, d.doi) AS doi,
    COALESCE(s.os, p.os, d.os) AS os,
    COALESCE(s.segment, p.segment, d.segment) AS segment,
    COALESCE(s.srp_users, 0) AS srp_users,
    COALESCE(p.payment_page_users, 0) AS payment_page_users,
    COALESCE(d.dropper_users, 0) AS dropper_users,
    COALESCE(d.txn_24h_with_offer, 0) AS txn_24h_with_offer,
    COALESCE(d.txn_24h_without_offer, 0) AS txn_24h_without_offer,
    COALESCE(d.txn_48h_with_offer, 0) AS txn_48h_with_offer,
    COALESCE(d.txn_48h_without_offer, 0) AS txn_48h_without_offer,
    COALESCE(d.not_transacted_48h, 0) AS not_transacted_48h
  FROM srp AS s
  FULL OUTER JOIN pp_daily AS p
    ON s.doi = p.doi AND s.os = p.os AND s.segment = p.segment
  FULL OUTER JOIN (
    SELECT
      d.doi,
      d.os,
      d.segment,
      COUNT(*) AS dropper_users,
      SUM(CASE WHEN f.hours_to_txn <= 24 AND f.with_offer = 1 THEN 1 ELSE 0 END) AS txn_24h_with_offer,
      SUM(CASE WHEN f.hours_to_txn <= 24 AND f.with_offer = 0 THEN 1 ELSE 0 END) AS txn_24h_without_offer,
      SUM(CASE WHEN NOT f.user_key IS NULL AND f.with_offer = 1 THEN 1 ELSE 0 END) AS txn_48h_with_offer,
      SUM(CASE WHEN NOT f.user_key IS NULL AND f.with_offer = 0 THEN 1 ELSE 0 END) AS txn_48h_without_offer,
      SUM(CASE WHEN f.user_key IS NULL THEN 1 ELSE 0 END) AS not_transacted_48h
    FROM droppers AS d
    LEFT JOIN first_recovery AS f
      ON d.doi = f.doi
      AND d.os = f.os
      AND d.segment = f.segment
      AND d.user_key = f.user_key
    GROUP BY 1, 2, 3
  ) AS d
    ON COALESCE(s.doi, p.doi) = d.doi
    AND COALESCE(s.os, p.os) = d.os
    AND COALESCE(s.segment, p.segment) = d.segment
)
SELECT
  os,
  segment,
  DAY_OF_WEEK(doi) AS weekday_no,
  CASE DAY_OF_WEEK(doi)
    WHEN 1 THEN 'Monday'
    WHEN 2 THEN 'Tuesday'
    WHEN 3 THEN 'Wednesday'
    WHEN 4 THEN 'Thursday'
    WHEN 5 THEN 'Friday'
    WHEN 6 THEN 'Saturday'
    ELSE 'Sunday'
  END AS weekday,
  COUNT(DISTINCT doi) AS days_in_avg,
  AVG(CAST(srp_users AS DOUBLE)) AS srp_users,
  AVG(CAST(payment_page_users AS DOUBLE)) AS payment_page_users,
  AVG(CAST(dropper_users AS DOUBLE)) AS dropper_users,
  AVG(CAST(txn_24h_with_offer AS DOUBLE)) AS txn_24h_with_offer,
  AVG(CAST(txn_24h_without_offer AS DOUBLE)) AS txn_24h_without_offer,
  AVG(CAST(txn_48h_with_offer AS DOUBLE)) AS txn_48h_with_offer,
  AVG(CAST(txn_48h_without_offer AS DOUBLE)) AS txn_48h_without_offer,
  AVG(CAST(not_transacted_48h AS DOUBLE)) AS not_transacted_48h
FROM daily
GROUP BY os, segment, DAY_OF_WEEK(doi)
ORDER BY os, segment, weekday_no
LIMIT 100
