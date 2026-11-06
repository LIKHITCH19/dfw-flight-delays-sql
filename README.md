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
```

All 11 data quality checks pass. Nothing was lost between raw and core, and there were 0
duplicate flights.

Analysis queries are next.
