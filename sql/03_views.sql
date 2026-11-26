-- Phase 2 — analytical views. SQL does every join/aggregation; Power BI only visualizes
-- the already-computed rows below. Run with: psql -d video_hashtag_phase2 -f sql/03_views.sql

DROP VIEW IF EXISTS vw_category_review_priority;
DROP VIEW IF EXISTS vw_confidence_by_category;
DROP VIEW IF EXISTS vw_high_tag_density_categories;
DROP VIEW IF EXISTS vw_category_overview;
DROP VIEW IF EXISTS vw_video_topic_tags;
DROP VIEW IF EXISTS vw_top_tags_by_category;
DROP VIEW IF EXISTS vw_topic_coverage_gap;

-- ============================================================
-- 1. plain joins, no aggregation
-- ============================================================

-- BUSINESS QUESTION:
-- For a given video, what specific topic hashtags (excluding the category's
-- own name tag) were assigned to it by the gold labels?
--
-- BUSINESS PURPOSE:
-- The simplest possible video-level lookup: lets a content reviewer or
-- creator-support agent pull up one video's substantive tags without
-- wading through the category-name tag that every video in a category
-- shares trivially. Foundation for every "which topics" question that
-- follows. 
CREATE OR REPLACE VIEW vw_video_topic_tags AS
SELECT v.video_id, c.category_name, h.hashtag_text
FROM fact_gold_label g
INNER JOIN dim_video v ON g.video_id = v.video_id
INNER JOIN dim_category c ON v.category_id = c.category_id
INNER JOIN dim_hashtag h ON g.hashtag_id = h.hashtag_id
WHERE h.is_category_tag = FALSE;

-- ============================================================
-- 2. GROUP BY + a scalar-subquery context column
-- ============================================================

-- BUSINESS QUESTION:
-- How many videos and distinct hashtags does each content category have,
-- how many tags per video on average, and how does that compare to the
-- dataset-wide average in the same row?
--
-- BUSINESS PURPOSE:
-- Help the Content Operations team size review/QA effort per category,
-- with the dataset-wide benchmark attached to every row so a viewer never
-- has to cross-reference a second number to tell "high" from "low".

CREATE OR REPLACE VIEW vw_category_overview AS
SELECT
    c.category_name,
    COUNT(DISTINCT v.video_id)                                              AS video_count,
    COUNT(DISTINCT g.hashtag_id)                                            AS distinct_hashtag_count,
    ROUND(COUNT(g.hashtag_id)::NUMERIC / COUNT(DISTINCT v.video_id), 2)     AS avg_tags_per_video,
    (SELECT ROUND(COUNT(*)::NUMERIC / COUNT(DISTINCT video_id), 2)
     FROM fact_gold_label)                                                 AS dataset_avg_tags_per_video
FROM dim_video v
INNER JOIN dim_category c ON v.category_id = c.category_id
INNER JOIN fact_gold_label g ON v.video_id = g.video_id
GROUP BY c.category_id, c.category_name;

-- ============================================================
-- 3. GROUP BY ... HAVING + a scalar subquery
-- ============================================================

-- BUSINESS QUESTION:
-- Which categories have an average tags-per-video ABOVE the dataset-wide
-- average, i.e. are meaningfully more hashtag-dense than a typical video?
--
-- BUSINESS PURPOSE:
-- Give Content Operations a short, SQL-filtered outlier list (not the full
-- 20-row table) of categories where tagging effort per video already runs
-- high, to prioritise lightweight sampling review instead of full review.

CREATE OR REPLACE VIEW vw_high_tag_density_categories AS
SELECT c.category_name,
       COUNT(DISTINCT v.video_id)                                          AS video_count,
       ROUND(COUNT(g.hashtag_id)::numeric / COUNT(DISTINCT v.video_id), 2) AS avg_tags_per_video
FROM dim_video v
JOIN dim_category c ON c.category_id = v.category_id
JOIN fact_gold_label g ON g.video_id = v.video_id
GROUP BY c.category_name
HAVING COUNT(g.hashtag_id)::numeric / COUNT(DISTINCT v.video_id) >
       (SELECT COUNT(*)::numeric / COUNT(DISTINCT video_id) FROM fact_gold_label)
ORDER BY avg_tags_per_video DESC;

-- ============================================================
-- 4. GROUP BY, ranked via ORDER BY / LIMIT
-- ============================================================

