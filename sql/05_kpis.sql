-- 05_kpis.sql
-- Headline numbers. "American" below = AA mainline + Envoy + PSA (the
-- american_group flag in dim_carrier), since at DFW the regionals fly a big
-- chunk of the schedule and passengers don't care whose crew it is.
--
-- Definitions (same as DOT uses):
--   on-time departure = left the gate less than 15 min after schedule
--   on-time arrival   = arrived less than 15 min late; cancelled and
--                       diverted flights count as NOT on time


-- 1. DFW departures by month, American vs everyone else at DFW ---------------
drop table if exists mart.dfw_monthly;
create table mart.dfw_monthly as
select
    d.month_start,
    case when c.american_group then 'American' else 'Other carriers' end as carrier_group,
    count(*)                                                        as scheduled,
    count(*) filter (where f.cancelled)                             as cancelled,
    round(100.0 * count(*) filter (where f.cancelled) / count(*), 2) as cancel_pct,
    round(100.0 * count(*) filter (where f.dep_ontime)
          / nullif(count(*) filter (where not f.cancelled), 0), 1)  as dep_ontime_pct,
    round(100.0 * count(*) filter (where f.arr_ontime) / count(*), 1) as arr_ontime_pct,
    round(avg(f.dep_delay) filter (where f.dep_delay >= 15), 1)     as avg_delay_when_late
from core.fact_flight f
join core.dim_carrier c on c.carrier_code = f.carrier_code
join core.dim_date d    on d.date_key = f.flight_date
where f.origin = 'DFW'
group by 1, 2
order by 1, 2;


-- 2. American hubs side by side -------------------------------------------
-- departures from each hub, split by calendar year so 2026 YTD sits next to
-- the full 2024 and 2025 numbers
drop table if exists mart.hub_comparison;
create table mart.hub_comparison as
with hub as (
    select
        d.year,
        f.origin                                                    as hub,
        count(*)                                                    as scheduled,
        round(100.0 * count(*) filter (where f.dep_ontime)
              / nullif(count(*) filter (where not f.cancelled), 0), 1) as dep_ontime_pct,
        round(100.0 * count(*) filter (where f.arr_ontime) / count(*), 1) as arr_ontime_pct,
        round(100.0 * count(*) filter (where f.cancelled) / count(*), 2)  as cancel_pct,
        round(100.0 * sum(f.late_aircraft_delay)
              / nullif(sum(coalesce(f.carrier_delay,0) + coalesce(f.weather_delay,0)
                         + coalesce(f.nas_delay,0) + coalesce(f.security_delay,0)
                         + coalesce(f.late_aircraft_delay,0)), 0), 1) as late_aircraft_share_pct
    from core.fact_flight f
    join core.dim_carrier c on c.carrier_code = f.carrier_code
    join core.dim_airport a on a.airport_code = f.origin
    join core.dim_date d    on d.date_key = f.flight_date
    where c.american_group
      and a.is_aa_hub
    group by d.year, f.origin
)
select
    hub.*,
    rank() over (partition by year order by dep_ontime_pct desc) as dep_rank,
    count(*) over (partition by year)                           as hubs_ranked
from hub
order by year, dep_rank;


-- 3. Same thing against the national picture --------------------------------
-- national_carrier_month comes straight from the full BTS file (every carrier,
-- every airport), arrival-based like the DOT monthly report
drop table if exists mart.national_benchmark;
create table mart.national_benchmark as
with n as (
    select
        make_date(n.year, n.month, 1) as month_start,
        n.carrier,
        n.scheduled,
        n.scheduled - n.cancelled - n.diverted - n.arr_delayed_15 as arr_ontime
    from raw.national_carrier_month n
)
select
    month_start,
    round(100.0 * sum(arr_ontime) filter (where carrier in ('AA','MQ','OH'))
          / sum(scheduled) filter (where carrier in ('AA','MQ','OH')), 1) as american_arr_ontime_pct,
    round(100.0 * sum(arr_ontime) / sum(scheduled), 1)                    as industry_arr_ontime_pct,
    (select arr_ontime_pct from mart.dfw_monthly m
      where m.month_start = n.month_start and m.carrier_group = 'American') as american_dfw_departures_arr_ontime_pct
from n
group by month_start
order by month_start;


-- 4. whole-period totals at DFW ---------------------------------------------
select
    case when c.american_group then 'American' else 'Other carriers' end as carrier_group,
    count(*)                                                             as scheduled,
    round(100.0 * count(*) filter (where f.dep_ontime)
          / nullif(count(*) filter (where not f.cancelled), 0), 1)       as dep_ontime_pct,
    round(100.0 * count(*) filter (where f.arr_ontime) / count(*), 1)    as arr_ontime_pct,
    round(100.0 * count(*) filter (where f.cancelled) / count(*), 2)     as cancel_pct
from core.fact_flight f
join core.dim_carrier c on c.carrier_code = f.carrier_code
where f.origin = 'DFW'
group by 1
order by 1;

-- who else flies out of DFW (other carriers, for context)
select f.carrier_code, c.carrier_name, count(*) as scheduled,
       round(100.0 * count(*) filter (where f.dep_ontime)
             / nullif(count(*) filter (where not f.cancelled), 0), 1) as dep_ontime_pct
from core.fact_flight f
join core.dim_carrier c on c.carrier_code = f.carrier_code
where f.origin = 'DFW'
group by 1, 2
order by 3 desc;
