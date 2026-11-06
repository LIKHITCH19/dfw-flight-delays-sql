-- 04_indexes.sql
-- Indexes the analysis files lean on. 10_performance.sql drops these and
-- times the main queries with and without them.

create index if not exists ix_fact_origin_date   on core.fact_flight (origin, flight_date);
create index if not exists ix_fact_dest_date     on core.fact_flight (dest, flight_date);
create index if not exists ix_fact_tail_dep      on core.fact_flight (tail_number, sched_dep)
    where tail_number is not null and not cancelled;
create index if not exists ix_fact_carrier_date  on core.fact_flight (carrier_code, flight_date);

analyze core.fact_flight;
