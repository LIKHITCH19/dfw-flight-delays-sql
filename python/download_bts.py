#!/usr/bin/env python3
"""
Download BTS "Reporting Carrier On-Time Performance" monthly files and keep
only the flights this project uses:

  - every flight operated by American (AA) and its two wholly owned regionals,
    Envoy (MQ) and PSA (OH), anywhere in the network
  - every flight in or out of DFW, any carrier

The full national file is ~600k rows a month. Keeping all of the American
group (not just DFW) matters because the knock-on analysis follows each
aircraft through its whole day, and planes leave DFW.

Also writes a small national summary per carrier per month so DFW / American
can be benchmarked against the rest of the industry without keeping every row.

Usage:
    python3 download_bts.py            # writes to ~/Downloads/bts_dfw
    python3 download_bts.py some/dir

Uses the system curl for downloads (python.org builds on macOS often fail
certificate checks with urllib).
"""

import csv
import gzip
import io
import os
import subprocess
import sys
import tempfile
import zipfile

URL = ("https://transtats.bts.gov/PREZIP/"
       "On_Time_Reporting_Carrier_On_Time_Performance_1987_present_{y}_{m}.zip")

START = (2024, 1)
END = (2026, 9)   # months BTS hasn't published yet are just skipped

AMERICAN_GROUP = {"AA", "MQ", "OH"}
HUB = "DFW"

KEEP = [
    "FlightDate", "Reporting_Airline", "Tail_Number",
    "Flight_Number_Reporting_Airline",
    "Origin", "OriginCityName", "OriginState",
    "Dest", "DestCityName", "DestState",
    "CRSDepTime", "DepTime", "DepDelay", "DepTimeBlk",
    "TaxiOut", "WheelsOff", "WheelsOn", "TaxiIn",
    "CRSArrTime", "ArrTime", "ArrDelay",
    "Cancelled", "CancellationCode", "Diverted",
    "CRSElapsedTime", "ActualElapsedTime", "Distance",
    "CarrierDelay", "WeatherDelay", "NASDelay",
    "SecurityDelay", "LateAircraftDelay",
]


def months(start, end):
    y, m = start
    while (y, m) <= end:
        yield y, m
        m += 1
        if m == 13:
            y, m = y + 1, 1


def fetch(url, dest):
    r = subprocess.run(
        ["curl", "-fsSL", "--retry", "3", "--retry-delay", "5", "-o", dest, url],
        capture_output=True, text=True)
    return r.returncode == 0


def is_float(s):
    try:
        float(s)
        return True
    except ValueError:
        return False


def process(zip_path, y, m, out_dir, national):
    with zipfile.ZipFile(zip_path) as z:
        member = [n for n in z.namelist() if n.lower().endswith(".csv")][0]
        with z.open(member) as raw:
            reader = csv.DictReader(io.TextIOWrapper(raw, encoding="latin-1"))
            missing = [c for c in KEEP if c not in reader.fieldnames]
            if missing:
                sys.exit(f"{y}-{m:02d}: columns missing from BTS file: {missing}")

            out_path = os.path.join(out_dir, f"flights_{y}_{m:02d}.csv.gz")
            total = kept = 0
            with gzip.open(out_path, "wt", newline="", encoding="utf-8") as f:
                w = csv.writer(f)
                w.writerow(KEEP)
                for row in reader:
                    total += 1
                    carrier = row["Reporting_Airline"]

                    # national summary, every row
                    key = (y, m, carrier)
                    s = national.setdefault(key, [0, 0, 0, 0, 0])
                    s[0] += 1
                    if row["Cancelled"].startswith("1"):
                        s[1] += 1
                    elif row["Diverted"].startswith("1"):
                        s[2] += 1
                    elif is_float(row["ArrDelay"]):
                        s[3] += 1
                        if float(row["ArrDelay"]) >= 15:
                            s[4] += 1

                    if (carrier in AMERICAN_GROUP
                            or row["Origin"] == HUB or row["Dest"] == HUB):
                        w.writerow([row[c] for c in KEEP])
                        kept += 1
    return total, kept


def main():
    out_dir = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/Downloads/bts_dfw")
    os.makedirs(out_dir, exist_ok=True)

    national = {}
    manifest = []
    tmp_dir = tempfile.mkdtemp()

    for y, m in months(START, END):
        zpath = os.path.join(tmp_dir, f"{y}_{m}.zip")
        print(f"{y}-{m:02d} downloading...", end=" ", flush=True)
        if not fetch(URL.format(y=y, m=m), zpath):
            print("not available, skipping")
            continue
        total, kept = process(zpath, y, m, out_dir, national)
        os.remove(zpath)
        manifest.append((y, m, total, kept))
        print(f"{total:,} rows in file, kept {kept:,}")

    with open(os.path.join(out_dir, "manifest.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["year", "month", "rows_in_file", "rows_kept"])
        w.writerows(manifest)

    with open(os.path.join(out_dir, "national_carrier_month.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["year", "month", "carrier", "scheduled", "cancelled",
                    "diverted", "arrived", "arr_delayed_15"])
        for k in sorted(national):
            w.writerow(list(k) + national[k])

    print(f"\ndone - {len(manifest)} months written to {out_dir}")


if __name__ == "__main__":
    main()
