-- Time on screen, LMB vs Non LMB, by channel.
-- India bus. Last 10 complete IST days: 5 Oct 2026 through 14 Oct 2026.
-- IST day starts 18:30 UTC the previous evening.
--
-- LMB: the session's first India search is on the journey date (DBD 0)
-- and the search hour in IST is 17:00-23:59.
-- Non LMB: every other session.
-- Channel: Android app, iOS app, Others = Mobweb + Desktop.
--
-- Time on a screen = seconds until the next funnel screen load in the same
-- session. Gaps under 0 or over 30 minutes are dropped (session went idle).
-- Screens: Home, Bus Home, SRP, Seat layout, BP/DP, Cust info, Payment, Ticket.

WITH srd AS (
  SELECT mri_session_id, __time, doj, channel, os
  FROM user_interaction.search_route_details
  WHERE __time >= TIMESTAMP '2026-10-04 18:30:00'
    AND __time < TIMESTAMP '2026-10-14 18:30:00'
    AND country = 'IND'
    AND channel IN ('MOBILE_APP', 'MOBILE_WEB', 'WEB_DIRECT')
    AND (akamai_bot IS NULL OR akamai_bot = '')
),
first_search AS (
  SELECT mri_session_id, segment, channel_cut
  FROM (
    SELECT
      mri_session_id,
      CASE
        WHEN dbd = 0 AND hr BETWEEN 17 AND 23 THEN 'LMB'
        ELSE 'Non_LMB'
      END AS segment,
      CASE
        WHEN channel = 'MOBILE_APP' AND os = 'Android' THEN 'Android'
        WHEN channel = 'MOBILE_APP' AND os = 'iOS' THEN 'iOS'
        ELSE 'Others'
      END AS channel_cut,
      ROW_NUMBER() OVER (PARTITION BY mri_session_id ORDER BY __time ASC) AS rn
    FROM (
      SELECT
        mri_session_id,
        channel,
        os,
        __time,
        DATE_DIFF(
          'day',
          CAST(AT_TIMEZONE(__time, 'Asia/Kolkata') AS DATE),
          CAST(doj AS DATE)
        ) AS dbd,
        EXTRACT(HOUR FROM AT_TIMEZONE(__time, 'Asia/Kolkata')) AS hr
      FROM srd
    )
  )
  WHERE rn = 1
),
screens AS (
  SELECT
    mri_session_id,
    __time,
    CASE event_group
      WHEN 'common_home_screen_load' THEN 'Home'
      WHEN 'bus_home_screen_load' THEN 'Bus Home'
      WHEN 'srp_screen_load' THEN 'SRP'
      WHEN 'sl_screen_load' THEN 'Seat layout'
      WHEN 'bp_dp_screen_load' THEN 'BP/DP'
      WHEN 'cust_info_load' THEN 'Cust info'
      WHEN 'payment_screen_load' THEN 'Payment'
      WHEN 'show_ticket_screen_load' THEN 'Ticket'
    END AS screen
  FROM user_interaction.ui_ux_events
  WHERE __time >= TIMESTAMP '2026-10-04 18:30:00'
    AND __time < TIMESTAMP '2026-10-14 18:30:00'
    AND header_country = 'IND'
    AND LOWER(header_bu) = 'bus'
    AND event_group IN (
      'common_home_screen_load',
      'bus_home_screen_load',
      'srp_screen_load',
      'sl_screen_load',
      'bp_dp_screen_load',
      'cust_info_load',
      'payment_screen_load',
      'show_ticket_screen_load'
    )
),
dwell AS (
  SELECT
    mri_session_id,
    screen,
    DATE_DIFF(
      'second',
      __time,
      LEAD(__time) OVER (PARTITION BY mri_session_id ORDER BY __time)
    ) AS seconds_on_screen
  FROM screens
  WHERE screen IS NOT NULL
)
SELECT
  f.segment,
  f.channel_cut,
  d.screen,
  COUNT(*) AS screen_views,
  COUNT(DISTINCT d.mri_session_id) AS sessions,
  ROUND(AVG(d.seconds_on_screen) FILTER (WHERE d.seconds_on_screen BETWEEN 0 AND 1800), 1) AS avg_seconds,
  ROUND(APPROX_PERCENTILE(d.seconds_on_screen, 0.5) FILTER (WHERE d.seconds_on_screen BETWEEN 0 AND 1800), 1) AS median_seconds
FROM dwell d
INNER JOIN first_search f
  ON d.mri_session_id = f.mri_session_id
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3
