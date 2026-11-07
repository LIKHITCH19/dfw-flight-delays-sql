-- 08_knock_on.sql
-- Late-arriving aircraft is the biggest delay cause, but BTS doesn't say what
-- made the inbound plane late in the first place. Every row has a tail number
-- though, so we can rebuild each aircraft's sequence of flights and follow a
-- delay back to the flight where it started.
--
-- Steps:
--   1. aircraft_legs  : each flight next to the previous flight on the same tail
--   2. delay_chains   : group consecutive "late aircraft" legs into chains
--                       (gaps and islands), first leg = the root cause flight
--   3. what that means for DFW: delay DFW imports vs delay it exports
--   4. a recursive CTE that walks one chain leg by leg (and a check that it
--      agrees with step 2)


-- 1. legs -------------------------------------------------------------------
drop table if exists mart.aircraft_legs cascade;
create table mart.aircraft_legs as
with seq as (
    select
        f.flight_id,
        f.tail_number,
        f.carrier_code,
        f.flight_date,
        f.flight_number,
        f.origin,
        f.dest,
        f.sched_dep,
        f.sched_arr,
        f.actual_dep,
        f.actual_arr,
        f.dep_hour,
        f.dep_delay,
        f.arr_delay,
        f.diverted,
        f.carrier_delay,
        f.weather_delay,
        f.nas_delay,
        f.security_delay,
        f.late_aircraft_delay,
        coalesce(f.actual_dep, f.sched_dep) as leg_order,
        lag(f.flight_id)  over w as prev_flight_id,
        lag(f.origin)     over w as prev_origin,
        lag(f.dest)       over w as prev_dest,
        lag(f.sched_arr)  over w as prev_sched_arr,
        lag(f.actual_arr) over w as prev_actual_arr,
        lag(f.arr_delay)  over w as prev_arr_delay,
        lag(f.diverted)   over w as prev_diverted
    from core.fact_flight f
    join core.dim_carrier c on c.carrier_code = f.carrier_code
    where c.american_group
      and not f.cancelled
      and f.tail_number is not null
    -- order by when the plane actually left, not the schedule: when there's
    -- an aircraft swap the tail that really flew can be out of schedule order
    window w as (partition by f.tail_number order by coalesce(f.actual_dep, f.sched_dep), f.flight_id)
)
select
    s.*,
    round(extract(epoch from (s.sched_dep - s.prev_sched_arr)) / 60)::int  as sched_turn_min,
    round(extract(epoch from (s.actual_dep - s.prev_actual_arr)) / 60)::int as actual_turn_min,
    -- a real link = the plane is at the right airport and it actually sat
    -- there less than 6 hours (so not an overnight). Uses actual times because
    -- swaps make the scheduled gap negative sometimes - the replacement plane
    -- was due in AFTER the flight was due out. Times are local, but both are
    -- at the same airport so the subtraction is fine.
    (s.prev_dest = s.origin
     and not coalesce(s.prev_diverted, false)
     and s.actual_dep - s.prev_actual_arr between interval '0 minutes' and interval '6 hours')
        as link_ok,
    -- scheduled turn under 15 min = the plane flying it wasn't the one planned
    (s.sched_dep - s.prev_sched_arr < interval '15 minutes') as likely_swap
from seq s;

create index on mart.aircraft_legs (flight_id);
create index on mart.aircraft_legs (prev_flight_id);
analyze mart.aircraft_legs;


-- how many links look valid? (sanity check, should be the large majority)
select
    count(*)                                         as legs,
    count(*) filter (where prev_flight_id is null)   as first_leg_for_tail,
    count(*) filter (where link_ok)                  as linked_to_prev,
    round(100.0 * count(*) filter (where link_ok) / nullif(count(*), 0), 1) as linked_pct
from mart.aircraft_legs;


-- 2. chains (gaps and islands) ---------------------------------------------
-- A leg "inherits" delay if the carrier coded late-aircraft minutes on it AND
-- it's properly linked to the previous leg. Every leg that does NOT inherit
-- starts a new island; a running sum of those starts gives a chain id.
drop table if exists mart.chain_legs cascade;
create table mart.chain_legs as
with flagged as (
    select
        l.*,
        (l.link_ok and coalesce(l.late_aircraft_delay, 0) > 0) as inherits
    from mart.aircraft_legs l
)
select
    f.*,
    sum(case when f.inherits then 0 else 1 end)
        over (partition by f.tail_number order by f.leg_order, f.flight_id
              rows between unbounded preceding and current row) as chain_no
from flagged f;

