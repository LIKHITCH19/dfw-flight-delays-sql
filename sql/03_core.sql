-- 03_core.sql
-- Build the dims and core.fact_flight from stg.flights.

-- carriers that show up at DFW but aren't in the seed list (shouldn't happen,
-- but don't want the FK to blow up the load if BTS adds someone)
insert into core.dim_carrier (carrier_code, carrier_name, american_group, carrier_type)
select distinct s.carrier_code, 'Unknown (' || s.carrier_code || ')', false, 'unknown'
from stg.flights s
where not exists (select 1 from core.dim_carrier c where c.carrier_code = s.carrier_code);


-- airports: take the most common city/state label BTS uses for each code
insert into core.dim_airport (airport_code, city_name, state)
select airport_code, city_name, state
from (
    select airport_code, city_name, state,
           row_number() over (partition by airport_code order by count(*) desc) as rn
    from (
        select origin as airport_code, origin_city as city_name, origin_state as state from stg.flights
        union all
        select dest, dest_city, dest_state from stg.flights
    ) a
    group by airport_code, city_name, state
) ranked
where rn = 1;

-- American's hubs
update core.dim_airport
set is_aa_hub = true
where airport_code in ('DFW', 'CLT', 'ORD', 'MIA', 'PHX', 'PHL', 'DCA', 'LGA', 'JFK', 'LAX');


-- dates
insert into core.dim_date
select
    d::date,
    extract(year from d)::int,
    extract(month from d)::int,
    date_trunc('month', d)::date,
    extract(isodow from d)::int,
    trim(to_char(d, 'Day')),
    extract(isodow from d) in (6, 7)
from generate_series(
        (select min(flight_date) from stg.flights),
        (select max(flight_date) from stg.flights),
        interval '1 day') d;


-- fact
insert into core.fact_flight (
    flight_date, carrier_code, flight_number, tail_number, origin, dest,
    sched_dep, sched_arr, actual_dep, actual_arr, dep_hour,
    dep_delay, arr_delay, taxi_out, taxi_in, sched_block, actual_block, distance,
    cancelled, cancellation_code, diverted,
    carrier_delay, weather_delay, nas_delay, security_delay, late_aircraft_delay,
    dep_ontime, arr_ontime
)
select
    flight_date, carrier_code, flight_number, tail_number, origin, dest,
    sched_dep, sched_arr, actual_dep, actual_arr, dep_hour,
    dep_delay, arr_delay, taxi_out, taxi_in, sched_block, actual_block, distance,
    cancelled, cancellation_code, diverted,
    carrier_delay, weather_delay, nas_delay, security_delay, late_aircraft_delay,
    case when cancelled then null else coalesce(dep_delay, 0) < 15 end,
    case when cancelled or diverted then false else coalesce(arr_delay, 0) < 15 end
from stg.flights
order by flight_date, carrier_code, sched_dep;

analyze core.fact_flight;
