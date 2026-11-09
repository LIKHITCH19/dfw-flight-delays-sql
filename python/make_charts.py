#!/usr/bin/env python3
"""
Charts for the README. Everything is computed in SQL (mart schema) - this
just reads the finished tables and draws them.

    python3 python/make_charts.py
"""

import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as mtick
import pandas as pd
import psycopg

DSN = os.environ.get("DATABASE_URL", "dbname=" + os.environ.get("PGDATABASE", "flights"))
OUT = os.path.join(os.path.dirname(__file__), "..", "charts")

BLUE = "#2a78d6"     # American
ORANGE = "#eb6834"   # highlight
GRAY = "#9a9893"     # everything else
INK = "#0b0b0b"
INK2 = "#52514e"
GRID = "#e6e5e1"

plt.rcParams.update({
    "font.family": "DejaVu Sans",
    "font.size": 10,
    "axes.edgecolor": GRID,
    "axes.labelcolor": INK2,
    "axes.titlecolor": INK,
    "axes.titlesize": 12,
    "axes.titleweight": "bold",
    "axes.titlelocation": "left",
    "axes.spines.top": False,
    "axes.spines.right": False,
    "axes.grid": True,
    "axes.axisbelow": True,
    "grid.color": GRID,
    "grid.linewidth": 0.8,
    "xtick.color": INK2,
    "ytick.color": INK2,
    "figure.facecolor": "white",
    "savefig.dpi": 150,
    "savefig.bbox": "tight",
})


def q(sql):
    with psycopg.connect(DSN) as conn, conn.cursor() as cur:
        cur.execute(sql)
        cols = [c.name for c in cur.description]
        df = pd.DataFrame(cur.fetchall(), columns=cols)
    # numeric columns come back as Decimal
    for c in df.columns:
        if df[c].dtype == object and len(df) and type(df[c].iloc[0]).__name__ == "Decimal":
            df[c] = df[c].astype(float)
    return df


def save(fig, name):
    os.makedirs(OUT, exist_ok=True)
    fig.savefig(os.path.join(OUT, name))
    plt.close(fig)
    print("wrote", name)


def monthly_ontime():
    df = q("select month_start, carrier_group, dep_ontime_pct from mart.dfw_monthly order by 1")
    df["month_start"] = pd.to_datetime(df["month_start"])
    fig, ax = plt.subplots(figsize=(9, 4))
    for grp, color in [("American", BLUE), ("Other carriers", GRAY)]:
        d = df[df.carrier_group == grp]
        ax.plot(d.month_start, d.dep_ontime_pct, color=color, lw=2)
        last = d.iloc[-1]
        ax.annotate(grp, (last.month_start, last.dep_ontime_pct), xytext=(6, 0),
                    textcoords="offset points", va="center", color=INK2)
    ax.set_title("On-time departures from DFW, by month")
    ax.set_ylabel("% departing < 15 min late")
    ax.yaxis.set_major_formatter(mtick.PercentFormatter(decimals=0))
    ax.grid(axis="x", visible=False)
    save(fig, "01_dfw_monthly_ontime.png")


def cause_mix():
    df = q("select cause, pct_of_delay_min from mart.dfw_cause_total order by minutes")
    fig, ax = plt.subplots(figsize=(8, 3.2))
    colors = [ORANGE if c == "Late-arriving aircraft" else BLUE for c in df.cause]
    ax.barh(df.cause, df.pct_of_delay_min, color=colors, height=0.6)
    for y, v in enumerate(df.pct_of_delay_min):
        ax.text(v + 0.6, y, f"{v:.1f}%", va="center", color=INK2)
    ax.set_title("Where delay minutes on American's DFW departures come from")
    ax.xaxis.set_major_formatter(mtick.PercentFormatter(decimals=0))
    ax.grid(axis="y", visible=False)
    save(fig, "02_delay_cause_mix.png")