-- one row per chain: the root leg plus totals for everything it knocked on
drop table if exists mart.delay_chains cascade;
create table mart.delay_chains as
with c as (
    select
        cl.*,
        row_number() over (partition by tail_number, chain_no order by leg_order, flight_id) - 1 as pos_in_chain,
        count(*)     over (partition by tail_number, chain_no)                       as chain_len
    from mart.chain_legs cl
),
roots as (
    select * from c where pos_in_chain = 0 and chain_len > 1
),
followers as (
    select
        tail_number,
        chain_no,
        count(*)                                   as legs_hit,
        sum(late_aircraft_delay)                   as inherited_min,
        count(*) filter (where origin = 'DFW')     as dfw_departures_hit,
        sum(late_aircraft_delay) filter (where origin = 'DFW') as dfw_inherited_min,
        max(late_aircraft_delay)                   as max_leg_inherited,
        bool_or(likely_swap) filter (where pos_in_chain = 1) as first_hit_is_swap,
        max(sched_dep)                             as last_hit_dep
    from c
    where pos_in_chain > 0
    group by tail_number, chain_no
)
select
    r.tail_number,
    r.chain_no,
    r.flight_id                     as root_flight_id,
    r.carrier_code                  as root_carrier,
    r.flight_date                   as root_date,
    r.origin                        as root_origin,
    r.dest                          as root_dest,
    r.dep_hour                      as root_dep_hour,
    r.arr_delay                     as root_arr_delay,
    -- what made the root flight late (its biggest non-late-aircraft cause).
    --
    -- Special cases first: the root landed less than 15 min late (usually
    -- early) but the next flight still got late-aircraft minutes.
    --   * next flight's scheduled turn < 15 min (most are negative): this
    --     plane was swapped in and was never planned to make that departure.
    --     The plane that WAS planned is a different tail, can't trace it.
    --   * otherwise the turn was just tight and ran long.
    -- Labelled separately instead of pretending the root flight caused it.
    --
    -- If the root itself is coded late aircraft, the delay came from a flight
    -- we couldn't link (usually the previous night or a long sit).
    case
        when coalesce(r.arr_delay, 0) < 15 and f.first_hit_is_swap then 'Aircraft swap'
        when coalesce(r.arr_delay, 0) < 15                  then 'Tight turn (inbound on time)'
        when coalesce(r.late_aircraft_delay, 0) >= greatest(
                coalesce(r.carrier_delay,0), coalesce(r.nas_delay,0),
                coalesce(r.weather_delay,0), coalesce(r.security_delay,0))
             and coalesce(r.late_aircraft_delay, 0) > 0     then 'Unlinked late aircraft'
        when coalesce(r.carrier_delay,0) >= greatest(coalesce(r.nas_delay,0),
                coalesce(r.weather_delay,0), coalesce(r.security_delay,0))
             and coalesce(r.carrier_delay,0) > 0            then 'Carrier'
        when coalesce(r.nas_delay,0) >= greatest(coalesce(r.weather_delay,0),
                coalesce(r.security_delay,0))
             and coalesce(r.nas_delay,0) > 0                then 'NAS'
        when coalesce(r.weather_delay,0) > 0                then 'Weather'
        when coalesce(r.security_delay,0) > 0               then 'Security'
        else 'Other'
    end                             as root_cause,
    f.legs_hit,
    f.inherited_min,
    f.dfw_departures_hit,
    coalesce(f.dfw_inherited_min, 0) as dfw_inherited_min,
    f.max_leg_inherited,
    f.last_hit_dep
from roots r
join followers f using (tail_number, chain_no);

create index on mart.delay_chains (root_origin);
analyze mart.delay_chains;


-- 3a. headline: how much DFW departure delay is inherited, and from what ----
-- Every late-aircraft minute on an American DFW departure lands in one bucket:
--   traced   : same plane, earlier flight really was late (a real root)
--   swap     : linked to a plane that was on time and swapped in
--   tight    : plane was on time, the turn itself ran long
--   untraced : no usable link (overnight, diversion, tail mismatch)
drop table if exists mart.dfw_knock_on_summary;
create table mart.dfw_knock_on_summary as
with dfw_legs as (
    select
        cl.flight_id,
        coalesce(cl.carrier_delay,0) + coalesce(cl.weather_delay,0) + coalesce(cl.nas_delay,0)
          + coalesce(cl.security_delay,0) + coalesce(cl.late_aircraft_delay,0) as delay_min,
        coalesce(cl.late_aircraft_delay,0) as la_min,
        case
            when not cl.inherits      then 'Untraced'
            when dc.root_cause = 'Aircraft swap' then 'Aircraft swap'
            when dc.root_cause = 'Tight turn (inbound on time)' then 'Tight turn, inbound on time'
            else 'Traced to a late earlier flight'
        end as bucket
    from mart.chain_legs cl
    left join mart.delay_chains dc
           on dc.tail_number = cl.tail_number and dc.chain_no = cl.chain_no
    where cl.origin = 'DFW'
)
select
    bucket,
    sum(la_min)                                                      as late_aircraft_min,
    round(100.0 * sum(la_min) / sum(sum(la_min)) over (), 1)         as pct_of_late_aircraft,
    round(100.0 * sum(la_min) / (select sum(delay_min) from dfw_legs), 1) as pct_of_all_delay
from dfw_legs
where la_min > 0
group by bucket
order by late_aircraft_min desc;


