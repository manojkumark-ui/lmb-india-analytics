---
name: lmb-india-analytics
description: >-
  redBus India last-minute bus (LMB) SQL: session LMB vs rest of DBD 0, LMB vs
  everything except LMB, monthly SRP and orders, ticket cuts, screen time, and
  HF (high-frequency) users. Use when the user asks about LMB, Non LMB, Except
  LMB, DBD 0, last-minute bus, LMB funnel, LMB CR, LMB screen time, LMB
  transaction cuts, HF, or high-frequency users.
---

# India LMB analytics

Run the SQL in [`references/`](references/) on Data Platform / Iceberg. Change only the UTC window. IST day start = previous day `18:30` UTC.

Country `IND`. Confirmed ticket: `transaction.bus_ticket_events`, `country_code = 'IND'`, `event_type = 101`, `event_class = 2`, `tin` not null. Bots: `akamai_bot IS NULL OR akamai_bot = ''`. Channels: `MOBILE_APP`, `MOBILE_WEB`, `WEB_DIRECT`.

Channel cut: `MOBILE_APP` + Android → Android; `MOBILE_APP` + iOS → iOS; else Others (Mobweb + Desktop).

## HF (high-frequency users)

**HF** = users with **more than 5** confirmed bookings (`tin`) in the **last year**. Confirmed ticket filters as above (`IND`, `event_type = 101`, `event_class = 2`, `tin` not null). Count distinct TINs per `rb_user_id` over the trailing 12 months ending at the analysis window (or as the user specifies). Not the same as Ticket LMB heavy users unless both cuts are applied.

## Two LMB definitions

Use the definition that matches the grain. Do not mix them in one comparison.

**Session LMB** — first row of the session (`ROW_NUMBER` by `__time`). LMB when `DATE_DIFF` from IST search date to `doj` is 0 and IST hour is 17–23. Non LMB / Except LMB is every other session. Rest of DBD 0 is the other hours on that same departure day only.

**Ticket LMB** — the confirmed ticket is issued 17:00–23:59 IST and the journey date is that same IST date. Used only by [transaction_cuts.sql](references/transaction_cuts.sql). Channel and user type sit on every cut in that file.

`transaction_cuts.sql` also cuts tickets by:

- DOJ−DOI: hours from issue to journey start. `0-1` is under 1 hour.
- SD tier: Mehar city map, source to destination, for example `Tier 1 -> Pilgrim`. Unlisted cities are Tier 3.
- Distance: `Short` when the SD is in `lis.short_route_sds` for the journey year. Else `Long`.
- Travel duration: boarding in IST to local arrival. `<3h`, `3-6h`, `6-9h`, `9-12h`, `12h+`.
- Week part: Friday, Saturday, and Sunday are `Weekend`. Monday–Thursday are `Weekday`.
- Route path: `Through` when `lis.routes.is_via = 0`. Else `Via`.
- Passenger mix, in seat order: `m`, `f`, `mm`, `ff`, `mf`, `fm`. Other party sizes are `Other`.

## Which file

| Ask | File | Definition |
|---|---|---|
| Page funnel, LMB vs rest of DBD 0, top 200 / 500 / all routes | [funnel_dbd0.sql](references/funnel_dbd0.sql) | Session, DBD 0 only |
| Same funnel, LMB vs anything except LMB | [funnel_except_lmb.sql](references/funnel_except_lmb.sql) | Session |
| Monthly SRP sessions and orders, channel × user type | [monthly_srp_orders.sql](references/monthly_srp_orders.sql) | Session |
| Ticket cuts by channel and user type: booking, ASP, region, route, operator, DOJ−DOI hours, SD tier, short/long, travel duration, weekday/weekend, through/via, passenger mix | [transaction_cuts.sql](references/transaction_cuts.sql) | Ticket |
| Month-on-month ticket cuts, Jan 2025–Sep 2026, channel × user type: distance, travel duration, week part, route path, passenger mix | [mom_cuts_jan2025_sep2026.sql](references/mom_cuts_jan2025_sep2026.sql) | Ticket |
| Seconds on funnel screens, last 10 days, by channel | [screen_time_last10d.sql](references/screen_time_last10d.sql) | Session |
| Weekday dropper recovery, session | [dropper_recovery_session.sql](references/dropper_recovery_session.sql) | Session, DBD 0, Android |
| Same cut, user grain | [dropper_recovery_user.sql](references/dropper_recovery_user.sql) | Session, DBD 0, Android |
| Payment-page visit frequency | [pp_visit_freq_user.sql](references/pp_visit_freq_user.sql) | Session, DBD 0, Android |
| RB user / client, 1-minute gap | [pp_rbuser_client_1min_gap.sql](references/pp_rbuser_client_1min_gap.sql) | Session, DBD 0, Android |
| LMB and inline filter viewed vs clicked | [lmb_inline_filter.sql](references/lmb_inline_filter.sql) | Filter events, not the LMB segment |

## Funnel steps

`funnel_dbd0.sql` and `funnel_except_lmb.sql`: SRP (`search_route_details`) → seat layout → cust info → create order → payment page → order confirmed, plus distinct TINs. A step counts on Top 200 or Top 500 only when that step's source × destination is in the rank set. Rank the pairs on the full analysis window, not on each day. Pay Now is not in these files.

CR = distinct TINs / SRP sessions. Recompute CR from sums. Do not average daily CRs.

## Screen time

Seconds from a screen load until the next funnel screen load in the same session. Drop gaps outside 0–1800 seconds. Screens: Home, Bus Home, SRP, seat layout, BP/DP, cust info, payment, ticket.

## Rules

- Prefer these files verbatim. Edit dates only.
- Search history in `search_route_details` starts January 2025. Do not expect Jan 2023–Dec 2024 SRP from that table.
- One month of `search_route_details` is a large scan. Do not run months in parallel.
- `transaction_cuts.sql` avoids the search scan. Its Top 200 / Top 500 pairs are fixed from India orders Jan 2025–Sep 2026.
