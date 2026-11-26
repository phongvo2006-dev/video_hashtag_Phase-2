# Business Questions & SQL Analysis

This document explains the five analytical views defined in
[`03_views.sql`](03_views.sql). Each section connects a business scenario
to the question, SQL technique, and intended interpretation.

> **Data validation note:** The SQL definitions have been revised for
> consistent populations and metric definitions. The result tables and
> category rankings from earlier drafts should not be reused as verified
> outputs. Re-run the queries against the current `video_hashtag_phase2`
> database and refresh any reported numbers before publishing them.

## Shared metric definitions

- **Gold labels / tag density:** Questions 2 and 3 count all gold labels,
  including the category-name label. This keeps the category and
  dataset-wide averages on the same definition.
- **Topic hashtags / topic coverage:** Questions 1 and 5 exclude
  category-name labels (`is_category_tag = FALSE`).
- **Evaluation predictions:** Questions 4 and 5 use predictions attached
  only to captions where `is_eval_caption = TRUE`.
- **Low-confidence threshold:** A prediction is low-confidence when
  `confidence < 0.50`.
- **Percentage scale:** `pct_low_confidence_predictions` is returned on a
  0–100 scale. For example, `20.90` means 20.90%.
- **Dataset benchmarks in question 5:** Confidence and coverage benchmarks
  are weighted across all prediction rows and all gold topic pairs,
  respectively. They are not unweighted averages of category averages.

---

## 1. `vw_video_topic_tags` — Video-Level Topic Lookup

**Complexity: Beginner** — plain joins, no aggregation.

| | |
|---|---|
| **Business Scenario** | A content reviewer or creator-support agent has a video and needs to identify its specific subject matter, beyond its broad category. |
| **Business Objective** | Show the topic hashtags assigned to an individual video while excluding the category-name tag, which adds little video-specific information. |
| **Business Question** | For a given video, which topic hashtags were assigned by the gold labels? |
| **SQL Technique** | `INNER JOIN` across the gold-label fact table and the video, category, and hashtag dimensions; filtered with `WHERE`. |

**Example query**

```sql
SELECT video_id, category_name, hashtag_text
FROM vw_video_topic_tags
WHERE category_name = 'ads'
ORDER BY video_id, hashtag_text
LIMIT 10;
```

**How to interpret the result**

Each row represents one video–topic-hashtag assignment. A video can therefore
appear on multiple rows. The view is suitable for a video-level detail table
or drill-through page in Power BI.

**Business use**

When a reviewer selects a video, this view provides its topic-level gold
labels without repeating the category tag as if it were a specific topic.

---

## 2. `vw_category_overview` — Content Catalogue Sizing

**Complexity: Beginner / Intermediate** — `GROUP BY` plus a scalar subquery.

| | |
|---|---|
| **Business Scenario** | The Content Operations team is planning review capacity and QA effort across content categories. |
| **Business Objective** | Compare category size and gold-label density using a common dataset-wide benchmark. |
| **Business Question** | How many videos and distinct hashtags does each category have, how many gold labels per video does it have on average, and how does that compare with the dataset-wide average? |
| **SQL Technique** | `GROUP BY`, aggregate functions, `LEFT JOIN`, and a non-correlated scalar subquery in the `SELECT` list. |

**Example query**

```sql
SELECT
    category_name,
    video_count,
    distinct_hashtag_count,
    avg_tags_per_video,
    dataset_avg_tags_per_video
FROM vw_category_overview
ORDER BY video_count DESC;
```

**How to interpret the result**

- `video_count` counts videos assigned to the category, including videos
  with no gold-label rows.
- `distinct_hashtag_count` counts distinct gold-label hashtags observed
  in that category.
- `avg_tags_per_video` counts all gold labels per video, including the
  category-name label.
- `dataset_avg_tags_per_video` uses the same per-video definition across
  the complete video catalogue.

The `LEFT JOIN` structure ensures that categories and videos are not
silently dropped just because they have no gold-label rows.

**Business use**

Use video volume to estimate the scale of category-level review work and
tag density to understand how many gold-label assignments are typically
associated with each video. Tag density alone should not be interpreted
as evidence of higher or lower model quality.

---

## 3. `vw_high_tag_density_categories` — Above-Average Tag Density

**Complexity: Intermediate** — `GROUP BY ... HAVING` with a scalar subquery.

| | |
|---|---|
| **Business Scenario** | After reviewing the full category breakdown, Content Operations wants a filtered list of categories whose gold-label density is above the dataset benchmark. |
| **Business Objective** | Identify categories with above-average gold-label counts per video using a SQL-computed threshold. |
| **Business Question** | Which categories have an average number of gold labels per video above the dataset-wide average? |
| **SQL Technique** | `GROUP BY`, `HAVING`, aggregate functions, `LEFT JOIN`, and a scalar subquery used as a group filter. |

**Example query**

```sql
SELECT
    category_name,
    video_count,
    avg_tags_per_video
FROM vw_high_tag_density_categories
ORDER BY avg_tags_per_video DESC;
```

**How to interpret the result**

Only categories whose unrounded average exceeds the unrounded dataset-wide
average are returned. The view uses the same population and tag-count
definition as question 2, so the comparison is consistent.

**Business use**

