-- Phase 2 — PostgreSQL warehouse schema.
-- Star schema: dim_video / dim_category / dim_caption / dim_hashtag are dimensions;
-- fact_gold_label, fact_prediction, fact_caption_metadata are facts.
-- Only the deployed model (RoBERTa+RL) is modeled here — see data_engineering/load_phase2.py
-- for why the other four Phase-1 comparison models are intentionally not loaded.

DROP TABLE IF EXISTS fact_prediction CASCADE;
DROP TABLE IF EXISTS fact_caption_metadata CASCADE;
DROP TABLE IF EXISTS fact_gold_label CASCADE;
DROP TABLE IF EXISTS dim_caption CASCADE;
DROP TABLE IF EXISTS dim_hashtag CASCADE;
DROP TABLE IF EXISTS dim_video CASCADE;
DROP TABLE IF EXISTS dim_category CASCADE;

CREATE TABLE dim_category (
    category_id   SMALLINT PRIMARY KEY,
    category_name TEXT UNIQUE NOT NULL
);

CREATE TABLE dim_video (
    video_id    TEXT PRIMARY KEY,
    split       TEXT NOT NULL CHECK (split IN ('train', 'val', 'test')),
    category_id SMALLINT REFERENCES dim_category(category_id)
);

CREATE TABLE dim_caption (
    caption_id      BIGINT PRIMARY KEY,
    video_id        TEXT REFERENCES dim_video(video_id),
    caption_index   SMALLINT NOT NULL,
    caption_text    TEXT NOT NULL,
    is_eval_caption BOOLEAN NOT NULL DEFAULT FALSE,
    UNIQUE (video_id, caption_index)
);

CREATE TABLE dim_hashtag (
    hashtag_id      SERIAL PRIMARY KEY,
    hashtag_text    TEXT UNIQUE NOT NULL,
    is_category_tag BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE fact_gold_label (
    video_id   TEXT REFERENCES dim_video(video_id),
    hashtag_id INT  REFERENCES dim_hashtag(hashtag_id),
    PRIMARY KEY (video_id, hashtag_id)
);

CREATE TABLE fact_caption_metadata (
    caption_id  BIGINT PRIMARY KEY REFERENCES dim_caption(caption_id),
    token_count SMALLINT,
    char_count  SMALLINT
);

-- RoBERTa+RL predictions on each video's eval caption only, confidence >= 0.40
-- (the model's own best Set-F1 operating point — see data_engineering/load_phase2.py).
CREATE TABLE fact_prediction (
    prediction_id   BIGSERIAL PRIMARY KEY,
    caption_id      BIGINT REFERENCES dim_caption(caption_id),
    hashtag_id      INT    REFERENCES dim_hashtag(hashtag_id),
    confidence      REAL NOT NULL,
    rank_in_caption SMALLINT
);
CREATE INDEX ix_fact_prediction_caption ON fact_prediction(caption_id);
CREATE INDEX ix_fact_prediction_hashtag ON fact_prediction(hashtag_id);
