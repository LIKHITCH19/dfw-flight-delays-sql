#!/usr/bin/env bash
# Rebuild everything from the downloaded files.
#   ./run_all.sh ~/Downloads/bts_dfw
# Needs: PostgreSQL running, a database called "flights" (createdb flights),
# and pip install -r requirements.txt
set -euo pipefail

DATA_DIR="${1:-$HOME/Downloads/bts_dfw}"
DB="${PGDATABASE:-flights}"
PSQL="psql -X -q -v ON_ERROR_STOP=1 -d $DB"

cd "$(dirname "$0")"
mkdir -p output

$PSQL -f sql/01_schema.sql
python3 python/load_postgres.py "$DATA_DIR"
$PSQL -f sql/02_staging.sql
$PSQL -f sql/03_core.sql
$PSQL -f tests/data_quality.sql
$PSQL -f sql/04_indexes.sql

for f in sql/05_kpis.sql sql/06_delay_causes.sql sql/07_routes.sql \
         sql/08_knock_on.sql sql/09_turns.sql \
         sql/11_chronic_delays.sql sql/12_cost_of_delay.sql; do
    echo "== $f"
    $PSQL -f "$f" > "output/$(basename "$f" .sql).txt"
done

echo "== sql/10_performance.sql"
$PSQL -f sql/10_performance.sql > output/10_performance.txt

python3 python/make_charts.py
python3 python/export_tableau.py
echo "done"