-- 3b. imported: DFW departures that inherited delay - where did it start? ---
drop table if exists mart.dfw_imported_by_root;
create table mart.dfw_imported_by_root as
select
    root_origin,
    root_dest,
    root_origin || '-' || root_dest                       as root_route,
    count(*)                                              as chains,
    sum(dfw_departures_hit)                               as dfw_departures_hit,
    sum(dfw_inherited_min)                                as dfw_inherited_min,
    round(100.0 * sum(dfw_inherited_min)
          / sum(sum(dfw_inherited_min)) over (), 1)       as pct_of_dfw_inherited,
    mode() within group (order by root_cause)             as most_common_root_cause
from mart.delay_chains
where dfw_departures_hit > 0
  and root_arr_delay >= 15      -- swap / tight-turn roots weren't late, see 2.
group by root_origin, root_dest
order by dfw_inherited_min desc;

-- same thing rolled up: did it start on the flight INTO dfw, or further back?
select
    case
        when root_dest = 'DFW'   then 'Root was the flight into DFW'
        when root_origin = 'DFW' then 'Root left DFW earlier, came back late'
        else 'Root was 2+ legs back'
    end                         as where_it_started,
    sum(dfw_inherited_min)      as dfw_inherited_min,
    round(100.0 * sum(dfw_inherited_min) / sum(sum(dfw_inherited_min)) over (), 1) as pct
from mart.delay_chains
where dfw_departures_hit > 0
  and root_arr_delay >= 15
group by 1
order by 2 desc;

-- root cause mix for delay that reached DFW
select
    root_cause,
    sum(dfw_inherited_min) as dfw_inherited_min,
    round(100.0 * sum(dfw_inherited_min) / sum(sum(dfw_inherited_min)) over (), 1) as pct
from mart.delay_chains
where dfw_departures_hit > 0
group by root_cause
order by 2 desc;


-- 3c. exported: chains that START at DFW, how far do they travel? -----------
drop table if exists mart.dfw_exported;
create table mart.dfw_exported as
select
    root_dep_hour,
    count(*)                                       as chains,
    round(avg(root_arr_delay), 1)                  as avg_root_delay,
    round(avg(legs_hit), 2)                        as avg_legs_hit,
    sum(inherited_min)                             as downstream_min,
    round(sum(inherited_min)::numeric / count(*), 1) as downstream_min_per_chain
from mart.delay_chains
where root_origin = 'DFW'
group by root_dep_hour
order by root_dep_hour;

-- chain length distribution (all chains, whole network)
select
    least(legs_hit, 6)  as legs_hit_capped,   -- 6 = "6 or more"
    count(*)            as chains,
    round(100.0 * count(*) / sum(count(*)) over (), 1) as pct
from mart.delay_chains
group by 1
order by 1;


-- 4. recursive walk of one chain --------------------------------------------
-- Picks one long chain that went through DFW (root delay 30-120 min, so not a
-- weird outlier) and walks it forward one leg at a time from the root using
-- the prev_flight_id links. Good for eyeballing that the chain logic is sane.
with recursive pick as (
    select root_flight_id
    from mart.delay_chains
    where dfw_departures_hit > 0
      and root_arr_delay between 30 and 120
      and max_leg_inherited <= 120
    order by legs_hit desc, inherited_min desc, root_flight_id
    limit 1
),
walk as (
    select l.flight_id, l.tail_number, l.carrier_code, l.flight_number,
           l.origin, l.dest, l.sched_dep, l.dep_delay, l.arr_delay,
           l.late_aircraft_delay, l.sched_turn_min, 0 as step
    from mart.aircraft_legs l
    join pick p on p.root_flight_id = l.flight_id

    union all

    select n.flight_id, n.tail_number, n.carrier_code, n.flight_number,
           n.origin, n.dest, n.sched_dep, n.dep_delay, n.arr_delay,
           n.late_aircraft_delay, n.sched_turn_min, w.step + 1
    from walk w
    join mart.aircraft_legs n
      on n.prev_flight_id = w.flight_id
     and n.link_ok
     and coalesce(n.late_aircraft_delay, 0) > 0
)
select step, tail_number, carrier_code || flight_number as flight,
       origin || '-' || dest as route, sched_dep,
       dep_delay, arr_delay, late_aircraft_delay, sched_turn_min
from walk
order by step;


-- 4b. cross-check: recursive walk vs gaps-and-islands, on one month ----------
-- the two methods should count the same number of inherited legs
with recursive roots as (
    select root_flight_id from mart.delay_chains
    where root_date >= (select max(root_date) from mart.delay_chains) - 30
),
walk as (
    select l.flight_id, 0 as step
    from mart.aircraft_legs l join roots r on r.root_flight_id = l.flight_id
    union all
    select n.flight_id, w.step + 1
    from walk w
    join mart.aircraft_legs n
      on n.prev_flight_id = w.flight_id
     and n.link_ok
     and coalesce(n.late_aircraft_delay, 0) > 0
)
select
    (select count(*) from walk where step > 0) as legs_hit_recursive,
    (select sum(legs_hit) from mart.delay_chains
      where root_date >= (select max(root_date) from mart.delay_chains) - 30) as legs_hit_islands;
