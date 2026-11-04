-- 01_schema.sql
-- Three layers:
--   raw   : BTS columns exactly as downloaded, everything as text
--   stg   : typed + derived timestamps, still one row per BTS record
--   core  : the model the analysis runs on (fact_flight + small dims)
--
-- Re-runnable: drops and rebuilds everything.

drop schema if exists raw cascade;
drop schema if exists stg cascade;
drop schema if exists core cascade;
drop schema if exists mart cascade;

create schema raw;
create schema stg;
create schema core;
create schema mart;   -- analysis views/tables live here


-- raw ----------------------------------------------------------------------

create table raw.flights (
    flightdate                       text,
    reporting_airline                text,
    tail_number                      text,
    flight_number_reporting_airline  text,
    origin                           text,
    origincityname                   text,
    originstate                      text,
    dest                             text,
    destcityname                     text,
    deststate                        text,
    crsdeptime                       text,
    deptime                          text,
    depdelay                         text,
    deptimeblk                       text,
    taxiout                          text,
    wheelsoff                        text,
    wheelson                         text,
    taxiin                           text,
    crsarrtime                       text,
    arrtime                          text,
    arrdelay                         text,
    cancelled                        text,
    cancellationcode                 text,
    diverted                         text,
    crselapsedtime                   text,
    actualelapsedtime                text,
    distance                         text,
    carrierdelay                     text,
    weatherdelay                     text,
    nasdelay                         text,
    securitydelay                    text,
    lateaircraftdelay                text,
    source_file                      text
);

-- national per-carrier monthly totals (built by the download script from the
-- full BTS file, so we can benchmark without keeping 20M rows)
create table raw.national_carrier_month (
    year            int,
    month           int,
    carrier         text,
    scheduled       int,
    cancelled       int,
    diverted        int,
    arrived         int,
    arr_delayed_15  int
);

create table raw.manifest (
    year          int,
    month         int,
    rows_in_file  int,
    rows_kept     int
);


-- core dims -----------------------------------------------------------------

create table core.dim_carrier (
    carrier_code   text primary key,
    carrier_name   text not null,
    american_group boolean not null,   -- AA mainline + wholly owned regionals
    carrier_type   text not null       -- mainline / regional / low-cost / ultra low-cost
);

-- codes from the BTS carrier list for 2024-2026 reporting carriers
insert into core.dim_carrier values
    ('AA', 'American Airlines',      true,  'mainline'),
    ('MQ', 'Envoy Air',              true,  'regional'),
    ('OH', 'PSA Airlines',           true,  'regional'),
    ('DL', 'Delta Air Lines',        false, 'mainline'),
    ('UA', 'United Airlines',        false, 'mainline'),
    ('WN', 'Southwest Airlines',     false, 'low-cost'),
    ('AS', 'Alaska Airlines',        false, 'mainline'),
    ('B6', 'JetBlue Airways',        false, 'low-cost'),
    ('HA', 'Hawaiian Airlines',      false, 'mainline'),
    ('NK', 'Spirit Air Lines',       false, 'ultra low-cost'),
    ('F9', 'Frontier Airlines',      false, 'ultra low-cost'),
    ('G4', 'Allegiant Air',          false, 'ultra low-cost'),
    ('OO', 'SkyWest Airlines',       false, 'regional'),
    ('YX', 'Republic Airways',       false, 'regional'),
    ('9E', 'Endeavor Air',           false, 'regional'),
    ('QX', 'Horizon Air',            false, 'regional'),
    ('ZW', 'Air Wisconsin',          false, 'regional'),
    ('C5', 'CommuteAir',             false, 'regional'),
    ('G7', 'GoJet Airlines',         false, 'regional'),
    ('PT', 'Piedmont Airlines',      false, 'regional'),
    ('EV', 'ExpressJet Airlines',    false, 'regional'),
    ('YV', 'Mesa Airlines',          false, 'regional'),
    ('MX', 'Breeze Airways',         false, 'low-cost'),
    ('SY', 'Sun Country Airlines',   false, 'low-cost');

create table core.dim_airport (
    airport_code  text primary key,
    city_name     text,
    state         text,
    is_aa_hub     boolean not null default false
);

create table core.dim_date (
    date_key      date primary key,
    year          int not null,
    month         int not null,
    month_start   date not null,
    day_of_week   int not null,   -- 1 = Monday
    day_name      text not null,
    is_weekend    boolean not null
);

-- fact ----------------------------------------------------------------------

create table core.fact_flight (
    flight_id            bigint generated always as identity primary key,
    flight_date          date    not null references core.dim_date,
    carrier_code         text    not null references core.dim_carrier,
    flight_number        int     not null,
    tail_number          text,
    origin               text    not null references core.dim_airport,
    dest                 text    not null references core.dim_airport,

    -- all local time at the airport in question
    sched_dep            timestamp not null,
    sched_arr            timestamp not null,
    actual_dep           timestamp,   -- sched_dep + dep_delay
    actual_arr           timestamp,   -- sched_arr + arr_delay
    dep_hour             int not null,

    dep_delay            int,         -- minutes, negative = early
    arr_delay            int,
    taxi_out             int,
    taxi_in              int,
    sched_block          int,         -- CRSElapsedTime
    actual_block         int,
    distance             int,

    cancelled            boolean not null,
    cancellation_code    char(1),     -- A carrier, B weather, C NAS, D security
    diverted             boolean not null,

    -- BTS only fills these when arr_delay >= 15
    carrier_delay        int,
    weather_delay        int,
    nas_delay            int,
    security_delay       int,
    late_aircraft_delay  int,

    -- handy flags
    dep_ontime           boolean,     -- departed < 15 min late (null if cancelled)
    arr_ontime           boolean,     -- DOT definition: arrived < 15 min late; cancel/divert = false

    unique (flight_date, carrier_code, flight_number, origin, sched_dep)
);
