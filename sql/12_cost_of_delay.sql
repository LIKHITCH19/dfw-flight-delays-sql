-- 12_cost_of_delay.sql
-- Rough dollar view of the findings.
--
-- Cost per minute comes from Airlines for America: U.S. passenger airline
-- direct aircraft operating cost per block minute, 2025 = $98.41 (crew 37.01,
-- fuel 29.34, maintenance 18.35, ownership 9.76, other 3.95). Based on DOT
-- Form 41. https://www.airlines.org/dataset/u-s-passenger-carrier-delay-costs/
--
-- This is the airline's cost only, not passengers' time, missed connections,
-- rebooking or compensation, so it UNDERSTATES what delay really costs. A
-- delay minute also isn't always a full block minute (some of it is spent
-- at the gate with engines off), so treat this as an order-of-magnitude number.

drop table if exists mart.assumptions;
create table mart.assumptions (
    name    text primary key,
    value   numeric not null,
    unit    text,
    source  text
);

insert into mart.assumptions values
    ('cost_per_block_minute',     98.41, 'USD',     'A4A, U.S. passenger carrier delay costs, 2025'),
    ('months_in_data',            0,     'months',  'filled below from the data'),
    ('evening_first_hour',        18,    'hour',    'evening bank = scheduled departures 18:00-22:59');

update mart.assumptions
set value = (select count(distinct month_start) from core.dim_date)
where name = 'months_in_data';


-- 1. what delay at DFW costs American per year --------------------------------
-- 2025 is the last full calendar year in the data
drop table if exists mart.delay_cost_2025;
create table mart.delay_cost_2025 as
with a as (select value as cpm from mart.assumptions where name = 'cost_per_block_minute'),
m as (
    select
        sum(total_min)          as delay_min,
        sum(late_aircraft_min)  as late_aircraft_min,
        sum(carrier_min)        as carrier_min,
        sum(nas_min)            as nas_min,
        sum(weather_min)        as weather_min
    from mart.dfw_cause_monthly
    where month_start >= date '2025-01-01' and month_start < date '2026-01-01'
)
select
    cause,
    minutes,
    round(minutes * (select cpm from a) / 1e6, 1) as cost_musd
from m
cross join lateral (values
    ('All delay',              delay_min),
    ('Late-arriving aircraft', late_aircraft_min),
    ('Air carrier',            carrier_min),
    ('NAS',                    nas_min),
    ('Extreme weather',        weather_min)
) v(cause, minutes);

-- the late-aircraft piece split the same way as 08_knock_on.sql (whole period,
-- annualized)
drop table if exists mart.knock_on_cost;
create table mart.knock_on_cost as
select
    k.bucket,
    k.late_aircraft_min,
    round(k.late_aircraft_min * 12.0 / ms.value)                    as min_per_year,
    round(k.late_aircraft_min * 12.0 / ms.value * c.value / 1e6, 1) as cost_musd_per_year
from mart.dfw_knock_on_summary k
cross join (select value from mart.assumptions where name = 'months_in_data') ms
cross join (select value from mart.assumptions where name = 'cost_per_block_minute') c
order by k.late_aircraft_min desc;


-- 2. what the turn padding is worth -------------------------------------------
-- from 09_turns.sql: minutes of late-aircraft delay avoided if tight turns get
-- 15 min of buffer. Annualized. The ground minutes added aren't priced -
-- they cost aircraft utilization (fewer flights per plane per day), which
-- this data can't value - so they're shown in aircraft-hours per day instead.
drop table if exists mart.pad_value;
create table mart.pad_value as
with p as (
    select
        case when dep_hour >= (select value from mart.assumptions where name = 'evening_first_hour')
             then 'Evening bank only (18:00-22:59)' else 'Rest of the day' end as scope,
        sum(delay_min_avoided) as delay_min_avoided,
        sum(ground_min_added)  as ground_min_added
    from mart.turn_pad_by_hour
    group by 1
    union all
    select 'All tight turns', sum(delay_min_avoided), sum(ground_min_added)
    from mart.turn_pad_by_hour
)
select
    p.scope,
    round(p.delay_min_avoided * 12.0 / ms.value)                       as delay_min_avoided_per_year,
    round(p.delay_min_avoided * 12.0 / ms.value * c.value / 1e6, 2)    as delay_cost_avoided_musd_per_year,
    round(p.ground_min_added / (ms.value * 30.4) / 60.0, 1)            as aircraft_hours_added_per_day,
    round(p.delay_min_avoided / p.ground_min_added, 2)                 as delay_min_avoided_per_ground_min
from p
cross join (select value from mart.assumptions where name = 'months_in_data') ms
cross join (select value from mart.assumptions where name = 'cost_per_block_minute') c
order by delay_min_avoided_per_year desc;


select * from mart.assumptions;
select * from mart.delay_cost_2025;
select * from mart.knock_on_cost;
select * from mart.pad_value;