-- BUSINESS QUESTION:
-- In which categories does the deployed model (RoBERTa+RL) predict with
-- low confidence most often?
--
-- BUSINESS PURPOSE:
-- Help the Operations/content-moderation team decide which categories'
-- auto-generated hashtags need human review before publishing. The view
-- itself is a plain GROUP BY; ranking it ("top 5 worst") is left to an
-- ORDER BY ... LIMIT query on top, run on demand rather than baked into
-- the view. See sql/business_questions.md, question 4.
CREATE OR REPLACE VIEW vw_confidence_by_category AS
SELECT c.category_name,
       ROUND(AVG(fp.confidence)::numeric, 4)                     AS avg_confidence,
       ROUND(AVG((fp.confidence < 0.5)::int)::numeric, 4)        AS pct_low_confidence_predictions
FROM fact_prediction fp
JOIN dim_caption cap ON cap.caption_id = fp.caption_id AND cap.is_eval_caption
JOIN dim_video v ON v.video_id = cap.video_id
JOIN dim_category c ON c.category_id = v.category_id
GROUP BY c.category_name;

-- ============================================================
-- 5. CTEs + window functions (AVG() OVER(), RANK() OVER())
-- ============================================================

-- BUSINESS QUESTION:
-- Combining both trust signals, which categories should be flagged for
-- PRIORITY human review — i.e. both below-average prediction confidence
-- AND below-average topic-coverage recall at the same time — and in what
-- order should a reviewer work through them?
--
-- BUSINESS PURPOSE:
-- Turn two separate diagnostic signals into one decision-ready, pre-ranked
-- list instead of two charts a reviewer has to cross-reference manually.
-- Technique: 5 CTEs build up the two signals from base tables (topic_gold
-- restricts gold labels to non-category-name hashtags; topic_coverage
-- computes, per category, how many of those gold (video, hashtag) pairs
-- the model actually predicted, via an EXISTS subquery; coverage turns that
-- into a recall ratio; confidence aggregates prediction confidence per
-- category; combined attaches the dataset-wide average of EACH signal to
-- every row using AVG(...) OVER (), so no separate scalar-subquery pass is
-- needed). A final RANK() OVER (...) orders every category by priority
-- tier first, then by how weak its signals are, so the output is ready to
-- read top-to-bottom without any further sorting in Power BI.
-- See sql/business_questions.md, question 5.
CREATE OR REPLACE VIEW vw_category_review_priority AS
WITH topic_gold AS (
    SELECT v.category_id, g.video_id, g.hashtag_id
    FROM fact_gold_label g
    INNER JOIN dim_video v ON g.video_id = v.video_id
    INNER JOIN dim_hashtag h ON g.hashtag_id = h.hashtag_id
    WHERE h.is_category_tag = FALSE
),
topic_coverage AS (
    SELECT tg.category_id,
           COUNT(*) AS gold_topic_assignments,
           COUNT(*) FILTER (
               WHERE EXISTS (
                   SELECT 1 FROM fact_prediction p
                   INNER JOIN dim_caption cap ON p.caption_id = cap.caption_id
                   WHERE cap.video_id = tg.video_id AND p.hashtag_id = tg.hashtag_id
               )
           ) AS predicted_hit_count
    FROM topic_gold tg
    GROUP BY tg.category_id
),
coverage AS (
    SELECT category_id,
           predicted_hit_count::NUMERIC / NULLIF(gold_topic_assignments, 0) AS coverage_recall
    FROM topic_coverage
),
confidence AS (
    SELECT v.category_id, AVG(p.confidence)::NUMERIC AS avg_confidence
    FROM fact_prediction p
    INNER JOIN dim_caption cap ON p.caption_id = cap.caption_id
    INNER JOIN dim_video v ON cap.video_id = v.video_id
    GROUP BY v.category_id
),
combined AS (
    SELECT c.category_id, c.category_name,
           conf.avg_confidence, cov.coverage_recall,
           AVG(conf.avg_confidence) OVER () AS avg_category_confidence,
           AVG(cov.coverage_recall) OVER ()  AS avg_category_coverage
    FROM dim_category c
    INNER JOIN confidence conf ON c.category_id = conf.category_id
    INNER JOIN coverage cov ON c.category_id = cov.category_id
),
classified AS (
    SELECT *,
           CASE WHEN avg_confidence < avg_category_confidence
                 AND coverage_recall < avg_category_coverage
                THEN 'High Priority Review' ELSE 'Normal' END AS review_priority
    FROM combined
)
SELECT
    RANK() OVER (
        ORDER BY CASE WHEN review_priority = 'High Priority Review' THEN 0 ELSE 1 END,
                 avg_confidence ASC, coverage_recall ASC
    ) AS review_rank,
    category_name,
    ROUND(avg_confidence, 4)  AS avg_confidence,
    ROUND(coverage_recall, 4) AS coverage_recall,
    review_priority
FROM classified
ORDER BY review_rank;
