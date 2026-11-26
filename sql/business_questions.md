# Business Questions & SQL Analysis

This document connects each of the five analytical SQL views in
[`03_views.sql`](03_views.sql) to a concrete business scenario, the
question it answers, the actual query result from this dataset, and the
insight/recommendation that follows from it.

> **Revision note:** this file moved from `docs/business_questions.md` into
> `sql/`, next to the views it documents, and was redesigned from 6
> questions down to **5**, ordered as a progressive **SQL-complexity
> ladder** (Beginner → Advanced) rather than a flat list. `vw_top_tags_by_category`
> was retired in favour of a new Beginner-level view, `vw_video_topic_tags`
> (a video-level drill-in rather than a category-level ranked list).
> `vw_topic_coverage_gap` was retired as a standalone view: its per-hashtag
> coverage logic now lives inline, as a CTE using `EXISTS`, inside the
> rewritten `vw_category_review_priority` (question 5), which also switched
> from two CTEs + scalar subqueries to 5 CTEs + window functions
> (`AVG() OVER ()`, `RANK() OVER (...)`). The `docs/` folder was removed;
> dashboard-level analysis for Power BI now lives in the README's Power BI
> section instead.

------------------------------------------------------------------------

## 1. `vw_video_topic_tags` — Video-Level Topic Lookup

**Complexity: Beginner** — plain joins, no aggregation.

