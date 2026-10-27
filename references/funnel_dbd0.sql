-- LMB vs Non LMB, DBD 0, India
-- Steps: SRP, SL, Cust_Info, Create_Order, Payment_Page, Order_Confirmed, Transactions
-- CR = Transactions / SRP sessions
--
-- LMB      = first search of the session at IST hour 17-23, and DOJ = that IST date
-- Non_LMB  = same DBD 0, any other hour
-- Top 200 / Top 500 = source-destination pairs ranked by confirmed TINs
--   over the FULL window below (keep this ranking window fixed when you loop days)
-- A step counts in Top 200 / Top 500 only when it happened on a route in that set.
-- Platform counts the step on any route in the session.
--
-- This scan times out over several days. Run one IST day at a time:
--   IST day D  =>  __time >= (D-1) 18:30:00 UTC  AND  __time < D 18:30:00 UTC
-- Example for 12 Oct 2026: start 2026-10-11 18:30:00, end 2026-10-12 18:30:00
-- Union the daily results. Do not change the ranked_sd window.

WITH srd AS (
  SELECT
    mri_session_id,
    route_id,
    src_id,
    dest_id,
    __time,
    doj,
    channel,
    os,
    user_type
  FROM user_interaction.search_route_details
  WHERE __time >= TIMESTAMP '2026-10-11 18:30:00'   -- one IST day: change this
    AND __time <  TIMESTAMP '2026-10-12 18:30:00'   -- and this
    AND country = 'IND'
    AND channel IN ('MOBILE_APP', 'MOBILE_WEB', 'WEB_DIRECT')
    AND (akamai_bot IS NULL OR akamai_bot = '')
),
first_search AS (
  SELECT
    mri_session_id,
    doi,
    CASE WHEN hr BETWEEN 17 AND 23 THEN 'LMB' ELSE 'Non_LMB' END AS segment,
    channel_cut,
    user_type_cut
  FROM (
    SELECT
      mri_session_id,
      CAST(DATE_TRUNC('day', AT_TIMEZONE(__time, 'Asia/Kolkata')) AS DATE) AS doi,
      DATE_DIFF('day', CAST(AT_TIMEZONE(__time, 'Asia/Kolkata') AS DATE), CAST(doj AS DATE)) AS dbd,
      EXTRACT(HOUR FROM AT_TIMEZONE(__time, 'Asia/Kolkata')) AS hr,
      CASE
        WHEN channel = 'MOBILE_APP' AND os = 'Android' THEN 'Android'
        WHEN channel = 'MOBILE_APP' AND os = 'iOS' THEN 'iOS'
        WHEN channel = 'MOBILE_WEB' THEN 'Mobweb'
        WHEN channel = 'WEB_DIRECT' THEN 'Desktop'
        ELSE 'Other'
      END AS channel_cut,
      CASE
        WHEN UPPER(user_type) = 'NEW' THEN 'NEW'
        WHEN UPPER(user_type) = 'RETURNING' THEN 'RETURNING'
        WHEN UPPER(user_type) = 'GUEST' THEN 'GUEST'
        ELSE 'UNKNOWN'
      END AS user_type_cut,
      ROW_NUMBER() OVER (PARTITION BY mri_session_id ORDER BY __time ASC) AS rn
    FROM srd
  )
  WHERE rn = 1
    AND dbd = 0
),
ranked_sd AS (
  SELECT
    CAST(source_location_id AS BIGINT) AS src_id,
    CAST(destination_location_id AS BIGINT) AS dest_id,
    ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT tin) DESC) AS sd_rank
  FROM transaction.bus_ticket_events
  WHERE country_code = 'IND'
    AND event_type = 101
    AND event_class = 2
    AND tin IS NOT NULL
    AND time_of_event >= TIMESTAMP '2026-10-02 18:30:00'  -- full 10-day rank window
    AND time_of_event <  TIMESTAMP '2026-10-12 18:30:00'
    AND source_location_id IS NOT NULL
    AND destination_location_id IS NOT NULL
  GROUP BY 1, 2
),
srp AS (
  SELECT
    f.doi,
    f.segment,
    f.channel_cut,
    f.user_type_cut,
    s.mri_session_id,
    s.route_id,
    MIN(COALESCE(r.sd_rank, 999999)) AS sd_rank
  FROM srd s
  INNER JOIN first_search f
    ON s.mri_session_id = f.mri_session_id
  LEFT JOIN ranked_sd r
    ON s.src_id = r.src_id
   AND s.dest_id = r.dest_id
  GROUP BY 1, 2, 3, 4, 5, 6
),
sl AS (
  SELECT DISTINCT mri_session_id, route_id
  FROM user_interaction.seat_layout_details
  WHERE __time >= TIMESTAMP '2026-10-11 18:30:00'
    AND __time <  TIMESTAMP '2026-10-12 18:30:00'
    AND country = 'IND'
),
ci AS (
  SELECT DISTINCT mri_session_id, route_id
  FROM user_interaction.cust_info_details
  WHERE __time >= TIMESTAMP '2026-10-11 18:30:00'
    AND __time <  TIMESTAMP '2026-10-12 18:30:00'
    AND country = 'IND'
),
co AS (
  SELECT DISTINCT mri_session_id, route_id
  FROM user_interaction.create_order_details
  WHERE __time >= TIMESTAMP '2026-10-11 18:30:00'
    AND __time <  TIMESTAMP '2026-10-12 18:30:00'
    AND country = 'IND'
),
pp AS (
  SELECT DISTINCT mri_session_id, route_id
  FROM user_interaction.order_info_details
  WHERE __time >= TIMESTAMP '2026-10-11 18:30:00'
    AND __time <  TIMESTAMP '2026-10-12 18:30:00'
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
    AND time_of_event >= TIMESTAMP '2026-10-11 18:30:00'
    AND time_of_event <  TIMESTAMP '2026-10-12 18:30:00'
  GROUP BY 1, 2
),
base AS (
  SELECT
    s.doi,
    s.segment,
    s.channel_cut,
    s.user_type_cut,
    s.mri_session_id,
    s.sd_rank,
    sl.mri_session_id AS sl_s,
    ci.mri_session_id AS ci_s,
    co.mri_session_id AS co_s,
    pp.mri_session_id AS pp_s,
    oc.mri_session_id AS oc_s,
    COALESCE(oc.tins, 0) AS tins
  FROM srp s
  LEFT JOIN sl
    ON s.mri_session_id = sl.mri_session_id AND s.route_id = sl.route_id
  LEFT JOIN ci
    ON s.mri_session_id = ci.mri_session_id AND s.route_id = ci.route_id
  LEFT JOIN co
    ON s.mri_session_id = co.mri_session_id AND s.route_id = co.route_id
  LEFT JOIN pp
    ON s.mri_session_id = pp.mri_session_id AND s.route_id = pp.route_id
  LEFT JOIN oc
    ON s.mri_session_id = oc.mri_session_id AND s.route_id = oc.route_id
),
sess AS (
  SELECT
    doi,
    segment,
    channel_cut,
    user_type_cut,
    mri_session_id,
    MAX(CASE WHEN sd_rank <= 200 THEN 1 ELSE 0 END) AS t2_srp,
    MAX(CASE WHEN sd_rank <= 200 AND sl_s IS NOT NULL THEN 1 ELSE 0 END) AS t2_sl,
    MAX(CASE WHEN sd_rank <= 200 AND ci_s IS NOT NULL THEN 1 ELSE 0 END) AS t2_ci,
    MAX(CASE WHEN sd_rank <= 200 AND co_s IS NOT NULL THEN 1 ELSE 0 END) AS t2_co,
    MAX(CASE WHEN sd_rank <= 200 AND pp_s IS NOT NULL THEN 1 ELSE 0 END) AS t2_pp,
    MAX(CASE WHEN sd_rank <= 200 AND oc_s IS NOT NULL THEN 1 ELSE 0 END) AS t2_oc,
    SUM(CASE WHEN sd_rank <= 200 THEN tins ELSE 0 END) AS t2_tx,
    MAX(CASE WHEN sd_rank <= 500 THEN 1 ELSE 0 END) AS t5_srp,
    MAX(CASE WHEN sd_rank <= 500 AND sl_s IS NOT NULL THEN 1 ELSE 0 END) AS t5_sl,
    MAX(CASE WHEN sd_rank <= 500 AND ci_s IS NOT NULL THEN 1 ELSE 0 END) AS t5_ci,
    MAX(CASE WHEN sd_rank <= 500 AND co_s IS NOT NULL THEN 1 ELSE 0 END) AS t5_co,
    MAX(CASE WHEN sd_rank <= 500 AND pp_s IS NOT NULL THEN 1 ELSE 0 END) AS t5_pp,
    MAX(CASE WHEN sd_rank <= 500 AND oc_s IS NOT NULL THEN 1 ELSE 0 END) AS t5_oc,
    SUM(CASE WHEN sd_rank <= 500 THEN tins ELSE 0 END) AS t5_tx,
    1 AS pl_srp,
    MAX(CASE WHEN sl_s IS NOT NULL THEN 1 ELSE 0 END) AS pl_sl,
    MAX(CASE WHEN ci_s IS NOT NULL THEN 1 ELSE 0 END) AS pl_ci,
    MAX(CASE WHEN co_s IS NOT NULL THEN 1 ELSE 0 END) AS pl_co,
    MAX(CASE WHEN pp_s IS NOT NULL THEN 1 ELSE 0 END) AS pl_pp,
    MAX(CASE WHEN oc_s IS NOT NULL THEN 1 ELSE 0 END) AS pl_oc,
    SUM(tins) AS pl_tx
  FROM base
  GROUP BY 1, 2, 3, 4, 5
)
SELECT
  segment,
  doi,
  CASE WHEN GROUPING(channel_cut) = 0 THEN channel_cut ELSE 'ALL' END AS channel,
  CASE WHEN GROUPING(user_type_cut) = 0 THEN user_type_cut ELSE 'ALL' END AS user_type,
  SUM(t2_srp) AS top200_srp,
  SUM(t2_sl) AS top200_sl,
  SUM(t2_ci) AS top200_cust_info,
  SUM(t2_co) AS top200_create_order,
  SUM(t2_pp) AS top200_payment_page,
  SUM(t2_oc) AS top200_order_confirmed,
  SUM(t2_tx) AS top200_transactions,
  SUM(t5_srp) AS top500_srp,
  SUM(t5_sl) AS top500_sl,
  SUM(t5_ci) AS top500_cust_info,
  SUM(t5_co) AS top500_create_order,
  SUM(t5_pp) AS top500_payment_page,
  SUM(t5_oc) AS top500_order_confirmed,
  SUM(t5_tx) AS top500_transactions,
  SUM(pl_srp) AS platform_srp,
  SUM(pl_sl) AS platform_sl,
  SUM(pl_ci) AS platform_cust_info,
  SUM(pl_co) AS platform_create_order,
  SUM(pl_pp) AS platform_payment_page,
  SUM(pl_oc) AS platform_order_confirmed,
  SUM(pl_tx) AS platform_transactions
FROM sess
GROUP BY GROUPING SETS (
  (segment, doi),
  (segment, doi, channel_cut),
  (segment, doi, user_type_cut),
  (segment, doi, channel_cut, user_type_cut)
)
