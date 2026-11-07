-- 11_chronic_delays.sql
-- DOT's "chronically delayed flight" rule (14 CFR 399.81):
--   a domestic flight operated at least 10 times in a month that arrives more
--   than 30 minutes late (cancellations count as late) more than 50% of the
--   time that month. Keeping one on the schedule for more than four
--   consecutive months is treated as an unfair and deceptive practice.
--
-- "Flight" here = carrier + flight number + origin + destination, which is how
-- the schedule shows it. Scope: American group flights in or out of DFW.
-- Diverted flights count as late too (they never made the scheduled arrival).


-- 1. flight-month scorecard -------------------------------------------------
drop table if exists mart.flight_month_chronic cascade;
create table mart.flight_month_chronic as
select
    f.carrier_code,
    f.flight_number,
    f.origin,
    f.dest,
    d.month_start,
    count(*)                                                        as scheduled,
    count(*) filter (where f.cancelled or f.diverted or f.arr_delay > 30) as late_30_or_cxl,
    round(100.0 * count(*) filter (where f.cancelled or f.diverted or f.arr_delay > 30)
          / count(*), 1)                                            as late_30_pct,
    count(*) >= 10
      and count(*) filter (where f.cancelled or f.diverted or f.arr_delay > 30) * 2 > count(*)
                                                                    as is_chronic
from core.fact_flight f
join core.dim_carrier c on c.carrier_code = f.carrier_code
join core.dim_date d    on d.date_key = f.flight_date
where c.american_group
  and (f.origin = 'DFW' or f.dest = 'DFW')
group by f.carrier_code, f.flight_number, f.origin, f.dest, d.month_start;

create index on mart.flight_month_chronic (month_start);
analyze mart.flight_month_chronic;


-- 2. how many each month ----------------------------------------------------
drop table if exists mart.chronic_by_month;
create table mart.chronic_by_month as
select
    month_start,
    count(*) filter (where scheduled >= 10)              as flights_eligible,
    count(*) filter (where is_chronic)                   as chronic_flights,
    round(100.0 * count(*) filter (where is_chronic)
          / nullif(count(*) filter (where scheduled >= 10), 0), 1) as chronic_pct,
    count(*) filter (where is_chronic and origin = 'DFW') as chronic_out_of_dfw,
    count(*) filter (where is_chronic and dest = 'DFW')   as chronic_into_dfw
from mart.flight_month_chronic
group by month_start
order by month_start;


-- 3. streaks: how many months in a row was the same flight chronic? ----------
-- gaps and islands again: month number minus row number is constant inside a
-- run of consecutive chronic months.
drop table if exists mart.chronic_streaks;
create table mart.chronic_streaks as
with c as (
    select
        carrier_code, flight_number, origin, dest, month_start,
        (extract(year from month_start) * 12 + extract(month from month_start))::int as month_no
    from mart.flight_month_chronic
    where is_chronic
),
grp as (
    select
        c.*,
        month_no - row_number() over (partition by carrier_code, flight_number, origin, dest
                                      order by month_no) as island
    from c
)
select
    carrier_code,
    flight_number,
    origin,
    dest,
    min(month_start)        as streak_start,
    max(month_start)        as streak_end,
    count(*)                as months_in_a_row
from grp
group by carrier_code, flight_number, origin, dest, island
order by months_in_a_row desc, streak_start;


-- 4. summary ------------------------------------------------------------------
select
    (select count(*) from mart.flight_month_chronic where is_chronic)          as chronic_flight_months,
    (select count(distinct (carrier_code, flight_number, origin, dest))
       from mart.flight_month_chronic where is_chronic)                        as distinct_flights_ever_chronic,
    (select count(*) from mart.chronic_streaks where months_in_a_row >= 2)     as streaks_2plus_months,
    (select count(*) from mart.chronic_streaks where months_in_a_row > 4)      as streaks_over_4_months,
    (select max(months_in_a_row) from mart.chronic_streaks)                    as longest_streak;

-- which months were worst
select * from mart.chronic_by_month order by chronic_flights desc limit 6;

-- longest streaks
select * from mart.chronic_streaks limit 10;

-- out of DFW: which departure hours do chronic flights leave in?
select
    f.dep_hour,
    count(distinct (m.carrier_code, m.flight_number, m.origin, m.dest, m.month_start)) as chronic_flight_months
from mart.flight_month_chronic m
join core.fact_flight f
  on f.carrier_code = m.carrier_code and f.flight_number = m.flight_number
 and f.origin = m.origin and f.dest = m.dest
 and f.flight_date >= m.month_start and f.flight_date < m.month_start + interval '1 month'
where m.is_chronic and m.origin = 'DFW'
group by f.dep_hour
order by f.dep_hour;