| | |
|---|---|
| **Business Scenario** | A content reviewer or creator-support agent has one video in front of them and needs to know what it's actually about, not just which category it was filed under. |
| **Business Objective** | Surface a video's specific topic hashtags, excluding the category's own name tag (every video in `ads` already carries the tag `ads` — that's not information). |
| **Business Question** | For a given video, what specific topic hashtags were assigned to it? |
| **SQL Technique** | Three plain `INNER JOIN`s and a `WHERE h.is_category_tag = FALSE` filter. No `GROUP BY`, no subquery — the foundation the other four questions build on. |

**SQL Query**

```sql
SELECT video_id, category_name, hashtag_text
FROM vw_video_topic_tags
WHERE category_name = 'ads'
ORDER BY video_id, hashtag_text
LIMIT 10;
```

**Query Result**

| video_id | category_name | hashtag_text |
|---|---|---|
| video1167 | ads | beach |
| video1167 | ads | crowd |
| video1167 | ads | horse |
| video1167 | ads | riding |
| video1167 | ads | speech |
| video1282 | ads | robot |
| video1282 | ads | serving |
| video1286 | ads | drawing |
| video1286 | ads | paper |
| video1286 | ads | school |

The full view holds **30,561 topic-tag assignments across 9,496 distinct
videos** (of 10,000 total — the remaining 504 videos have only their
category-name tag as a gold label, no additional topic tags).

**Business Insight**

The category tag alone tells a reviewer almost nothing about a specific
video's content. `video1167` is filed under `ads`, but its actual subject
matter — a horse-riding scene with a crowd and a speech — only shows up
once the category-name tag is filtered out.

**Recommendation**

Use this view as the row-level detail behind any dashboard drill-through:
a reviewer clicking into a flagged video (from question 5's priority list,
for example) should land on this query, filtered to that `video_id`, rather
than being shown the category tag again.

------------------------------------------------------------------------

## 2. `vw_category_overview` — Content Catalogue Sizing

**Complexity: Beginner / Intermediate** — `GROUP BY` plus a scalar-subquery
context column.

| | |
|---|---|
| **Business Scenario** | The Content Operations team is planning headcount and tooling budget for content moderation and tagging quality control across the catalogue. |
| **Business Objective** | Understand how large each content category is and how hashtag-dense it is, with the dataset-wide benchmark attached to every row so no one has to look it up separately. |
| **Business Question** | How many videos and distinct hashtags does each category have, how many tags per video on average, and how does that compare to the dataset-wide average? |
| **SQL Technique** | A **non-correlated scalar subquery** in the `SELECT` list (`(SELECT ... FROM fact_gold_label)`), evaluated once and repeated on every group — the step between a plain `GROUP BY` and `HAVING` with a subquery (question 3). |

**SQL Query**

```sql
SELECT category_name, video_count, distinct_hashtag_count,
       avg_tags_per_video, dataset_avg_tags_per_video
FROM vw_category_overview
ORDER BY video_count DESC
LIMIT 5;
```

**Query Result**

| category_name | video_count | distinct_hashtag_count | avg_tags_per_video | dataset_avg_tags_per_video |
|---|---:|---:|---:|---:|
| sports | 1,108 | 228 | 4.93 | 4.06 |
| movies | 1,019 | 261 | 3.42 | 4.06 |
| autos | 815 | 187 | 4.36 | 4.06 |
| music | 733 | 217 | 4.68 | 4.06 |
| food | 643 | 174 | 5.15 | 4.06 |

Across the full catalogue (all 20 categories): 10,000 videos, 367 distinct
hashtags, and a dataset-wide average of **4.06** tags per video.

**Business Insight**

`sports` is both the single largest category (11.1% of all videos) and
one of the highest-tagged, so it concentrates the most tagging volume.
`movies` is larger still in distinct-hashtag richness (261 hashtags) but
sits *below* the 4.06 dataset average at 3.42 tags/video — size and tag
density are independent dimensions, and the `dataset_avg_tags_per_video`
column makes that comparison immediate on every row instead of requiring
a second lookup.

**Recommendation**

Prioritise review and QA tooling capacity for `sports` and `movies` first
because they carry the largest absolute volume of tagging decisions. For
categories whose `avg_tags_per_video` already clears the attached
`dataset_avg_tags_per_video` benchmark, consider a lighter-touch, higher-
frequency sampling review instead of reviewing every video — question 3
turns this exact comparison into a pre-filtered shortlist.

------------------------------------------------------------------------

## 3. `vw_high_tag_density_categories` — Tagging-Effort Outliers

**Complexity: Intermediate** — `GROUP BY ... HAVING` against a
non-correlated scalar subquery.

| | |
|---|---|
| **Business Scenario** | Content Operations has already seen the full category breakdown (question 2) and now wants a short, pre-filtered list of outliers, not all 20 rows, to decide where lightweight sampling review is enough. |
| **Business Objective** | Isolate exactly which categories run meaningfully denser tagging than a typical video, using a SQL-computed cutoff rather than an eyeballed one. |
| **Business Question** | Which categories have an average tags-per-video **above** the dataset-wide average? |
| **SQL Technique** | `GROUP BY ... HAVING` filtered against a scalar subquery — the same subquery idea as question 2, but used as a *filter* on groups (`HAVING`) instead of an extra *column* (`SELECT`). |

**SQL Query**

```sql
SELECT category_name, video_count, avg_tags_per_video
FROM vw_high_tag_density_categories
ORDER BY avg_tags_per_video DESC;
```

**Query Result** (full result — only 7 of 20 categories clear the bar)

| category_name | video_count | avg_tags_per_video |
|---|---:|---:|
| food | 643 | 5.15 |
| sports | 1,108 | 4.93 |
| animation | 343 | 4.75 |
| music | 733 | 4.68 |
| family | 558 | 4.48 |
| autos | 815 | 4.36 |
| cooking | 342 | 4.32 |

The cutoff is the dataset-wide average: **4.06** tags/video.

**Business Insight**

Only 7 of the 20 categories (35%) are above average, and the gap between
the top (`food`, 5.15) and the cutoff (4.06) is substantial — roughly 27%
denser. This is not a close distribution: a small, identifiable subset of
categories carries disproportionately more tagging signal per video than
the rest.

**Recommendation**

Treat this 7-category list, not the full 20-category table, as the
starting point for Content Operations' lightweight/sampling-review policy
— each video in these categories already carries more tag signal to
cross-check, so full-manual review here has a lower marginal payoff than
spending that same reviewer time on the other 13 categories' sparser
videos.

------------------------------------------------------------------------

## 4. `vw_confidence_by_category` — Prediction Reliability by Category

**Complexity: Intermediate** — `GROUP BY`, ranked on demand via
`ORDER BY ... LIMIT`.

| | |
|---|---|
| **Business Scenario** | The Operations/content-moderation team has limited reviewer capacity and must decide which categories' auto-generated hashtags get a human check before publishing. |
| **Business Objective** | Identify which categories the deployed model (RoBERTa+RL) is least confident in, to prioritise review capacity. |
| **Business Question** | In which categories does the model predict with low confidence most often? |
| **SQL Technique** | The view itself is a plain `GROUP BY` with no ranking baked in; `ORDER BY ... LIMIT` is applied on top, on demand, rather than hard-coding "top 5" into the view definition. |

**SQL Query**

```sql
SELECT category_name, avg_confidence, pct_low_confidence_predictions
FROM vw_confidence_by_category
ORDER BY pct_low_confidence_predictions DESC
LIMIT 5;
```

**Query Result**

| category_name | avg_confidence | pct_low_confidence_predictions |
|---|---:|---:|
| education | 0.7095 | 20.9% |
| documentary | 0.7305 | 18.4% |
| scitech | 0.7118 | 17.8% |
| ads | 0.7387 | 17.5% |
| cooking | 0.7069 | 17.0% |

Dataset-wide: average confidence **0.7712**, with **13.8%** of all
materialised predictions below the 0.5 decision threshold.

**Business Insight**

`education`, `documentary`, and `scitech` are the three categories with
both the highest share of low-confidence predictions and among the lowest
average confidence overall — these are the categories where the model is
most consistently unsure, not just occasionally wrong.

**Recommendation**

Route auto-generated hashtags for `education`, `documentary`, and
`scitech` content through human review by default, while categories with
high average confidence and a low low-confidence rate (e.g. `autos` at
0.8455 average, from `sql/results/vw_category_review_priority.csv`) can
stay on auto-publish with spot-checking only. Question 5 combines this
signal with topic-coverage recall into a single pre-ranked list.

------------------------------------------------------------------------

## 5. `vw_category_review_priority` — Combined, Pre-Ranked Review Priority

**Complexity: Advanced** — 5 CTEs, an `EXISTS` subquery, and two window
functions (`AVG() OVER ()`, `RANK() OVER (...)`).

| | |
|---|---|
| **Business Scenario** | Operations (question 4) has one diagnostic signal, but a reviewer scanning a dashboard still has to bring a second signal — topic-coverage recall — into the picture, and then work out in what order to act. |
| **Business Objective** | Produce one combined, pre-ranked list that is "High Priority Review" only when a category is weak on **both** signals at once, ordered so the worst cases are already at the top. |
| **Business Question** | Which categories have both below-average prediction confidence **and** below-average topic-coverage recall at the same time, and in what priority order should a reviewer work through them? |
| **SQL Technique** | `topic_gold` restricts gold labels to non-category-name hashtags; `topic_coverage` computes, per category, how many of those gold (video, hashtag) pairs the model actually predicted, via an `EXISTS` correlated subquery; `coverage` turns that into a recall ratio; `confidence` aggregates prediction confidence per category; `combined` attaches the dataset-wide average of **each** signal to every row using `AVG(...) OVER ()` — no separate scalar-subquery pass needed, unlike question 3. A final `RANK() OVER (...)` orders every category by priority tier first, then by how weak its signals are. |

**SQL Query**

```sql
SELECT review_rank, category_name, avg_confidence, coverage_recall, review_priority
FROM vw_category_review_priority
ORDER BY review_rank;
```

**Query Result** (full 20-category ranking; **6 of 20** flagged `High Priority Review`)

| review_rank | category_name | avg_confidence | coverage_recall | review_priority |
|---:|---|---:|---:|---|
| 1 | education | 0.7095 | 0.1227 | High Priority Review |
| 2 | scitech | 0.7118 | 0.1339 | High Priority Review |
| 3 | ads | 0.7387 | 0.1327 | High Priority Review |
| 4 | news | 0.7391 | 0.0925 | High Priority Review |
| 5 | tvshow | 0.7433 | 0.1121 | High Priority Review |
| 6 | travel | 0.7441 | 0.1452 | High Priority Review |
| 7 | cooking | 0.7069 | 0.2264 | Normal |
| 8 | food | 0.7169 | 0.1823 | Normal |
| 9 | documentary | 0.7305 | 0.1619 | Normal |
| 10 | movies | 0.7659 | 0.1137 | Normal |
| 11 | people | 0.7674 | 0.1991 | Normal |
| 12 | family | 0.7740 | 0.1885 | Normal |
| 13 | howto | 0.7809 | 0.1807 | Normal |
| 14 | beauty | 0.7814 | 0.1599 | Normal |
| 15 | animation | 0.7941 | 0.1788 | Normal |
| 16 | music | 0.7962 | 0.1772 | Normal |
| 17 | animals | 0.7964 | 0.1432 | Normal |
| 18 | sports | 0.8116 | 0.2005 | Normal |
| 19 | gaming | 0.8271 | 0.1698 | Normal |
| 20 | autos | 0.8455 | 0.1864 | Normal |

Full results: [`sql/results/vw_category_review_priority.csv`](results/vw_category_review_priority.csv).

**Business Insight**

Flagging on either signal alone would give a different, noisier list — e.g.
`cooking` has the single lowest average confidence of all 20 categories
(question 4) but ranks 7th here, just below the cutoff, because its
topic-coverage recall (0.2264) is comfortably above the dataset average;
its low confidence does not come with a matching coverage problem. The
`coverage_recall` figures here are computed per (video, hashtag) pair via
`EXISTS`, which is stricter than aggregating counts at the category+hashtag
level — it is why every recall value in this view is noticeably lower than
a category-level approximation would suggest, and why the combined flag
is a defensible "both signals agree, and agree at the individual-pair
level" list rather than either diagnostic alone.

**Recommendation**

Route the 6 `High Priority Review` categories — `education`, `scitech`,
`ads`, `news`, `tvshow`, `travel` — to mandatory human review before
publishing auto-generated hashtags, in the order given by `review_rank`;
the remaining 14, including `cooking` which is weak on confidence alone,
can stay on a lighter spot-check policy. This view is meant to sit
directly on the Power BI risk-map chart as the pre-computed, pre-ranked
"where to look first" answer, rather than leaving that judgment to
whoever is reading the chart.

------------------------------------------------------------------------

## Reading SQL results correctly

Each section above follows the same **Query → Insight → Recommendation**
chain, and the distinction matters:

- **Query result** is a fact about this dataset — it cannot be wrong if
  the SQL is correct, but it also does not by itself say what to do.
- **Business insight** is an interpretation of that fact — it can be
  debated, and a different analyst might weigh the same numbers
  differently.
- **Recommendation** is a proposed action — it carries the most
  uncertainty, because it assumes the insight is right and that no other
  constraint (budget, team size, model-retraining cost) overrides it.

Every number in this document was run against the live
`video_hashtag_phase2` database, not estimated or invented.
