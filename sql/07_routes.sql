-- 07_routes.sql
-- Which DFW routes cost the most delay, and are they getting better or worse?
-- Route = American departure from DFW to a destination.


-- 1. route scorecard (whole period) ---------------------------------------
-- min 1,000 departures so tiny seasonal routes don't top the list on 40 flights
drop table if exists mart.route_scorecard;
create table mart.route_scorecard as
with r as (
    select
        f.dest,
        count(*)                                                     as scheduled,
        round(100.0 * count(*) filter (where f.dep_ontime)
              / nullif(count(*) filter (where not f.cancelled), 0), 1) as dep_ontime_pct,
        round(100.0 * count(*) filter (where f.arr_ontime) / count(*), 1) as arr_ontime_pct,
        round(100.0 * count(*) filter (where f.cancelled) / count(*), 2)  as cancel_pct,
        sum(coalesce(f.carrier_delay,0) + coalesce(f.weather_delay,0) + coalesce(f.nas_delay,0)
            + coalesce(f.security_delay,0) + coalesce(f.late_aircraft_delay,0)) as delay_min,
        sum(coalesce(f.late_aircraft_delay, 0))                      as late_aircraft_min,
        sum(coalesce(f.carrier_delay, 0))                            as carrier_min,
        sum(coalesce(f.nas_delay, 0))                                as nas_min
    from core.fact_flight f
    join core.dim_carrier c on c.carrier_code = f.carrier_code
    where f.origin = 'DFW'
      and c.american_group
    group by f.dest
    having count(*) >= 1000
)
select
    r.*,
    a.city_name,
    round(r.delay_min::numeric / r.scheduled, 1)                   as delay_min_per_flight,
    rank() over (order by r.delay_min desc)                        as rank_total_delay,
    rank() over (order by r.delay_min::numeric / r.scheduled desc) as rank_per_flight,
    round(100.0 * sum(r.delay_min) over (order by r.delay_min desc
                                         rows between unbounded preceding and current row)
          / sum(r.delay_min) over (), 1)                           as cumulative_pct_of_delay,
    -- the biggest single cause on this route
    case greatest(r.late_aircraft_min, r.carrier_min, r.nas_min)
        when r.late_aircraft_min then 'Late aircraft'
        when r.carrier_min       then 'Carrier'
        else 'NAS'
    end                                                            as top_cause
from r
join core.dim_airport a on a.airport_code = r.dest
order by rank_total_delay;


-- 2. month over month by route --------------------------------------------
drop table if exists mart.route_monthly;
create table mart.route_monthly as
with m as (
    select
        f.dest,
        d.month_start,
        count(*) as scheduled,
        round(100.0 * count(*) filter (where f.dep_ontime)
              / nullif(count(*) filter (where not f.cancelled), 0), 1) as dep_ontime_pct
    from core.fact_flight f
    join core.dim_carrier c on c.carrier_code = f.carrier_code
    join core.dim_date d    on d.date_key = f.flight_date
    where f.origin = 'DFW'
      and c.american_group
      and f.dest in (select dest from mart.route_scorecard)
    group by f.dest, d.month_start
)
select
    m.*,
    -- LAG alone would compare against the previous month that HAS flights,
    -- which is wrong for seasonal routes, so check the gap is exactly 1 month
    case when lag(m.month_start) over w = m.month_start - interval '1 month'
         then lag(m.dep_ontime_pct) over w end           as prev_month_pct,
    case when lag(m.month_start) over w = m.month_start - interval '1 month'
         then m.dep_ontime_pct - lag(m.dep_ontime_pct) over w end as mom_change_pts,
    -- same month last year (join instead of lag(12) for the same reason)
    m.dep_ontime_pct - ly.dep_ontime_pct                 as yoy_change_pts
from m
left join m ly
       on ly.dest = m.dest
      and ly.month_start = m.month_start - interval '1 year'
window w as (partition by m.dest order by m.month_start)
order by m.dest, m.month_start;


-- 3. rolling 30-day on-time by route ---------------------------------------
-- daily counts first, then a RANGE window so days with no flights don't
-- throw off the 30-day window
drop table if exists mart.route_rolling_30d;
create table mart.route_rolling_30d as
with daily as (
    select
        f.dest,
        f.flight_date,
        count(*) filter (where not f.cancelled) as departed,
        count(*) filter (where f.dep_ontime)    as ontime
    from core.fact_flight f
    join core.dim_carrier c on c.carrier_code = f.carrier_code
    where f.origin = 'DFW'
      and c.american_group
      and f.dest in (select dest from mart.route_scorecard where rank_total_delay <= 10)
    group by f.dest, f.flight_date
)
select
    dest,
    flight_date,
    departed,
    ontime,
    round(100.0 * sum(ontime) over w / nullif(sum(departed) over w, 0), 1) as rolling_30d_ontime_pct
from daily
window w as (partition by dest order by flight_date
             range between interval '29 days' preceding and current row)
order by dest, flight_date;


-- 4. which routes got worse: latest 3 months vs the same 3 months a year
-- earlier (min 300 departures in the recent window so tiny routes don't win)
with latest as (select max(month_start) as m from mart.route_monthly),
periods as (
    select
        r.dest,
        sum(r.scheduled * r.dep_ontime_pct) filter (
            where r.month_start > (select m from latest) - interval '3 months')
          / nullif(sum(r.scheduled) filter (
            where r.month_start > (select m from latest) - interval '3 months'), 0) as recent_pct,
        sum(r.scheduled) filter (
            where r.month_start > (select m from latest) - interval '3 months') as recent_flights,
        sum(r.scheduled * r.dep_ontime_pct) filter (
            where r.month_start >  (select m from latest) - interval '15 months'
              and r.month_start <= (select m from latest) - interval '12 months')
          / nullif(sum(r.scheduled) filter (
            where r.month_start >  (select m from latest) - interval '15 months'
              and r.month_start <= (select m from latest) - interval '12 months'), 0) as year_ago_pct
    from mart.route_monthly r
    group by r.dest
)
select dest,
       recent_flights,
       round(recent_pct, 1)               as recent_3mo_pct,
       round(year_ago_pct, 1)             as same_3mo_last_year_pct,
       round(recent_pct - year_ago_pct, 1) as change_pts
from periods
where recent_pct is not null and year_ago_pct is not null
  and recent_flights >= 300
order by change_pts
limit 10;
