"""
Train the AI signal model from a history CSV exported out of MT5.

How to export the CSV from MT5:
  Tools -> History Center (or the "..." menu on a chart) -> pick your
  symbol and timeframe -> Export -> save as CSV.

Usage - name the output to match the exact symbol name shown in MT5's
Market Watch (case-sensitive - this is how app.py picks the right model
per symbol, so a mismatch here means it silently won't be used):
  python train_model.py XAUUSD_M15.csv --out models/XAUUSD.pkl
  python train_model.py EURUSD_M15.csv --out models/EURUSD.pkl

Read the printed validation report before trusting this model with real
money: if the "actual up-rate" / "actual down-rate" among confident
signals isn't clearly above 50%, the model found no real edge in this
data and should not be used live.
"""
import argparse
import sys

import numpy as np
import pandas as pd
import joblib
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.metrics import classification_report

from features import compute_indicator_frame, FEATURE_COLUMNS


def load_mt5_csv(path: str) -> pd.DataFrame:
    try:
        df = pd.read_csv(path, sep="\t")
        if df.shape[1] < 5:
            raise ValueError("not tab-separated")
    except Exception:
        df = pd.read_csv(path)

    df.columns = [c.strip("<>").strip().lower() for c in df.columns]

    epoch = pd.Timestamp("1970-01-01")

    if "date" in df.columns and "time" in df.columns:
        dt = pd.to_datetime(df["date"].astype(str) + " " + df["time"].astype(str),
                             errors="coerce")
        # Don't assume datetime64[ns]: pandas can infer us/ms/s resolution
        # depending on version, and .astype("int64") // 10**9 silently gives
        # the wrong answer (e.g. 1000x too small) if it guessed microseconds.
        # Dividing by an actual Timedelta is resolution-independent.
        df["time"] = ((dt - epoch) // pd.Timedelta(seconds=1)).astype("int64")
    elif "time" in df.columns:
        dt = pd.to_datetime(df["time"], errors="coerce")
        df["time"] = ((dt - epoch) // pd.Timedelta(seconds=1)).astype("int64")
    else:
        df["time"] = np.arange(len(df))

    for col in ["open", "high", "low", "close"]:
        if col not in df.columns:
            raise ValueError(
                f"Column '{col}' not found in {path}. Columns present: {list(df.columns)}"
            )

    return df[["time", "open", "high", "low", "close"]].reset_index(drop=True)


def build_dataset(df: pd.DataFrame, horizon: int, move_threshold_atr: float) -> pd.DataFrame:
    feats = compute_indicator_frame(df)
    atr = feats["atr_14"]
    future_close = df["close"].shift(-horizon)
    future_move_atr = (future_close - df["close"]) / atr.replace(0, np.nan)

    label = pd.Series(np.nan, index=df.index)
    label[future_move_atr > move_threshold_atr] = 1
    label[future_move_atr < -move_threshold_atr] = 0

    data = feats[FEATURE_COLUMNS].copy()
    data["label"] = label
    return data.dropna()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("csv", help="Path to MT5-exported history CSV")
    ap.add_argument("--horizon", type=int, default=5,
                     help="Bars ahead the model predicts direction for")
    ap.add_argument("--move-threshold-atr", type=float, default=0.5,
                     help="Minimum move (in ATR units) to count as up/down; smaller moves are dropped as noise")
    ap.add_argument("--out", default="model.pkl")
    args = ap.parse_args()

    df = load_mt5_csv(args.csv)
    print(f"Loaded {len(df)} bars from {args.csv}")
    if len(df) < 1000:
        print("WARNING: fewer than 1000 bars. A model trained on this little data is not reliable "
              "- export more history (months, ideally a year+) before trusting this.")

    data = build_dataset(df, args.horizon, args.move_threshold_atr)
    print(f"{len(data)} usable labeled rows after feature/label computation "
          f"(rows with an ambiguous small move are dropped, not an error)")
    if len(data) < 300:
        print("ERROR: too few labeled rows to train anything meaningful. Export more history "
              "or lower --move-threshold-atr.")
        sys.exit(1)

    split = int(len(data) * 0.8)
    train, test = data.iloc[:split], data.iloc[split:]
    if train["label"].nunique() < 2 or test["label"].nunique() < 2:
        print("ERROR: training or test split doesn't contain both classes (up and down). "
              "Try a larger dataset or lower --move-threshold-atr.")
        sys.exit(1)

    X_train, y_train = train[FEATURE_COLUMNS], train["label"]
    X_test, y_test = test[FEATURE_COLUMNS], test["label"]

    model = GradientBoostingClassifier(random_state=42)
    model.fit(X_train, y_train)

    preds = model.predict(X_test)
    print("\n=== Validation performance (held-out, most recent 20% of data) ===")
    print(classification_report(y_test, preds, target_names=["down", "up"]))

    proba_up = model.predict_proba(X_test)[:, 1]
    confident_up = proba_up > 0.6
    confident_down = proba_up < 0.4

    up_rate = y_test[confident_up].mean() if confident_up.sum() else float("nan")
    down_rate = (1 - y_test[confident_down]).mean() if confident_down.sum() else float("nan")

    print(f"Confident BUY signals in test set: {int(confident_up.sum())}, "
          f"actual up-rate among them: {up_rate:.1%}" if confident_up.sum() else
          "Confident BUY signals in test set: 0")
    print(f"Confident SELL signals in test set: {int(confident_down.sum())}, "
          f"actual down-rate among them: {down_rate:.1%}" if confident_down.sum() else
          "Confident SELL signals in test set: 0")
    print("\nIf those rates aren't clearly and consistently above 50%, this model has no "
          "demonstrated edge on this data - do not point real money at it as-is.")

    joblib.dump(model, args.out)
    print(f"\nSaved model to {args.out}")


if __name__ == "__main__":
    main()
