-- tests/data_quality.sql
-- Each check returns one row: name, number of problem rows, pass/fail.
-- Run after 03_core.sql. Anything that says FAIL needs a look before trusting
-- the analysis.

with checks as (

    -- every month in the manifest made it into raw with the same row count
    select 'raw rows match download manifest' as check_name,
           count(*) as problems
    from raw.manifest m
    left join (
        select substring(source_file from 'flights_(\d{4})_') ::int as year,
               substring(source_file from '_(\d{2})\.csv')    ::int as month,
               count(*) as n
        from raw.flights group by 1, 2
    ) r using (year, month)
    where r.n is distinct from m.rows_kept

    union all
    -- nothing lost between raw and core except the logged duplicates
    select 'raw = core + duplicates removed',
           abs((select count(*) from raw.flights)
               - (select count(*) from core.fact_flight)
               - (select count(*) from stg.duplicates_removed))

    union all
    -- every row kept should be American group or touch DFW (that's the filter)
    select 'rows outside the download filter',
           count(*)
    from core.fact_flight f
    join core.dim_carrier c using (carrier_code)
    where not c.american_group and f.origin <> 'DFW' and f.dest <> 'DFW'

    union all
    -- cause minutes should add up to the arrival delay when they're filled in
    select 'delay causes do not sum to arr_delay',
           count(*)
    from core.fact_flight
    where carrier_delay is not null
      and abs(coalesce(carrier_delay,0) + coalesce(weather_delay,0) + coalesce(nas_delay,0)
              + coalesce(security_delay,0) + coalesce(late_aircraft_delay,0) - arr_delay) > 1

    union all
    -- causes should only be present on flights 15+ min late
    select 'delay causes on a flight under 15 min late',
           count(*)
    from core.fact_flight
    where carrier_delay is not null and arr_delay < 15

    union all
    select 'cancelled flight with an actual departure',
           count(*)
    from core.fact_flight
    where cancelled and actual_dep is not null

    union all
    select 'cancelled flight without a cancellation code',
           count(*)
    from core.fact_flight
    where cancelled and cancellation_code is null

    union all
    -- scheduled arrival should come after scheduled departure, allowing for
    -- time zones (local times on both ends). Flag anything over 7h "early".
    select 'sched_arr implausibly before sched_dep',
           count(*)
    from core.fact_flight
    where sched_arr < sched_dep - interval '7 hours'

    union all
    select 'flight with no tail number (info only)',
           0 * count(*)   -- informational, BTS has a few of these
    from core.fact_flight
    where tail_number is null and not cancelled

    union all
    select 'origin = dest',
           count(*)
    from core.fact_flight
    where origin = dest

    union all
    -- gaps: every day in the range should have DFW departures
    select 'days with no DFW departures',
           count(*)
    from core.dim_date d
    where not exists (select 1 from core.fact_flight f
                      where f.flight_date = d.date_key and f.origin = 'DFW')
)
select check_name,
       problems,
       case when problems = 0 then 'PASS' else 'FAIL' end as result
from checks;


-- informational counts (not pass/fail)
select 'rows in core.fact_flight'                 as item, count(*)::text as value from core.fact_flight
union all
select 'duplicates removed in staging',            count(*)::text from stg.duplicates_removed
union all
select 'non-cancelled flights missing tail number', count(*)::text from core.fact_flight
        where tail_number is null and not cancelled
union all
select 'date range', min(flight_date)::text || ' to ' || max(flight_date)::text from core.fact_flight;
