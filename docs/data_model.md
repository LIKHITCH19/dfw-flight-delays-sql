# Data model

```mermaid
erDiagram
    dim_date     ||--o{ fact_flight : "flight_date"
    dim_carrier  ||--o{ fact_flight : "carrier_code"
    dim_airport  ||--o{ fact_flight : "origin"
    dim_airport  ||--o{ fact_flight : "dest"

    fact_flight {
        bigint    flight_id PK
        date      flight_date FK
        text      carrier_code FK
        int       flight_number
        text      tail_number
        text      origin FK
        text      dest FK
        timestamp sched_dep
        timestamp sched_arr
        timestamp actual_dep
        timestamp actual_arr
        int       dep_delay
        int       arr_delay
        boolean   cancelled
        boolean   diverted
        int       carrier_delay
        int       weather_delay
        int       nas_delay
        int       security_delay
        int       late_aircraft_delay
        boolean   dep_ontime
        boolean   arr_ontime
    }
    dim_carrier {
        text    carrier_code PK
        text    carrier_name
        boolean american_group
        text    carrier_type
    }
    dim_airport {
        text    airport_code PK
        text    city_name
        text    state
        boolean is_aa_hub
    }
    dim_date {
        date    date_key PK
        int     year
        int     month
        date    month_start
        int     day_of_week
        boolean is_weekend
    }
```

One row in `fact_flight` = one scheduled flight. Natural key is
`(flight_date, carrier_code, flight_number, origin, sched_dep)` with a unique constraint on it.

## Schemas

| schema | purpose |
|---|---|
| `raw` | the CSV columns exactly as downloaded, all text, plus the file name each row came from |
| `stg` | typed and cleaned, timestamps built, duplicates removed (and kept in `stg.duplicates_removed`) |
| `core` | the star schema above |
| `mart` | one table per analysis question, rebuilt by files 05-09 |

## Notes on the tricky columns

- **Times.** BTS gives `CRSDepTime` / `CRSArrTime` as `hhmm` local time and no arrival date.
  Arrival is pushed to the next day when local arrival minus local departure is more than 7
  hours less than the scheduled block time. More than 7 hours can't be explained by time zones.
  Checked: 0 flights where the scheduled duration and the block time disagree by more than
  400 minutes after this.
- **Actual times** = scheduled + delay minutes, instead of parsing `DepTime` / `ArrTime`,
  which wrap around midnight.
- **Delay causes** are only filled when `arr_delay >= 15`, and they add up to `arr_delay`
  (tested).
