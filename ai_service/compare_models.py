"""
Head-to-head comparison of a short-history model against a long-history
model, scored on the SAME held-out period neither one trained on.

Each model's own internal validation report (from train_model.py) grades
itself on a split of its own training data - useful, but not the same
as asking "which model predicts a period neither has ever seen?" This
script answers that question directly, and reports a 95% confidence
interval per side so "significant" means what it should: the interval
excludes 50%, not just "the rate looks good."

Usage:
  python compare_models.py FULL_HISTORY.csv --holdout-months 3 --short-window-months 12

Chronological layout:
  [------------- long-window training -------------][ holdout ]
                          [ short-window training  ][ holdout ]

- LONG model trains on everything before the holdout.
- SHORT model trains on only the most recent --short-window-months of
  that same pre-holdout period.
- Both are scored on the identical holdout slice.
"""
import argparse

import pandas as pd
from sklearn.ensemble import GradientBoostingClassifier

from features import FEATURE_COLUMNS
from train_model import load_mt5_csv, build_dataset


def wald_ci(successes: int, n: int, z: float = 1.96):
    if n == 0:
        return (float("nan"), float("nan"))
    p = successes / n
    se = (p * (1 - p) / n) ** 0.5
    return (max(0.0, p - z * se), min(1.0, p + z * se))


def evaluate(model, df_slice: pd.DataFrame, horizon: int, move_threshold_atr: float):
    data = build_dataset(df_slice, horizon, move_threshold_atr)
    if data.empty:
        return None
    proba_up = model.predict_proba(data[FEATURE_COLUMNS])[:, 1]
    y = data["label"]

    confident_up = proba_up > 0.6
    confident_down = proba_up < 0.4
    up_n, down_n = int(confident_up.sum()), int(confident_down.sum())
    up_hits = int(y[confident_up].sum())
    down_hits = int((1 - y[confident_down]).sum())

    return {
        "buy_n": up_n, "buy_rate": (up_hits / up_n) if up_n else float("nan"),
        "buy_ci": wald_ci(up_hits, up_n),
        "sell_n": down_n, "sell_rate": (down_hits / down_n) if down_n else float("nan"),
        "sell_ci": wald_ci(down_hits, down_n),
    }


def print_result(label: str, result):
    print(f"\n=== {label}, scored on the shared holdout ===")
    if result is None:
        print("No usable holdout rows.")
        return
    for side in ["buy", "sell"]:
        n = result[f"{side}_n"]
        rate = result[f"{side}_rate"]
        lo, hi = result[f"{side}_ci"]
        significant = "yes" if (n > 0 and lo > 0.5) else "no"
        rate_str = f"{rate * 100:5.1f}%" if n else "  n/a"
        ci_str = f"[{lo * 100:.1f}%, {hi * 100:.1f}%]" if n else "n/a"
        print(f"  {side.upper():5s} n={n:4d}  rate={rate_str}  95% CI={ci_str}  significant={significant}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("csv", help="Full history CSV covering both windows plus the holdout")
    ap.add_argument("--holdout-months", type=float, default=3)
    ap.add_argument("--short-window-months", type=float, default=12)
    ap.add_argument("--horizon", type=int, default=5)
    ap.add_argument("--move-threshold-atr", type=float, default=0.5)
    args = ap.parse_args()

    df = load_mt5_csv(args.csv)
    df["dt"] = pd.to_datetime(df["time"], unit="s")

    last_time = df["dt"].max()
    holdout_start = last_time - pd.Timedelta(days=args.holdout_months * 30.44)
    short_start = holdout_start - pd.Timedelta(days=args.short_window_months * 30.44)

    holdout_df = df[df["dt"] >= holdout_start].reset_index(drop=True)
    long_df = df[df["dt"] < holdout_start].reset_index(drop=True)
    short_df = df[(df["dt"] >= short_start) & (df["dt"] < holdout_start)].reset_index(drop=True)

    print(f"Holdout (neither model trains on this): {holdout_start.date()} -> {last_time.date()} "
          f"({len(holdout_df)} bars)")
    print(f"LONG-window training:  {long_df['dt'].min().date()} -> {holdout_start.date()} "
          f"({len(long_df)} bars)")
    print(f"SHORT-window training: {short_df['dt'].min().date()} -> {holdout_start.date()} "
          f"({len(short_df)} bars)")

    for label, train_df in [("SHORT-WINDOW model", short_df), ("LONG-WINDOW model", long_df)]:
        data = build_dataset(train_df, args.horizon, args.move_threshold_atr)
        if len(data) < 200:
            print(f"\n{label}: only {len(data)} usable training rows - skipping, need more data")
            continue
        model = GradientBoostingClassifier(random_state=42)
        model.fit(data[FEATURE_COLUMNS], data["label"])
        result = evaluate(model, holdout_df, args.horizon, args.move_threshold_atr)
        print_result(label, result)


if __name__ == "__main__":
    main()
