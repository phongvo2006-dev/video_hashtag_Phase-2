-- Phase 2 — analytical views. SQL does every join/aggregation; Power BI only visualizes
-- the already-computed rows below. Run with: psql -d video_hashtag_phase2 -f sql/03_views.sql
--
-- Metric definitions shared by the views (see sql/business_questions.md):
--   * Views 2-3 count ALL gold labels per video (including the category-name label).
--   * Views 1 and 5 use topic hashtags only (is_category_tag = FALSE).
--   * Views 4-5 use predictions attached to evaluation captions (is_eval_caption = TRUE).
--   * A prediction is low-confidence when confidence < 0.50.

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
-- A video-level lookup that lets a content reviewer or creator-support agent
-- see one video's substantive tags without the category-name tag that every
-- video in a category shares trivially.
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
-- how many gold labels per video on average, and how does that compare to
-- the dataset-wide average in the same row?
--
-- BUSINESS PURPOSE:
-- Help the Content Operations team size review/QA effort per category, with
-- the dataset-wide benchmark attached to every row.
-- LEFT JOINs keep categories and videos that have no gold-label rows.
CREATE OR REPLACE VIEW vw_category_overview AS
SELECT
    c.category_name,
    COUNT(DISTINCT v.video_id)                                              AS video_count,
    COUNT(DISTINCT g.hashtag_id)                                            AS distinct_hashtag_count,
    ROUND(COUNT(g.hashtag_id)::NUMERIC / NULLIF(COUNT(DISTINCT v.video_id), 0), 2)
                                                                            AS avg_tags_per_video,
    (SELECT ROUND((SELECT COUNT(*) FROM fact_gold_label)::NUMERIC
                  / NULLIF((SELECT COUNT(*) FROM dim_video), 0), 2))        AS dataset_avg_tags_per_video
FROM dim_category c
LEFT JOIN dim_video v ON v.category_id = c.category_id
LEFT JOIN fact_gold_label g ON g.video_id = v.video_id
GROUP BY c.category_id, c.category_name;

-- ============================================================
-- 3. GROUP BY ... HAVING + a scalar subquery
-- ============================================================

-- BUSINESS QUESTION:
-- Which categories have an average gold-label count per video ABOVE the
-- dataset-wide average?
--
-- BUSINESS PURPOSE:
-- A short, SQL-filtered outlier list for lightweight sampling review. Same
-- population and tag-count definition as view 2; the comparison uses the
-- unrounded averages.
CREATE OR REPLACE VIEW vw_high_tag_density_categories AS
SELECT c.category_name,
       COUNT(DISTINCT v.video_id)                                                  AS video_count,
       ROUND(COUNT(g.hashtag_id)::NUMERIC / NULLIF(COUNT(DISTINCT v.video_id), 0), 2) AS avg_tags_per_video
FROM dim_category c
LEFT JOIN dim_video v ON v.category_id = c.category_id
LEFT JOIN fact_gold_label g ON g.video_id = v.video_id
GROUP BY c.category_id, c.category_name
HAVING COUNT(g.hashtag_id)::NUMERIC / NULLIF(COUNT(DISTINCT v.video_id), 0) >
       (SELECT (SELECT COUNT(*) FROM fact_gold_label)::NUMERIC
               / NULLIF((SELECT COUNT(*) FROM dim_video), 0))
ORDER BY avg_tags_per_video DESC;

-- ============================================================
-- 4. GROUP BY + conditional aggregation
-- ============================================================

-- BUSINESS QUESTION:
-- In which categories are predictions below the 0.50 confidence threshold
-- most frequent?
--
-- BUSINESS PURPOSE:
-- Help the Operations team decide which categories' auto-generated hashtags
-- need closer inspection. pct_low_confidence_predictions is on a 0-100 scale
-- (20.90 = 20.90%). NULL metrics mean no evaluation predictions exist for the
-- category, not zero confidence. Rank on demand with ORDER BY ... LIMIT.
CREATE OR REPLACE VIEW vw_confidence_by_category AS
SELECT c.category_name,
       COUNT(fp.prediction_id)                                                     AS prediction_count,
       ROUND(AVG(fp.confidence)::NUMERIC, 4)                                       AS avg_confidence,
       ROUND(100.0 * COUNT(fp.prediction_id) FILTER (WHERE fp.confidence < 0.5)
             / NULLIF(COUNT(fp.prediction_id), 0), 2)                              AS pct_low_confidence_predictions