The result can help Content Operations identify categories with relatively
dense tagging workloads for further sampling or process review. A high
number of tags per video does not, by itself, prove that a category requires
more manual review or that its labels are less accurate.

---

## 4. `vw_confidence_by_category` — Prediction Confidence by Category

**Complexity: Intermediate** — `GROUP BY` and conditional aggregation.

| | |
|---|---|
| **Business Scenario** | The Operations team needs to understand where the deployed RoBERTa+RL model produces predictions with lower confidence. |
| **Business Objective** | Compare average prediction confidence and the share of predictions below the chosen confidence threshold across categories. |
| **Business Question** | In which categories are predictions below the 0.50 confidence threshold most frequent? |
| **SQL Technique** | `LEFT JOIN`, `GROUP BY`, `AVG`, `COUNT`, and aggregate `FILTER` for conditional counting. |

**Example query**

```sql
SELECT
    category_name,
    prediction_count,
    avg_confidence,
    pct_low_confidence_predictions
FROM vw_confidence_by_category
ORDER BY pct_low_confidence_predictions DESC NULLS LAST
LIMIT 5;
```

**How to interpret the result**

- `prediction_count` is the number of materialised predictions associated
  with evaluation captions in the category.
- `avg_confidence` is the mean confidence across those predictions.
- `pct_low_confidence_predictions` is the percentage of predictions with
  confidence below 0.50, expressed on a 0–100 scale.
- `NULL` confidence metrics indicate that no evaluation predictions were
  available for that category; they do not mean zero confidence.

Average confidence and low-confidence percentage describe different
aspects of the prediction distribution. Both should be considered rather
than treating either metric as a complete measure of model quality.

**Business use**

Use the low-confidence share to identify categories that may warrant closer
inspection. The 0.50 threshold is an operational threshold for this
analysis; it should not be presented as a calibrated probability or proof
that a prediction is incorrect.

---

## 5. `vw_category_review_priority` — Combined Review Priority

**Complexity: Advanced** — five CTEs, a correlated `EXISTS` subquery, and
window functions.

| | |
|---|---|
| **Business Scenario** | Operations has separate confidence and topic-coverage diagnostics but needs one consolidated view to decide which categories to investigate first. |
| **Business Objective** | Flag categories only when both prediction confidence and topic-coverage recall are below their respective dataset-wide benchmarks. |
| **Business Question** | Which categories are below the dataset-wide benchmark on both average prediction confidence and topic-coverage recall, and in what order should reviewers inspect them? |
| **SQL Technique** | Five CTEs (`topic_gold`, `topic_coverage`, `confidence`, `combined`, `classified`), a correlated `EXISTS` subquery, weighted window aggregates, and `RANK() OVER (...)`. |

**Example query**

```sql
SELECT
    review_rank,
    category_name,
    avg_confidence,
    coverage_recall,
    dataset_avg_confidence,
    dataset_avg_coverage_recall,
    review_priority
FROM vw_category_review_priority
ORDER BY review_rank;
```

**Metric definitions**

- **Gold topic assignments:** Each non-category gold `(video_id, hashtag_id)`
  pair is one assignment.
- **Predicted hit:** A gold topic assignment is counted as covered if the
  same hashtag appears in at least one prediction attached to an evaluation
  caption for that same video.
- **Coverage recall:** `predicted_hit_count / gold_topic_assignments`.
- **Average confidence:** Mean confidence across predictions attached to
  evaluation captions in the category.
- **Dataset confidence benchmark:** Total confidence across all eligible
  predictions divided by the total number of eligible predictions.
- **Dataset coverage benchmark:** Total matched gold topic pairs divided
  by the total gold topic assignments.

The `EXISTS` condition checks the exact video–hashtag pair. It does not
count a hashtag as covered merely because the model predicted it for a
different video in the same category.

**Priority rules**

1. `High Priority Review`: both category metrics are below their respective
   weighted dataset-wide benchmarks.
2. `Normal`: both metrics are available, but the two-signal condition is
   not met.
3. `Insufficient Data`: either confidence or topic coverage is unavailable
   for that category.

The ranking places `High Priority Review` categories first, then orders
them by lower confidence and lower coverage. Categories with insufficient
data are placed last. The category name is included as a final tie-breaker
for deterministic ordering.

**Business use**

Use this view as a consolidated category-level review queue. It combines
two distinct warning signals while avoiding the assumption that low
confidence alone necessarily means poor topic coverage, or vice versa.

---

## Re-running and validating the results

The SQL views contain the analytical logic; the figures shown in a report
or dashboard should be generated from the current database, not manually
copied from an older draft.

After running `03_views.sql`, inspect each view with:

```sql
SELECT * FROM vw_video_topic_tags LIMIT 10;
SELECT * FROM vw_category_overview ORDER BY video_count DESC;
SELECT * FROM vw_high_tag_density_categories;
SELECT * FROM vw_confidence_by_category
ORDER BY pct_low_confidence_predictions DESC NULLS LAST;
SELECT * FROM vw_category_review_priority ORDER BY review_rank;
```

For a reproducible GitHub snapshot, export the query results from PostgreSQL
after validation. Refresh any numeric examples in the README and this
document from those current outputs.

**Scope note:** These views describe gold-label volume, prediction
confidence, and exact topic-tag coverage. They do not measure engagement,
reach, click-through rate, or recommendation impact because those outcome
data are not part of the tables used here.
