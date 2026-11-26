#!/usr/bin/env bash
# Loads the flat CSV exports (data_engineering/exports/) into the PostgreSQL warehouse.
# Usage: bash sql/load.sh [path/to/exports] [db_name]
set -euo pipefail
cd "$(dirname "$0")/.."
EXPORTS_DIR="${1:-$(pwd)/data_engineering/exports}"
DB="${2:-video_hashtag_phase2}"

psql -d "$DB" -f sql/01_schema.sql
sed "s|__EXPORTS_DIR__|${EXPORTS_DIR}|g" sql/02_load.sql | psql -d "$DB" -f -
echo "Loaded $EXPORTS_DIR into database '$DB'."
