-- 10_performance.sql
-- Does indexing actually matter here? Times two queries the project runs a
-- lot, without and then with the indexes from 04_indexes.sql.
-- Run with psql so \timing works; EXPLAIN (ANALYZE) prints the real plan.

\timing on

-- start clean
drop index if exists core.ix_fact_origin_date;
drop index if exists core.ix_fact_dest_date;
drop index if exists core.ix_fact_tail_dep;
drop index if exists core.ix_fact_carrier_date;
analyze core.fact_flight;

-- busiest American mainline tail, looked up once so it isn't part of the timing
select tail_number as busy_tail
from core.fact_flight
where carrier_code = 'AA' and tail_number is not null
group by tail_number
order by count(*) desc
limit 1 \gset


-- Query A: one route, one quarter (the kind of thing an ops analyst pulls all day)
explain (analyze, buffers, costs off, summary on)
select f.flight_date, count(*), avg(f.dep_delay)
from core.fact_flight f
where f.origin = 'DFW'
  and f.dest = 'ORD'
  and f.flight_date between date '2025-06-01' and date '2025-08-31'
group by f.flight_date;

-- Query B: one aircraft's history in order (what the knock-on logic does per tail)
explain (analyze, buffers, costs off, summary on)
select f.flight_id, f.origin, f.dest, f.sched_dep, f.dep_delay, f.arr_delay
from core.fact_flight f
where f.tail_number = :'busy_tail'
  and not f.cancelled
order by f.sched_dep;


-- add the indexes back
\i sql/04_indexes.sql


explain (analyze, buffers, costs off, summary on)
select f.flight_date, count(*), avg(f.dep_delay)
from core.fact_flight f
where f.origin = 'DFW'
  and f.dest = 'ORD'
  and f.flight_date between date '2025-06-01' and date '2025-08-31'
group by f.flight_date;

explain (analyze, buffers, costs off, summary on)
select f.flight_id, f.origin, f.dest, f.sched_dep, f.dep_delay, f.arr_delay
from core.fact_flight f
where f.tail_number = :'busy_tail'
  and not f.cancelled
order by f.sched_dep;

\timing off
