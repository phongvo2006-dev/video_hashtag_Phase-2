#!/usr/bin/env bash
# Phase 2 — export the raw star-schema tables (4 dimensions + 3 facts) to CSV
# so they can be loaded directly into Power BI and modeled there with
# relationships and DAX measures, on top of (not instead of) the 5
# pre-computed SQL views exported by export_views.sh.
#
# dim_caption.caption_text is intentionally excluded: none of the planned
# Power BI visuals need individual caption text, and including all 200,000
# rows of it would make the file far larger than anything else in the model
# for no analytical benefit. Every other column needed to build the
# relationships is kept.
set -euo pipefail

DB_NAME="${1:-video_hashtag_phase2}"
OUT_DIR="$(dirname "$0")/../powerbi/data/star_schema"
mkdir -p "$OUT_DIR"

declare -A TABLE_COLUMNS=(
  [dim_category]="category_id, category_name"
  [dim_video]="video_id, split, category_id"
  [dim_caption]="caption_id, video_id, caption_index, is_eval_caption"
  [dim_hashtag]="hashtag_id, hashtag_text, is_category_tag"
  [fact_gold_label]="video_id, hashtag_id"
  [fact_caption_metadata]="caption_id, token_count, char_count"
  [fact_prediction]="prediction_id, caption_id, hashtag_id, confidence, rank_in_caption"
)

for table in dim_category dim_video dim_caption dim_hashtag \
             fact_gold_label fact_caption_metadata fact_prediction; do
  cols="${TABLE_COLUMNS[$table]}"
  echo "Exporting ${table} (${cols})..."
  psql -d "$DB_NAME" -c "\copy (SELECT ${cols} FROM ${table}) TO '${OUT_DIR}/${table}.csv' CSV HEADER"
done

echo "Done. Star-schema CSVs written to ${OUT_DIR}/"
