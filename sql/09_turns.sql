-- 09_turns.sql
-- If a plane lands late at DFW, does the next departure leave late too?
-- That depends on how much slack is in the scheduled turn. This looks at
-- every linked inbound -> outbound pair at DFW.

drop table if exists mart.dfw_turns cascade;
create table mart.dfw_turns as
select
    l.flight_id,
    l.prev_flight_id,
    l.tail_number,
    l.carrier_code,
    case when l.carrier_code = 'AA' then 'Mainline' else 'Regional' end as fleet,
    l.prev_origin                         as inbound_from,
    l.dest                                as outbound_to,
    l.flight_date,
    l.dep_hour,
    l.sched_turn_min,
    l.actual_turn_min,
    l.prev_arr_delay                      as inbound_delay,
    l.dep_delay                           as outbound_delay,
    coalesce(l.late_aircraft_delay, 0)    as outbound_late_aircraft_min,
    case
        when l.sched_turn_min < 40  then '1: 15-39'
        when l.sched_turn_min < 50  then '2: 40-49'
        when l.sched_turn_min < 60  then '3: 50-59'
        when l.sched_turn_min < 75  then '4: 60-74'
        when l.sched_turn_min < 90  then '5: 75-89'
        when l.sched_turn_min < 120 then '6: 90-119'
        else                             '7: 120+'
    end                                   as turn_bucket
from mart.aircraft_legs l
where l.origin = 'DFW'
  and l.link_ok
  and not l.likely_swap          -- swaps don't have a real scheduled turn
  and l.prev_arr_delay is not null
  and l.dep_delay is not null;

analyze mart.dfw_turns;


-- 1. pass-through by scheduled turn ---------------------------------------
-- only pairs where the inbound was 15+ late: of those, how often did the
-- outbound leave 15+ late, and how many minutes did the turn soak up?
drop table if exists mart.turn_passthrough;
create table mart.turn_passthrough as
select
    fleet,
    turn_bucket,
    count(*)                                                   as late_inbounds,
    round(avg(sched_turn_min), 0)                              as avg_sched_turn,
    round(100.0 * count(*) filter (where outbound_delay >= 15) / count(*), 1) as passthrough_pct,
    round(avg(inbound_delay), 1)                               as avg_inbound_delay,
    round(avg(greatest(outbound_delay, 0)), 1)                 as avg_outbound_delay,
    round(avg(inbound_delay - greatest(outbound_delay, 0)), 1) as avg_min_absorbed
from mart.dfw_turns
where inbound_delay >= 15
group by fleet, turn_bucket
order by fleet, turn_bucket;


-- 2. what's the real minimum turn? ------------------------------------------
-- 10th percentile of ACTUAL turn when the inbound was late (crews hustle
-- then), by fleet. Anything scheduled close to this has basically no buffer.
drop table if exists mart.min_turn;
create table mart.min_turn as
select
    fleet,
    count(*) as late_inbounds,
    percentile_cont(0.10) within group (order by actual_turn_min) as p10_actual_turn,
    percentile_cont(0.50) within group (order by actual_turn_min) as median_actual_turn,
    percentile_cont(0.50) within group (order by sched_turn_min)  as median_sched_turn
from mart.dfw_turns
where inbound_delay >= 30
  and actual_turn_min > 0
group by fleet;


-- 3. buffer per departure hour --------------------------------------------
-- buffer = scheduled turn minus that fleet's practical minimum. Shows which
-- departure banks are built tight and how much late-aircraft delay they carry.
drop table if exists mart.dfw_bank_buffer;
create table mart.dfw_bank_buffer as
select
    t.dep_hour,
    count(*)                                                       as turns,
    round(avg(t.sched_turn_min - m.p10_actual_turn)::numeric, 1)   as avg_buffer_min,
    round(100.0 * count(*) filter (where t.sched_turn_min - m.p10_actual_turn < 15) / count(*), 1)
                                                                   as pct_turns_under_15min_buffer,
    round(100.0 * count(*) filter (where t.inbound_delay >= 15) / count(*), 1) as pct_inbound_late,
    round(100.0 * count(*) filter (where t.inbound_delay >= 15 and t.outbound_delay >= 15)
          / nullif(count(*) filter (where t.inbound_delay >= 15), 0), 1)       as passthrough_pct,
    sum(t.outbound_late_aircraft_min)                              as late_aircraft_min
from mart.dfw_turns t
join mart.min_turn m on m.fleet = t.fleet
group by t.dep_hour
order by t.dep_hour;


-- 4. simple what-if ----------------------------------------------------------
-- If every turn with under 15 min of buffer got padded up to 15, how many
-- minutes of late-aircraft delay would those outbound flights have avoided?
-- Rough: assumes each extra buffer minute absorbs one minute of inbound delay,
-- capped at the late-aircraft delay that actually got passed on.
-- The catch: padding isn't free. Every padded minute is ground time on EVERY
-- day the flight runs, late inbound or not. So compare minutes added to the
-- schedule vs delay minutes avoided, by departure hour.
drop table if exists mart.turn_pad_whatif;
create table mart.turn_pad_whatif as
with t as (
    select
        t.*,
        greatest(0, 15 - (t.sched_turn_min - m.p10_actual_turn)) as pad_min
    from mart.dfw_turns t
    join mart.min_turn m on m.fleet = t.fleet
)
select
    fleet,
    count(*) filter (where pad_min > 0)                              as turns_padded,
    round(100.0 * count(*) filter (where pad_min > 0) / count(*), 1) as pct_of_turns,
    round(avg(pad_min) filter (where pad_min > 0)::numeric, 1)       as avg_pad_min,
    round(sum(pad_min)::numeric, 0)                                  as ground_min_added,
    round(sum(least(pad_min, outbound_late_aircraft_min))::numeric, 0) as delay_min_avoided,
    round((sum(least(pad_min, outbound_late_aircraft_min))
           / nullif(sum(pad_min), 0))::numeric, 2)                   as avoided_per_min_added,
    round((100.0 * sum(least(pad_min, outbound_late_aircraft_min))
           / nullif(sum(outbound_late_aircraft_min), 0))::numeric, 1) as pct_of_late_aircraft_min
from t
group by fleet
order by fleet;

-- same thing by departure hour (both fleets) - where does padding pay off?
drop table if exists mart.turn_pad_by_hour;
create table mart.turn_pad_by_hour as
with t as (
    select
        t.*,
        greatest(0, 15 - (t.sched_turn_min - m.p10_actual_turn)) as pad_min
    from mart.dfw_turns t
    join mart.min_turn m on m.fleet = t.fleet
)
select
    dep_hour,
    count(*) filter (where pad_min > 0)                                as turns_padded,
    round(sum(pad_min)::numeric, 0)                                    as ground_min_added,
    round(sum(least(pad_min, outbound_late_aircraft_min))::numeric, 0) as delay_min_avoided,
    round((sum(least(pad_min, outbound_late_aircraft_min))
           / nullif(sum(pad_min), 0))::numeric, 2)                     as avoided_per_min_added
from t
group by dep_hour
having count(*) filter (where pad_min > 0) >= 500
order by dep_hour;


-- print the results
select * from mart.turn_passthrough;
select * from mart.min_turn;
select * from mart.turn_pad_whatif;
select * from mart.turn_pad_by_hour;
