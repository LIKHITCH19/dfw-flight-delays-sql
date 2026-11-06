# DFW flight delays: where American's hub loses time

SQL project on U.S. DOT on-time data, Jan 2024 to Aug 2026. Everything is done in PostgreSQL;
Python only downloads the files, loads them and draws the charts at the end.

I live near DFW and fly out of it a lot, and in my transportation operations job at UNT I
spend a lot of time on "why is this late" questions, so I wanted to see whether the data
backs up the feeling that DFW is always running behind. It does. American is the biggest
carrier at DFW by a lot (it's their largest hub), so that's the focus.

**Questions**

1. How does DFW compare with American's other hubs, and with the other airlines at DFW?
2. Where do the delay minutes come from: which causes, which hours, which routes?
3. Half the delay is "late-arriving aircraft". BTS doesn't say what made the plane late
   in the first place. Can that be traced?
4. Where in the schedule could a small change actually help?
5. Which flights would DOT call "chronically delayed", and roughly what is all this costing?

## Data

Bureau of Transportation Statistics, [Reporting Carrier On-Time Performance](https://www.transtats.bts.gov/DL_SelectFields.aspx?gnoyr_VQ=FGJ).
Airlines over a revenue threshold are required to report every domestic flight: schedule,
actual times, tail number, and delay minutes split into five causes (carrier, weather,
National Aviation System, security, late aircraft).

- 32 monthly files, 18.8M flights nationally
- `python/download_bts.py` keeps everything flown by American and its two wholly owned
  regionals (Envoy `MQ`, PSA `OH`) anywhere in the country, plus every flight in or out of
  DFW by any airline. That's **4,414,013 flights**. The whole American network is kept,
  not just DFW, because the delay tracing follows planes after they leave DFW.
- It also writes national totals by carrier and month so there's an industry benchmark
  without keeping all 18.8M rows.

The raw files are not in the repo (about 120 MB). Run the download script to get them:

```
python3 python/download_bts.py     # ~20 min, writes to ~/Downloads/bts_dfw
```

## How it's built

```
raw   ->  stg   ->  core                ->  mart
text      typed     fact_flight             analysis tables
as-is     dedupe    dim_carrier             (one per question)
          times     dim_airport
                    dim_date
```

| file | what it does |
|---|---|
| `sql/01_schema.sql` | schemas, tables, keys, carrier lookup |
| `sql/02_staging.sql` | casts types, builds timestamps (handles `2400` and overnight arrivals), removes duplicates |
| `sql/03_core.sql` | builds the dims and the fact table, adds on-time flags using the DOT definitions |
| `tests/data_quality.sql` | 11 checks, e.g. row counts vs the download log, causes add up to the arrival delay, no causes on flights under 15 min late |
| `sql/04_indexes.sql` | indexes |
| `sql/05_kpis.sql` | DFW monthly, hub ranking, national benchmark |
| `sql/06_delay_causes.sql` | cause mix, hour of day, day of week |
| `sql/07_routes.sql` | route scorecard, month over month and year over year, rolling 30-day on-time |

The data model is in [docs/data_model.md](docs/data_model.md).

Run it (so far):

```
createdb flights
pip install -r requirements.txt
python3 python/download_bts.py
psql -d flights -f sql/01_schema.sql
python3 python/load_postgres.py ~/Downloads/bts_dfw
psql -d flights -f sql/02_staging.sql
psql -d flights -f sql/03_core.sql
psql -d flights -f tests/data_quality.sql
psql -d flights -f sql/04_indexes.sql
psql -d flights -f sql/05_kpis.sql
psql -d flights -f sql/06_delay_causes.sql
psql -d flights -f sql/07_routes.sql
```

All 11 data quality checks pass. Nothing was lost between raw and core, and there were 0
duplicate flights.

## What I found

"American" below means AA mainline + Envoy + PSA flying out of DFW, 662,662 departures.
On-time means it left the gate less than 15 minutes late.

### 1. DFW is American's worst hub, every year

| | 2024 | 2025 | 2026 (Jan-Aug) |
|---|---|---|---|
| DFW on-time departures | 70.9% | 70.0% | 68.4% |
| DFW rank among the 10 AA hubs | 10th | 10th | 10th |
| best hub | JFK 85.0% | JFK 84.0% | JFK 79.9% |

DFW also runs behind the other airlines at the same airport: 69.9% on-time for American vs
77.3% for everyone else, with the same weather and the same air traffic control. Inside
American, mainline is the problem: **AA mainline 64.6%**, PSA 74.1%, Envoy 81.9%.

Summer is the worst every year (May to Aug), which fits Texas thunderstorm season.

### 2. Half the delay is planes showing up late, and it builds through the day

Late-arriving aircraft is 49.7% of delay minutes on American's DFW departures. Weather
(the "extreme weather" category) is only 7.6%, though BTS counts normal weather under NAS.

Departures before 8am leave on time about 84% of the time. By 6 to 8pm it's around 60%,
and over half the delay at that point is inherited from earlier flights. That's the
classic hub snowball pattern.

### 3. It isn't a route problem

149 routes out of DFW have 1,000+ American departures. The worst route (SAT) is only 2.3%
of total delay minutes, and the top 15 together are 27%. No single route explains much, so
route-by-route fixes won't move the hub number. Late aircraft is the top cause on every one
of the top 15 routes. (Full table: `mart.route_scorecard`.)

Next: following delays from plane to plane by tail number.
