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

from features import FEATURE_COLUMNS, wald_ci
from train_model import load_mt5_csv, build_dataset


def _deoverlap(idx_list, min_gap):
    kept, last = [], -10 ** 9
    for i in idx_list:
        if i - last >= min_gap:
            kept.append(i)
            last = i
    return kept


def evaluate(model, df_slice: pd.DataFrame, horizon: int, move_threshold_atr: float):
    data = build_dataset(df_slice, horizon, move_threshold_atr)
    if data.empty:
        return None
    proba_up = model.predict_proba(data[FEATURE_COLUMNS])[:, 1]
    data = data.reset_index(drop=True)

    buy_idx = data.index[proba_up > 0.6].tolist()
    sell_idx = data.index[proba_up < 0.4].tolist()
    buy_idx_do = _deoverlap(buy_idx, horizon)
    sell_idx_do = _deoverlap(sell_idx, horizon)

    def stats(idx_list, is_buy):
        n = len(idx_list)
        if n == 0:
            return n, float("nan"), (float("nan"), float("nan"))
        labels = data.loc[idx_list, "label"]
        hits = int(labels.sum()) if is_buy else int((1 - labels).sum())
        return n, hits / n, wald_ci(hits, n)

    buy_n, buy_rate, buy_ci = stats(buy_idx, True)
    sell_n, sell_rate, sell_ci = stats(sell_idx, False)
    buy_n2, buy_rate2, buy_ci2 = stats(buy_idx_do, True)
    sell_n2, sell_rate2, sell_ci2 = stats(sell_idx_do, False)

    return {
        "buy_n": buy_n, "buy_rate": buy_rate, "buy_ci": buy_ci,
        "buy_n_do": buy_n2, "buy_rate_do": buy_rate2, "buy_ci_do": buy_ci2,
        "sell_n": sell_n, "sell_rate": sell_rate, "sell_ci": sell_ci,
        "sell_n_do": sell_n2, "sell_rate_do": sell_rate2, "sell_ci_do": sell_ci2,
    }


def _fmt_line(side, n, rate, ci):
    if n == 0:
        return f"  {side.upper():5s} n=0"
    significant = "yes" if ci[0] > 0.5 else "no"
    return (f"  {side.upper():5s} n={n:4d}  rate={rate * 100:5.1f}%  "
            f"95% CI=[{ci[0] * 100:.1f}%, {ci[1] * 100:.1f}%]  significant={significant}")


def print_result(label: str, result):
    print(f"\n=== {label}, scored on the shared holdout ===")
    if result is None:
        print("No usable holdout rows.")
        return
    for side in ["buy", "sell"]:
        print("  (raw, overlapping)")
        print(_fmt_line(side, result[f"{side}_n"], result[f"{side}_rate"], result[f"{side}_ci"]))
        print("  (de-overlapped - the one to trust)")
        print(_fmt_line(side, result[f"{side}_n_do"], result[f"{side}_rate_do"], result[f"{side}_ci_do"]))


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
