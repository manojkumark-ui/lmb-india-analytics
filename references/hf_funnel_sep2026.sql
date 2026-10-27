-- Sep 2026 IST: HF vs Non_HF platform funnel throughput + channel.
-- HF = rb_user_id with >5 distinct confirmed TINs in the trailing 12 months
--   ending analysis window end (2025-09-30 18:30 → 2026-09-30 18:30 UTC).
-- Null / 0 rb_user_id → Non_HF.
-- Funnel: SRP → SL → Cust info → Create order → Payment → Order confirmed + TINs.
-- Platform grain (any route in session). One-month search scan is heavy; if it times out, run one IST day at a time and union.

WITH hf_users AS (
  SELECT rb_user_id
  FROM transaction.bus_ticket_events
  WHERE country_code = 'IND'
    AND event_type = 101
    AND event_class = 2
    AND tin IS NOT NULL
    AND rb_user_id IS NOT NULL
    AND TRY_CAST(rb_user_id AS BIGINT) > 0
    AND time_of_event >= TIMESTAMP '2025-09-30 18:30:00'
    AND time_of_event < TIMESTAMP '2026-09-30 18:30:00'
  GROUP BY rb_user_id
  HAVING COUNT(DISTINCT tin) > 5
),
srd AS (
  SELECT mri_session_id, route_id, __time, channel, os, rb_user_id
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
    CASE WHEN hf.rb_user_id IS NOT NULL THEN 'HF' ELSE 'Non_HF' END AS hf_segment,
    channel_cut
  FROM (
    SELECT
      mri_session_id,
      rb_user_id,
      CASE
        WHEN channel = 'MOBILE_APP' AND os = 'Android' THEN 'Android'
        WHEN channel = 'MOBILE_APP' AND os = 'iOS' THEN 'iOS'
        ELSE 'Others'
      END AS channel_cut,
      ROW_NUMBER() OVER (PARTITION BY mri_session_id ORDER BY __time ASC) AS rn
    FROM srd
  ) s
  LEFT JOIN hf_users hf
    ON TRY_CAST(s.rb_user_id AS BIGINT) > 0
   AND s.rb_user_id = hf.rb_user_id
  WHERE rn = 1
),
srp AS (
  SELECT
    f.hf_segment,
    f.channel_cut,
    s.mri_session_id,
    s.route_id
  FROM srd s
  INNER JOIN first_search f ON s.mri_session_id = f.mri_session_id
  GROUP BY 1, 2, 3, 4
),
sl AS (
  SELECT DISTINCT mri_session_id, route_id
  FROM user_interaction.seat_layout_details
  WHERE __time >= TIMESTAMP '2026-08-31 18:30:00'
    AND __time < TIMESTAMP '2026-09-30 18:30:00'
    AND country = 'IND'
),
ci AS (
  SELECT DISTINCT mri_session_id, route_id
  FROM user_interaction.cust_info_details
  WHERE __time >= TIMESTAMP '2026-08-31 18:30:00'
    AND __time < TIMESTAMP '2026-09-30 18:30:00'
    AND country = 'IND'
),
co AS (
  SELECT DISTINCT mri_session_id, route_id
  FROM user_interaction.create_order_details
  WHERE __time >= TIMESTAMP '2026-08-31 18:30:00'
    AND __time < TIMESTAMP '2026-09-30 18:30:00'
    AND country = 'IND'
),
pp AS (
  SELECT DISTINCT mri_session_id, route_id
  FROM user_interaction.order_info_details
  WHERE __time >= TIMESTAMP '2026-08-31 18:30:00'
    AND __time < TIMESTAMP '2026-09-30 18:30:00'
    AND country = 'IND'
),
oc AS (
  SELECT
    mri_session_id,
    CAST(route_id AS BIGINT) AS route_id,
    COUNT(DISTINCT tin) AS tins
  FROM transaction.bus_ticket_events
  WHERE country_code = 'IND'
    AND event_type = 101
    AND event_class = 2
    AND tin IS NOT NULL
    AND time_of_event >= TIMESTAMP '2026-08-31 18:30:00'
    AND time_of_event < TIMESTAMP '2026-09-30 18:30:00'
  GROUP BY 1, 2
),
base AS (
  SELECT
    s.hf_segment,
    s.channel_cut,
    s.mri_session_id,
    sl.mri_session_id AS sl_s,
    ci.mri_session_id AS ci_s,
    co.mri_session_id AS co_s,
    pp.mri_session_id AS pp_s,
    oc.mri_session_id AS oc_s,
    COALESCE(oc.tins, 0) AS tins
  FROM srp s
  LEFT JOIN sl ON s.mri_session_id = sl.mri_session_id AND s.route_id = sl.route_id
  LEFT JOIN ci ON s.mri_session_id = ci.mri_session_id AND s.route_id = ci.route_id
  LEFT JOIN co ON s.mri_session_id = co.mri_session_id AND s.route_id = co.route_id
  LEFT JOIN pp ON s.mri_session_id = pp.mri_session_id AND s.route_id = pp.route_id
  LEFT JOIN oc ON s.mri_session_id = oc.mri_session_id AND s.route_id = oc.route_id
),
sess AS (
  SELECT
    hf_segment,
    channel_cut,
    mri_session_id,
    1 AS srp,
    MAX(CASE WHEN sl_s IS NOT NULL THEN 1 ELSE 0 END) AS sl,
    MAX(CASE WHEN ci_s IS NOT NULL THEN 1 ELSE 0 END) AS cust_info,
    MAX(CASE WHEN co_s IS NOT NULL THEN 1 ELSE 0 END) AS create_order,
    MAX(CASE WHEN pp_s IS NOT NULL THEN 1 ELSE 0 END) AS payment_page,
    MAX(CASE WHEN oc_s IS NOT NULL THEN 1 ELSE 0 END) AS order_confirmed,
    SUM(tins) AS transactions
  FROM base
  GROUP BY 1, 2, 3
)
SELECT
  hf_segment,
  channel_cut,
  SUM(srp) AS srp,
  SUM(sl) AS sl,
  SUM(cust_info) AS cust_info,
  SUM(create_order) AS create_order,
  SUM(payment_page) AS payment_page,
  SUM(order_confirmed) AS order_confirmed,
  SUM(transactions) AS transactions
FROM sess
GROUP BY 1, 2
ORDER BY 1, 2
