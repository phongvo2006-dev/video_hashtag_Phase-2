#!/usr/bin/env bash
# Exports every Phase 2 analytical view to a CSV, ready for Power BI import.
# Usage: bash sql/export_views.sh [db_name]
set -euo pipefail
cd "$(dirname "$0")/.."
DB="${1:-video_hashtag_phase2}"

VIEWS=(
  vw_video_topic_tags
  vw_category_overview
  vw_high_tag_density_categories
  vw_confidence_by_category
  vw_category_review_priority
)

mkdir -p powerbi/data sql/results

for v in "${VIEWS[@]}"; do
  psql -d "$DB" -c "\copy (SELECT * FROM ${v}) TO '$(pwd)/powerbi/data/${v}.csv' CSV HEADER"
  cp "powerbi/data/${v}.csv" "sql/results/${v}.csv"
done

echo "Exported ${#VIEWS[@]} views to powerbi/data/ and sql/results/."
