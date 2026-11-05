-- 02_staging.sql
-- raw.flights (all text) -> stg.flights (typed, timestamps built, deduped)
--
-- Notes on the BTS time fields:
--   * CRSDepTime / CRSArrTime are hhmm in LOCAL time of that airport.
--     "2400" shows up and means midnight.
--   * Arrival can be the next calendar day (red-eyes). BTS doesn't give an
--     arrival date, so it gets worked out below from the scheduled block time.
--   * Actual times are built as scheduled + delay instead of using DepTime /
--     ArrTime directly, which avoids another round of midnight problems.

drop table if exists stg.flights;

create table stg.flights as
with typed as (
    select
        flightdate::date                                   as flight_date,
        reporting_airline                                  as carrier_code,
        flight_number_reporting_airline::int               as flight_number,
        nullif(trim(tail_number), '')                      as tail_number,
        origin,
        origincityname                                     as origin_city,
        originstate                                        as origin_state,
        dest,
        destcityname                                       as dest_city,
        deststate                                          as dest_state,

        -- hhmm -> minutes after midnight
        (crsdeptime::int / 100) * 60 + (crsdeptime::int % 100)   as crs_dep_min,
        (crsarrtime::int / 100) * 60 + (crsarrtime::int % 100)   as crs_arr_min,

        round(nullif(depdelay, '')::numeric)::int          as dep_delay,
        round(nullif(arrdelay, '')::numeric)::int          as arr_delay,
        round(nullif(taxiout, '')::numeric)::int           as taxi_out,
        round(nullif(taxiin, '')::numeric)::int            as taxi_in,
        round(nullif(crselapsedtime, '')::numeric)::int    as sched_block,
        round(nullif(actualelapsedtime, '')::numeric)::int as actual_block,
        round(nullif(distance, '')::numeric)::int          as distance,

        nullif(cancelled, '')::numeric = 1                 as cancelled,
        nullif(trim(cancellationcode), '')::char(1)        as cancellation_code,
        nullif(diverted, '')::numeric = 1                  as diverted,

        round(nullif(carrierdelay, '')::numeric)::int      as carrier_delay,
        round(nullif(weatherdelay, '')::numeric)::int      as weather_delay,
        round(nullif(nasdelay, '')::numeric)::int          as nas_delay,
        round(nullif(securitydelay, '')::numeric)::int     as security_delay,
        round(nullif(lateaircraftdelay, '')::numeric)::int as late_aircraft_delay,

        source_file
    from raw.flights
),
timed as (
    select
        t.*,
        t.flight_date + make_interval(mins => t.crs_dep_min) as sched_dep,

        -- Did the flight land the next day?  local arr - local dep should be
        -- roughly the block time +/- a few hours of time zone difference.
        -- If it's way negative, it's an overnight flight.
        case
            when t.sched_block is not null
                 and (t.crs_arr_min - t.crs_dep_min) - t.sched_block < -420 then 1
            when t.sched_block is null
                 and t.crs_arr_min < t.crs_dep_min then 1
            else 0
        end as arr_day_shift
    from typed t
),
built as (
    select
        x.*,
        x.flight_date + x.arr_day_shift + make_interval(mins => x.crs_arr_min) as sched_arr
    from timed x
),
deduped as (
    select
        b.*,
        row_number() over (
            partition by flight_date, carrier_code, flight_number, origin, sched_dep
            order by source_file
        ) as rn
    from built b
)
select
    flight_date, carrier_code, flight_number, tail_number,
    origin, origin_city, origin_state, dest, dest_city, dest_state,
    sched_dep,
    sched_arr,
    case when not cancelled and dep_delay is not null
         then sched_dep + make_interval(mins => dep_delay) end   as actual_dep,
    case when not cancelled and not diverted and arr_delay is not null
         then sched_arr + make_interval(mins => arr_delay) end   as actual_arr,
    least(crs_dep_min / 60, 23)                                  as dep_hour,
    dep_delay, arr_delay, taxi_out, taxi_in,
    sched_block, actual_block, distance,
    cancelled, cancellation_code, diverted,
    carrier_delay, weather_delay, nas_delay, security_delay, late_aircraft_delay,
    rn > 1 as is_duplicate
from deduped;

-- keep a record of what got dropped as duplicate before removing it
drop table if exists stg.duplicates_removed;
create table stg.duplicates_removed as
select * from stg.flights where is_duplicate;

delete from stg.flights where is_duplicate;
alter table stg.flights drop column is_duplicate;

analyze stg.flights;