def by_hour():
    df = q("select dep_hour, scheduled, dep_ontime_pct, late_aircraft_pct "
           "from mart.dfw_by_hour where scheduled >= 1000 order by dep_hour")
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 3.8))
    a1.plot(df.dep_hour, df.dep_ontime_pct, color=BLUE, lw=2, marker="o", ms=4)
    a1.set_title("On-time departure % by scheduled hour")
    a1.yaxis.set_major_formatter(mtick.PercentFormatter(decimals=0))
    a2.plot(df.dep_hour, df.late_aircraft_pct, color=ORANGE, lw=2, marker="o", ms=4)
    a2.set_title("Share of delay that's late-arriving aircraft")
    a2.yaxis.set_major_formatter(mtick.PercentFormatter(decimals=0))
    for a in (a1, a2):
        a.set_xlabel("scheduled departure hour (local)")
        a.set_xticks(range(5, 24, 2))
    save(fig, "03_by_hour.png")


def turn_passthrough():
    df = q("select fleet, turn_bucket, passthrough_pct, late_inbounds "
           "from mart.turn_passthrough where late_inbounds >= 200 order by turn_bucket")
    df["label"] = df.turn_bucket.str.split(": ").str[1]
    fig, ax = plt.subplots(figsize=(8.5, 4))
    for fleet, color in [("Mainline", BLUE), ("Regional", ORANGE)]:
        d = df[df.fleet == fleet]
        ax.plot(d.label, d.passthrough_pct, color=color, lw=2, marker="o", ms=5)
        ax.annotate(fleet, (d.label.iloc[-1], d.passthrough_pct.iloc[-1]),
                    xytext=(6, 0), textcoords="offset points", va="center", color=INK2)
    ax.set_title("Inbound late 15+ min: how often the next DFW departure is late too")
    ax.set_xlabel("scheduled turn at DFW (minutes)")
    ax.set_ylabel("% of late inbounds passed on")
    ax.set_ylim(0, 100)
    ax.yaxis.set_major_formatter(mtick.PercentFormatter(decimals=0))
    ax.grid(axis="x", visible=False)
    save(fig, "04_turn_passthrough.png")


def knock_on_buckets():
    df = q("select bucket, pct_of_late_aircraft from mart.dfw_knock_on_summary "
           "order by late_aircraft_min")
    fig, ax = plt.subplots(figsize=(8, 3))
    colors = [ORANGE if b == "Aircraft swap" else BLUE if b.startswith("Traced") else GRAY
              for b in df.bucket]
    ax.barh(df.bucket, df.pct_of_late_aircraft, color=colors, height=0.6)
    for y, v in enumerate(df.pct_of_late_aircraft):
        ax.text(v + 0.6, y, f"{v:.1f}%", va="center", color=INK2)
    ax.set_title("Late-aircraft minutes on DFW departures, traced by tail number")
    ax.set_xlabel("% of late-aircraft delay minutes")
    ax.xaxis.set_major_formatter(mtick.PercentFormatter(decimals=0))
    ax.grid(axis="y", visible=False)
    save(fig, "05_knock_on_buckets.png")


def pad_by_hour():
    df = q("select dep_hour, avoided_per_min_added from mart.turn_pad_by_hour order by dep_hour")
    fig, ax = plt.subplots(figsize=(8.5, 3.6))
    colors = [ORANGE if h >= 18 else BLUE for h in df.dep_hour]
    ax.bar(df.dep_hour, df.avoided_per_min_added, color=colors, width=0.7)
    ax.set_title("Padding tight DFW turns: delay minutes avoided per minute of ground time added")
    ax.set_xlabel("scheduled departure hour (local)")
    ax.set_xticks(df.dep_hour)
    ax.grid(axis="x", visible=False)
    save(fig, "06_pad_payoff_by_hour.png")


if __name__ == "__main__":
    monthly_ontime()
    cause_mix()
    by_hour()
    turn_passthrough()
    knock_on_buckets()
    pad_by_hour()
