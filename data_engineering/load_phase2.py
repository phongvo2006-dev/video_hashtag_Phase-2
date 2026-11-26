"""Phase 2 data engineering — extract Phase 1 outputs into flat, warehouse-ready CSVs.

This script replaces the KNIME ETL step that was in an earlier draft of this
pipeline. Phase 1 already produces clean, correct data (captions, weak
labels, model predictions); this script's only job is to flatten it into a
normalized, relational shape that PostgreSQL (and SQL in general) can join
on, and that Power BI can import directly.

Reads, from a Phase 1 checkout (``--phase1-dir``, default: ``../video-hashtag-llm``):
  - dataset/MSRVTT_data.json           (not used directly — videos.jsonl is the processed form)
  - data/processed/videos.jsonl        (1 row per video: id, split, category, 20 captions, eval
                                         caption, gold weak-label tags)
  - data/processed/meta.json           (367-hashtag vocabulary, 20 category names, in a fixed
                                         order shared by every model's prediction columns)
  - results/preds/roberta_rl_val.npy   (497 x 367 probability matrix for the val split)
  - results/preds/roberta_rl_test.npy  (2990 x 367 probability matrix for the test split)

Writes, under ``--out`` (default: ``data_engineering/exports``):
  - videos.csv        one row per video
  - captions.csv      one row per caption (20 per video)
  - gold_labels.csv   one row per (video, gold hashtag) pair
  - predictions.csv   one row per (eval caption, predicted hashtag) pair, RoBERTa+RL only,
                       confidence >= PREDICTION_THRESHOLD (Phase 1's own best-F1 operating
                       point for this model, per results/metrics.json's val_threshold_sweep)

Only the deployed model (RoBERTa+RL) is exported — Phase 2 does not need, and does not
load, the other four Phase-1 comparison models (keyword, TF-IDF, Transformer-from-scratch,
RoBERTa-BCE). That comparison already lives in Phase 1's own evaluation report.
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np

# RoBERTa+RL's own best Set-F1 operating point on the validation threshold sweep
# (results/metrics.json -> val_threshold_sweep -> roberta_rl -> SetF1 peaks at threshold 0.40).
PREDICTION_THRESHOLD = 0.40


def load_phase1(phase1_dir: Path):
    videos = [json.loads(line) for line in (phase1_dir / "data/processed/videos.jsonl").read_text().splitlines()]
    meta = json.loads((phase1_dir / "data/processed/meta.json").read_text())
    return videos, meta


def write_videos_csv(videos: list[dict], category_tags: list[str], out_dir: Path) -> None:
    path = out_dir / "videos.csv"
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["video_id", "split", "category_id", "category_name"])
        for v in videos:
            w.writerow([v["video_id"], v["split"], v["category"], category_tags[v["category"]]])
    print(f"wrote {path} ({len(videos)} rows)")


def write_captions_csv(videos: list[dict], out_dir: Path) -> dict[tuple[str, bool], int]:
    """Returns a lookup of (video_id, is_eval_caption) -> caption_id for the eval captions,
    used by write_predictions_csv to attach predictions to the right caption row."""
    path = out_dir / "captions.csv"
    eval_caption_id: dict[str, int] = {}
    caption_id = 0
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["caption_id", "video_id", "caption_index", "caption_text",
                    "is_eval_caption", "token_count", "char_count"])
        for v in videos:
            for idx, cap in enumerate(v["captions"]):
                is_eval = cap == v["eval_caption"] and v["video_id"] not in eval_caption_id
                w.writerow([caption_id, v["video_id"], idx, cap, is_eval,
                            len(cap.split()), len(cap)])
                if is_eval:
                    eval_caption_id[v["video_id"]] = caption_id
                caption_id += 1
    print(f"wrote {path} ({caption_id} rows)")
    return eval_caption_id


def write_gold_labels_csv(videos: list[dict], out_dir: Path) -> None:
    path = out_dir / "gold_labels.csv"
    n = 0
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["video_id", "hashtag_text"])
        for v in videos:
            for tag in v["tags"]:
                w.writerow([v["video_id"], tag])
                n += 1
    print(f"wrote {path} ({n} rows)")


def write_predictions_csv(
    videos: list[dict], vocab: list[str], eval_caption_id: dict[str, int],
    phase1_dir: Path, out_dir: Path,
) -> None:
    path = out_dir / "predictions.csv"
    n = 0
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["caption_id", "video_id", "hashtag_text", "confidence", "rank_in_caption"])
        for split in ("val", "test"):
            probs = np.load(phase1_dir / f"results/preds/roberta_rl_{split}.npy")
            split_videos = [v for v in videos if v["split"] == split]
            assert len(split_videos) == probs.shape[0], (
                f"{split}: {len(split_videos)} videos but {probs.shape[0]} prediction rows"
            )
            for v, row in zip(split_videos, probs):
                above = [(vocab[i], float(p)) for i, p in enumerate(row) if p >= PREDICTION_THRESHOLD]
                above.sort(key=lambda t: t[1], reverse=True)
                for rank, (tag, conf) in enumerate(above, start=1):
                    w.writerow([eval_caption_id[v["video_id"]], v["video_id"], tag, round(conf, 6), rank])
                    n += 1
    print(f"wrote {path} ({n} rows, threshold={PREDICTION_THRESHOLD})")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--phase1-dir", default="../video-hashtag-llm", type=Path,
                     help="Path to a Phase 1 (video-hashtag-llm) checkout")
    ap.add_argument("--out", default=Path(__file__).parent / "exports", type=Path,
                     help="Output directory for the flat CSVs")
    args = ap.parse_args()

    phase1_dir = args.phase1_dir.resolve()
    out_dir = args.out.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Reading Phase 1 outputs from {phase1_dir}")
    videos, meta = load_phase1(phase1_dir)
    vocab, category_tags = meta["vocab"], meta["category_tags"]

    write_videos_csv(videos, category_tags, out_dir)
    eval_caption_id = write_captions_csv(videos, out_dir)
    write_gold_labels_csv(videos, out_dir)
    write_predictions_csv(videos, vocab, eval_caption_id, phase1_dir, out_dir)
    print(f"Done. Flat exports ready in {out_dir}")


if __name__ == "__main__":
    main()
