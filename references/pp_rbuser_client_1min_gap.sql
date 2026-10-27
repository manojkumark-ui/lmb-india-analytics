WITH seg AS (
  SELECT
    mri_session_id,
    CASE WHEN hr BETWEEN 17 AND 23 THEN 'LMB' ELSE 'DBD0_WITHOUT_LMB' END AS segment
  FROM (
    SELECT
      mri_session_id,
      EXTRACT(HOUR FROM AT_TIMEZONE(__time, 'Asia/Kolkata')) AS hr,
      DATE_DIFF('day', CAST(AT_TIMEZONE(__time, 'Asia/Kolkata') AS DATE), CAST(doj AS DATE)) AS dbd,
      ROW_NUMBER() OVER (PARTITION BY mri_session_id ORDER BY __time ASC) AS rn
    FROM user_interaction.search_details
    WHERE
      __time >= CAST('2026-09-06 18:30:00' AS TIMESTAMP)
      AND __time < CAST('2026-09-20 18:30:00' AS TIMESTAMP)
      AND country = 'IND'
      AND os = 'Android'
  )
  WHERE rn = 1 AND dbd = 0
),
pp_raw AS (
  SELECT
    p.mri_client_id,
    p.rb_user_id,
    p.mri_session_id,
    g.segment,
    p.__time AS load_time,
    LAG(p.__time) OVER (
      PARTITION BY p.mri_client_id
      ORDER BY p.__time
    ) AS prev_load_time
  FROM user_interaction.make_payment_details AS p
  INNER JOIN seg AS g
    ON p.mri_session_id = g.mri_session_id
  WHERE
    p.__time >= CAST('2026-09-06 18:30:00' AS TIMESTAMP)
    AND p.__time < CAST('2026-09-20 18:30:00' AS TIMESTAMP)
    AND p.country = 'IND'
    AND p.os = 'Android'
    AND NOT p.mri_client_id IS NULL
    AND NOT p.rb_user_id IS NULL
    AND p.rb_user_id <> 0
),
pp_visits AS (
  SELECT
    mri_client_id,
    rb_user_id,
    mri_session_id,
    segment,
    load_time,
    CAST(DATE_TRUNC('day', AT_TIMEZONE(load_time, 'Asia/Kolkata')) AS DATE) AS doi,
    CASE
      WHEN prev_load_time IS NULL THEN 1
      WHEN DATE_DIFF('second', prev_load_time, load_time) >= 60 THEN 1
      ELSE 0
    END AS is_new_visit
  FROM pp_raw
),
kept AS (
  SELECT *
  FROM pp_visits
  WHERE is_new_visit = 1
),
user_day AS (
  SELECT
    doi,
    segment,
    rb_user_id,
    COUNT(*) AS pp_visits
  FROM kept
  GROUP BY 1, 2, 3
),
user_2w AS (
  SELECT
    segment,
    rb_user_id,
    COUNT(*) AS pp_visits
  FROM kept
  GROUP BY 1, 2
),
daily AS (
  SELECT
    doi,
    segment,
    COUNT(*) AS users,
    AVG(CAST(pp_visits AS DOUBLE)) AS avg_pp_visits,
    SUM(CASE WHEN pp_visits = 1 THEN 1 ELSE 0 END) AS bkt_1,
    SUM(CASE WHEN pp_visits = 2 THEN 1 ELSE 0 END) AS bkt_2,
    SUM(CASE WHEN pp_visits = 3 THEN 1 ELSE 0 END) AS bkt_3,
    SUM(CASE WHEN pp_visits = 4 THEN 1 ELSE 0 END) AS bkt_4,
    SUM(CASE WHEN pp_visits = 5 THEN 1 ELSE 0 END) AS bkt_5,
    SUM(CASE WHEN pp_visits >= 6 THEN 1 ELSE 0 END) AS bkt_5plus
  FROM user_day
  GROUP BY 1, 2
),
weekday_avg AS (
  SELECT
    segment,
    'WEEKDAY' AS grain,
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
    AVG(CAST(users AS DOUBLE)) AS users,
    AVG(avg_pp_visits) AS avg_pp_visits,
    AVG(CAST(bkt_1 AS DOUBLE)) AS users_1,
    AVG(CAST(bkt_2 AS DOUBLE)) AS users_2,
    AVG(CAST(bkt_3 AS DOUBLE)) AS users_3,
    AVG(CAST(bkt_4 AS DOUBLE)) AS users_4,
    AVG(CAST(bkt_5 AS DOUBLE)) AS users_5,
    AVG(CAST(bkt_5plus AS DOUBLE)) AS users_5plus
  FROM daily
  GROUP BY segment, DAY_OF_WEEK(doi)
),
overall_2w AS (
  SELECT
    segment,
    '2W' AS grain,
    CAST(NULL AS INTEGER) AS weekday_no,
    'ALL_DAYS' AS weekday,
    CAST(14 AS BIGINT) AS days_in_avg,
    CAST(COUNT(*) AS DOUBLE) AS users,
    AVG(CAST(pp_visits AS DOUBLE)) AS avg_pp_visits,
    CAST(SUM(CASE WHEN pp_visits = 1 THEN 1 ELSE 0 END) AS DOUBLE) AS users_1,
    CAST(SUM(CASE WHEN pp_visits = 2 THEN 1 ELSE 0 END) AS DOUBLE) AS users_2,
    CAST(SUM(CASE WHEN pp_visits = 3 THEN 1 ELSE 0 END) AS DOUBLE) AS users_3,
    CAST(SUM(CASE WHEN pp_visits = 4 THEN 1 ELSE 0 END) AS DOUBLE) AS users_4,
    CAST(SUM(CASE WHEN pp_visits = 5 THEN 1 ELSE 0 END) AS DOUBLE) AS users_5,
    CAST(SUM(CASE WHEN pp_visits >= 6 THEN 1 ELSE 0 END) AS DOUBLE) AS users_5plus
  FROM user_2w
  GROUP BY segment
)
SELECT
  'Android' AS os,
  segment,
  grain,
  weekday_no,
  weekday,
  days_in_avg,
  users,
  avg_pp_visits,
  users_1,
  users_2,
  users_3,
  users_4,
  users_5,
  users_5plus,
  100.0 * users_1 / NULLIF(users, 0) AS pct_1,
  100.0 * users_2 / NULLIF(users, 0) AS pct_2,
  100.0 * users_3 / NULLIF(users, 0) AS pct_3,
  100.0 * users_4 / NULLIF(users, 0) AS pct_4,
  100.0 * users_5 / NULLIF(users, 0) AS pct_5,
  100.0 * users_5plus / NULLIF(users, 0) AS pct_5plus
FROM (
  SELECT * FROM weekday_avg
  UNION ALL
  SELECT * FROM overall_2w
) AS u
ORDER BY segment, grain, weekday_no
LIMIT 100
