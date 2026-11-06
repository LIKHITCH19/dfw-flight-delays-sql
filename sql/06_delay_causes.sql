-- 06_delay_causes.sql
-- Where do the delay minutes on American's DFW departures come from?
--
-- BTS splits delay into five causes, but only for flights that arrived 15+
-- minutes late, and the five add up to that flight's arrival delay. So
-- "delay minutes" in this file = minutes on flights that were actually late,
-- which is also how DOT reports it.


-- 1. cause mix by month ----------------------------------------------------
drop table if exists mart.dfw_cause_monthly;
create table mart.dfw_cause_monthly as
with m as (
    select
        d.month_start,
        count(*)                                     as flights,
        count(*) filter (where f.arr_delay >= 15 and not f.cancelled and not f.diverted) as late_flights,
        coalesce(sum(f.carrier_delay), 0)            as carrier_min,
        coalesce(sum(f.weather_delay), 0)            as weather_min,
        coalesce(sum(f.nas_delay), 0)                as nas_min,
        coalesce(sum(f.security_delay), 0)           as security_min,
        coalesce(sum(f.late_aircraft_delay), 0)      as late_aircraft_min
    from core.fact_flight f
    join core.dim_carrier c on c.carrier_code = f.carrier_code
    join core.dim_date d    on d.date_key = f.flight_date
    where f.origin = 'DFW'
      and c.american_group
    group by d.month_start
)
select
    m.*,
    carrier_min + weather_min + nas_min + security_min + late_aircraft_min as total_min,
    round(100.0 * late_aircraft_min
          / nullif(carrier_min + weather_min + nas_min + security_min + late_aircraft_min, 0), 1)
        as late_aircraft_pct,
    round(100.0 * carrier_min
          / nullif(carrier_min + weather_min + nas_min + security_min + late_aircraft_min, 0), 1)
        as carrier_pct,
    round(100.0 * nas_min
          / nullif(carrier_min + weather_min + nas_min + security_min + late_aircraft_min, 0), 1)
        as nas_pct,
    round(100.0 * weather_min
          / nullif(carrier_min + weather_min + nas_min + security_min + late_aircraft_min, 0), 1)
        as weather_pct
from m
order by month_start;


-- 2. whole-period cause share (unpivoted so it's easy to chart / rank) -------
drop table if exists mart.dfw_cause_total;
create table mart.dfw_cause_total as
with totals as (
    select
        sum(carrier_min)       as carrier,
        sum(weather_min)       as weather,
        sum(nas_min)           as nas,
        sum(security_min)      as security,
        sum(late_aircraft_min) as late_aircraft
    from mart.dfw_cause_monthly
)
select
    cause,
    minutes,
    round(100.0 * minutes / sum(minutes) over (), 1) as pct_of_delay_min,
    rank() over (order by minutes desc)              as cause_rank
from totals
cross join lateral (values
    ('Air carrier',        carrier),
    ('Late-arriving aircraft', late_aircraft),
    ('National Aviation System', nas),
    ('Extreme weather',    weather),
    ('Security',           security)
) v(cause, minutes)
order by cause_rank;


-- 3. time of day: does it snowball? -----------------------------------------
drop table if exists mart.dfw_by_hour;
create table mart.dfw_by_hour as
select
    f.dep_hour,
    count(*)                                                        as scheduled,
    round(100.0 * count(*) filter (where f.dep_ontime)
          / nullif(count(*) filter (where not f.cancelled), 0), 1)  as dep_ontime_pct,
    round(avg(greatest(f.dep_delay, 0)) filter (where not f.cancelled), 1) as avg_dep_delay_min,
    round(100.0 * sum(f.late_aircraft_delay)
          / nullif(sum(coalesce(f.carrier_delay,0) + coalesce(f.weather_delay,0)
                     + coalesce(f.nas_delay,0) + coalesce(f.security_delay,0)
                     + coalesce(f.late_aircraft_delay,0)), 0), 1)  as late_aircraft_pct
from core.fact_flight f
join core.dim_carrier c on c.carrier_code = f.carrier_code
where f.origin = 'DFW'
  and c.american_group
group by f.dep_hour
order by f.dep_hour;


-- 4. day of week ------------------------------------------------------------
select
    d.day_of_week,
    d.day_name,
    count(*) as scheduled,
    round(100.0 * count(*) filter (where f.dep_ontime)
          / nullif(count(*) filter (where not f.cancelled), 0), 1) as dep_ontime_pct
from core.fact_flight f
join core.dim_carrier c on c.carrier_code = f.carrier_code
join core.dim_date d    on d.date_key = f.flight_date
where f.origin = 'DFW'
  and c.american_group
group by d.day_of_week, d.day_name
order by d.day_of_week;
