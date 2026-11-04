#!/usr/bin/env python3
"""
Load the files from download_bts.py into Postgres (raw schema).
Expects 01_schema.sql to have been run first.

    python3 python/load_postgres.py ~/Downloads/bts_dfw

Connection comes from the usual PG* env vars (PGHOST, PGDATABASE, PGUSER...),
defaults to a local database called "flights".
"""

import glob
import gzip
import os
import sys

import psycopg

RAW_COLS = [
    "flightdate", "reporting_airline", "tail_number", "flight_number_reporting_airline",
    "origin", "origincityname", "originstate", "dest", "destcityname", "deststate",
    "crsdeptime", "deptime", "depdelay", "deptimeblk", "taxiout", "wheelsoff",
    "wheelson", "taxiin", "crsarrtime", "arrtime", "arrdelay", "cancelled",
    "cancellationcode", "diverted", "crselapsedtime", "actualelapsedtime",
    "distance", "carrierdelay", "weatherdelay", "nasdelay", "securitydelay",
    "lateaircraftdelay",
]


def main():
    data_dir = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/Downloads/bts_dfw")
    files = sorted(glob.glob(os.path.join(data_dir, "flights_*.csv.gz")))
    if not files:
        sys.exit(f"no flights_*.csv.gz files in {data_dir}")

    dsn = os.environ.get("DATABASE_URL", "dbname=" + os.environ.get("PGDATABASE", "flights"))
    with psycopg.connect(dsn) as conn, conn.cursor() as cur:
        cur.execute("truncate raw.flights, raw.manifest, raw.national_carrier_month")

        cols = ", ".join(RAW_COLS)
        for path in files:
            name = os.path.basename(path)
            # load into a temp table, then tag each row with the file it came from
            cur.execute("create temp table if not exists load_tmp (like raw.flights) on commit preserve rows")
            cur.execute("truncate load_tmp")
            with gzip.open(path, "rb") as f, \
                    cur.copy(f"copy load_tmp ({cols}) from stdin with (format csv, header true)") as cp:
                while chunk := f.read(1 << 20):
                    cp.write(chunk)
            cur.execute(f"insert into raw.flights ({cols}, source_file) "
                        f"select {cols}, %s from load_tmp", (name,))
            print(f"{name}: {cur.rowcount:,} rows")

        for table, fname in [("raw.manifest", "manifest.csv"),
                             ("raw.national_carrier_month", "national_carrier_month.csv")]:
            with open(os.path.join(data_dir, fname), "rb") as f, \
                    cur.copy(f"copy {table} from stdin with (format csv, header true)") as cp:
                cp.write(f.read())

        conn.commit()
    print("loaded")


if __name__ == "__main__":
    main()