FROM dim_category c
LEFT JOIN dim_video v ON v.category_id = c.category_id
LEFT JOIN dim_caption cap ON cap.video_id = v.video_id AND cap.is_eval_caption
LEFT JOIN fact_prediction fp ON fp.caption_id = cap.caption_id
GROUP BY c.category_name;

-- ============================================================
-- 5. CTEs + window functions (AVG() OVER (), RANK() OVER ())
-- ============================================================

-- BUSINESS QUESTION:
-- Which categories are below the dataset-wide benchmark on BOTH average
-- prediction confidence and topic-coverage recall, and in what order should
-- a reviewer inspect them?
--
-- BUSINESS PURPOSE:
-- Turn two diagnostic signals into one decision-ready, pre-ranked list.
--   topic_gold      non-category gold (video, hashtag) pairs
--   topic_coverage  per category, how many of those pairs were predicted for
--                   the same video (correlated EXISTS on the exact pair)
--   confidence      per category, total and count of evaluation-caption
--                   prediction confidences
--   combined        attaches the dataset-wide benchmarks, each the average of
--                   the category-level values (macro average, the same
--                   benchmark the Power BI scatter uses), via AVG() OVER ()
--   classified      assigns review_priority
-- Priority: 'High Priority Review' = both metrics below benchmark; 'Normal' =
-- both available but not both below; 'Insufficient Data' = either metric is
-- unavailable. RANK() puts High Priority first, then lower confidence, then
-- lower coverage, with Insufficient Data last and category_name as the final
-- tie-breaker.
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
                   SELECT 1
                   FROM fact_prediction p
                   INNER JOIN dim_caption cap ON p.caption_id = cap.caption_id
                   WHERE cap.is_eval_caption
                     AND cap.video_id = tg.video_id
                     AND p.hashtag_id = tg.hashtag_id
               )
           ) AS predicted_hit_count
    FROM topic_gold tg
    GROUP BY tg.category_id
),
confidence AS (
    SELECT v.category_id,
           SUM(p.confidence)::NUMERIC AS confidence_sum,
           COUNT(*)                   AS prediction_count
    FROM fact_prediction p
    INNER JOIN dim_caption cap ON p.caption_id = cap.caption_id AND cap.is_eval_caption
    INNER JOIN dim_video v ON cap.video_id = v.video_id
    GROUP BY v.category_id
),
combined AS (
    SELECT c.category_id,
           c.category_name,
           conf.confidence_sum / NULLIF(conf.prediction_count, 0)             AS avg_confidence,
           cov.predicted_hit_count::NUMERIC / NULLIF(cov.gold_topic_assignments, 0)
                                                                              AS coverage_recall,
           AVG(conf.confidence_sum / NULLIF(conf.prediction_count, 0)) OVER ()  AS dataset_avg_confidence,
           AVG(cov.predicted_hit_count::NUMERIC
               / NULLIF(cov.gold_topic_assignments, 0)) OVER ()                 AS dataset_avg_coverage_recall
    FROM dim_category c
    LEFT JOIN confidence conf ON conf.category_id = c.category_id
    LEFT JOIN topic_coverage cov ON cov.category_id = c.category_id
),
classified AS (
    SELECT *,
           CASE
               WHEN avg_confidence IS NULL OR coverage_recall IS NULL THEN 'Insufficient Data'
               WHEN avg_confidence < dataset_avg_confidence
                AND coverage_recall < dataset_avg_coverage_recall THEN 'High Priority Review'
               ELSE 'Normal'
           END AS review_priority
    FROM combined
)
SELECT
    RANK() OVER (
        ORDER BY CASE review_priority
                     WHEN 'High Priority Review' THEN 0
                     WHEN 'Normal' THEN 1
                     ELSE 2
                 END,
                 avg_confidence ASC NULLS LAST,
                 coverage_recall ASC NULLS LAST,
                 category_name
    ) AS review_rank,
    category_name,
    ROUND(avg_confidence, 4)             AS avg_confidence,
    ROUND(coverage_recall, 4)            AS coverage_recall,
    ROUND(dataset_avg_confidence, 4)     AS dataset_avg_confidence,
    ROUND(dataset_avg_coverage_recall, 4) AS dataset_avg_coverage_recall,
    review_priority
FROM classified
ORDER BY review_rank;
