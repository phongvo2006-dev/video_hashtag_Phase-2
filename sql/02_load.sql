-- Phase 2 — load the flat CSVs from data_engineering/exports/ into the star schema.
-- Run with: bash sql/load.sh [path/to/data_engineering/exports] [db_name]
-- (the __EXPORTS_DIR__ placeholder below is substituted by that script)

CREATE TEMP TABLE stg_videos (
    video_id TEXT, split TEXT, category_id SMALLINT, category_name TEXT
);
CREATE TEMP TABLE stg_captions (
    caption_id BIGINT, video_id TEXT, caption_index SMALLINT, caption_text TEXT,
    is_eval_caption BOOLEAN, token_count SMALLINT, char_count SMALLINT
);
CREATE TEMP TABLE stg_gold_labels (video_id TEXT, hashtag_text TEXT);
CREATE TEMP TABLE stg_predictions (
    caption_id BIGINT, video_id TEXT, hashtag_text TEXT, confidence REAL, rank_in_caption SMALLINT
);

\copy stg_videos FROM '__EXPORTS_DIR__/videos.csv' CSV HEADER
\copy stg_captions FROM '__EXPORTS_DIR__/captions.csv' CSV HEADER
\copy stg_gold_labels FROM '__EXPORTS_DIR__/gold_labels.csv' CSV HEADER
\copy stg_predictions FROM '__EXPORTS_DIR__/predictions.csv' CSV HEADER

INSERT INTO dim_category (category_id, category_name)
SELECT DISTINCT category_id, category_name FROM stg_videos;

INSERT INTO dim_video (video_id, split, category_id)
SELECT video_id, split, category_id FROM stg_videos;

INSERT INTO dim_caption (caption_id, video_id, caption_index, caption_text, is_eval_caption)
SELECT caption_id, video_id, caption_index, caption_text, is_eval_caption FROM stg_captions;

INSERT INTO fact_caption_metadata (caption_id, token_count, char_count)
SELECT caption_id, token_count, char_count FROM stg_captions;

INSERT INTO dim_hashtag (hashtag_text, is_category_tag)
SELECT DISTINCT h.hashtag_text, (h.hashtag_text IN (SELECT category_name FROM dim_category))
FROM (
    SELECT hashtag_text FROM stg_gold_labels
    UNION
    SELECT hashtag_text FROM stg_predictions
) h;

INSERT INTO fact_gold_label (video_id, hashtag_id)
SELECT g.video_id, h.hashtag_id
FROM stg_gold_labels g
JOIN dim_hashtag h ON h.hashtag_text = g.hashtag_text;

INSERT INTO fact_prediction (caption_id, hashtag_id, confidence, rank_in_caption)
SELECT p.caption_id, h.hashtag_id, p.confidence, p.rank_in_caption
FROM stg_predictions p
JOIN dim_hashtag h ON h.hashtag_text = p.hashtag_text;

-- quick sanity counts
SELECT 'dim_category' AS t, COUNT(*) FROM dim_category
UNION ALL SELECT 'dim_video', COUNT(*) FROM dim_video
UNION ALL SELECT 'dim_caption', COUNT(*) FROM dim_caption
UNION ALL SELECT 'dim_hashtag', COUNT(*) FROM dim_hashtag
UNION ALL SELECT 'fact_gold_label', COUNT(*) FROM fact_gold_label
UNION ALL SELECT 'fact_caption_metadata', COUNT(*) FROM fact_caption_metadata
UNION ALL SELECT 'fact_prediction', COUNT(*) FROM fact_prediction;
