#!/usr/bin/env python3
"""
Export the mart tables the Tableau dashboard uses to CSV (tableau/ folder).
The dashboard itself is on Tableau Public; these files are what it was built from.

dashboard_data.csv stacks the six charts into one long file (one data source
in Tableau, each sheet filters on the "chart" column) - Tableau Public only
saves extracts, so one file was a lot easier to manage than six.

    python3 python/export_tableau.py
"""

import csv
import os

import psycopg

DSN = os.environ.get("DATABASE_URL", "dbname=" + os.environ.get("PGDATABASE", "flights"))
OUT = os.path.join(os.path.dirname(__file__), "..", "tableau")

EXPORTS = {
    "hub_comparison": """
        select year, hub, scheduled, dep_ontime_pct, arr_ontime_pct, cancel_pct, dep_rank
        from mart.hub_comparison order by year, dep_rank""",
    "dfw_monthly": """
        select month_start, carrier_group, scheduled, dep_ontime_pct, arr_ontime_pct, cancel_pct
        from mart.dfw_monthly order by month_start, carrier_group""",
    "dfw_by_hour": """
        select dep_hour, scheduled, dep_ontime_pct, avg_dep_delay_min, late_aircraft_pct
        from mart.dfw_by_hour where scheduled >= 1000 order by dep_hour""",
    "delay_causes": """
        select cause, minutes, pct_of_delay_min from mart.dfw_cause_total order by cause_rank""",
    "knock_on": """
        select k.bucket, k.late_aircraft_min, k.pct_of_late_aircraft, c.cost_musd_per_year
        from mart.dfw_knock_on_summary k
        join mart.knock_on_cost c using (bucket)
        order by k.late_aircraft_min desc""",
    "turn_passthrough": """
        select fleet, split_part(turn_bucket, ': ', 2) as sched_turn, turn_bucket as sort_key,
               late_inbounds, passthrough_pct
        from mart.turn_passthrough where late_inbounds >= 200 order by fleet, turn_bucket""",
    "chronic_by_month": """
        select month_start, flights_eligible, chronic_flights, chronic_pct
        from mart.chronic_by_month order by month_start""",
}


def build_dashboard_file():
    def read(name):
        with open(os.path.join(OUT, f"{name}.csv"), newline="") as f:
            return list(csv.DictReader(f))

    rows = []

    def add(chart, label="", month="", hour="", series="", value="", sort=""):
        rows.append([chart, label, month, hour, series, value, sort])

    for r in read("hub_comparison"):
        if r["year"] == "2025":
            add("Hub on-time 2025", label=r["hub"],
                series="DFW" if r["hub"] == "DFW" else "Other AA hubs", value=r["dep_ontime_pct"])
    for r in read("dfw_monthly"):
        add("DFW monthly on-time", month=r["month_start"], series=r["carrier_group"], value=r["dep_ontime_pct"])
    for r in read("dfw_by_hour"):
        add("On-time by hour", hour=r["dep_hour"], series="American", value=r["dep_ontime_pct"])
    for r in read("knock_on"):
        add("Late aircraft traced", label=r["bucket"], series=r["bucket"], value=r["pct_of_late_aircraft"])
    for r in read("turn_passthrough"):
        add("Turn pass-through", label=r["sched_turn"], series=r["fleet"],
            value=r["passthrough_pct"], sort=r["sort_key"].split(":")[0])
    for r in read("chronic_by_month"):
        add("Chronic delays", month=r["month_start"], series="Chronically delayed flights",
            value=r["chronic_flights"])

    path = os.path.join(OUT, "dashboard_data.csv")
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["chart", "label", "month", "hour", "series", "value", "sort_order"])
        w.writerows(rows)
    print("wrote", path)


def main():
    os.makedirs(OUT, exist_ok=True)
    with psycopg.connect(DSN) as conn, conn.cursor() as cur:
        for name, sql in EXPORTS.items():
            cur.execute(sql)
            path = os.path.join(OUT, f"{name}.csv")
            with open(path, "w", newline="") as f:
                w = csv.writer(f)
                w.writerow([c.name for c in cur.description])
                w.writerows(cur.fetchall())
            print("wrote", path)
    build_dashboard_file()


if __name__ == "__main__":
    main()
