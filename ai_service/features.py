"""
Shared feature engineering for the AI signal service.

Both train_model.py (offline training) and app.py (live inference) import
this module, so the features the model is trained on are guaranteed to
match the features it sees live. Never duplicate this logic elsewhere.
"""
import numpy as np
import pandas as pd

FEATURE_COLUMNS = [
    "ret_1", "ret_3", "ret_5", "ret_10",
    "rsi_14",
    "ema_diff_atr",
    "atr_pct",
    "volatility_10",
    "hour",
    "dow",
]


def wald_ci(successes: int, n: int, z: float = 1.96):
    """95% confidence interval for a binomial rate, e.g. a confident-signal
    hit rate. Shared by train_model.py and compare_models.py so "is this
    edge statistically significant" always means the same thing."""
    if n == 0:
        return (float("nan"), float("nan"))
    p = successes / n
    se = (p * (1 - p) / n) ** 0.5
    return (max(0.0, p - z * se), min(1.0, p + z * se))


def compute_indicator_frame(df: pd.DataFrame) -> pd.DataFrame:
    """
    df must have columns: time (unix seconds), open, high, low, close,
    ordered oldest-first. Returns a DataFrame of engineered features
    aligned to df's index; the first ~26 rows will be NaN (warmup).
    """
    close = df["close"]
    high = df["high"]
    low = df["low"]

    out = pd.DataFrame(index=df.index)
    out["ret_1"] = close.pct_change(1)
    out["ret_3"] = close.pct_change(3)
    out["ret_5"] = close.pct_change(5)
    out["ret_10"] = close.pct_change(10)

    delta = close.diff()
    gain = delta.clip(lower=0)
    loss = -delta.clip(upper=0)
    avg_gain = gain.ewm(alpha=1 / 14, min_periods=14, adjust=False).mean()
    avg_loss = loss.ewm(alpha=1 / 14, min_periods=14, adjust=False).mean()
    rs = avg_gain / avg_loss.replace(0, np.nan)
    out["rsi_14"] = 100 - (100 / (1 + rs))

    ema_fast = close.ewm(span=12, adjust=False).mean()
    ema_slow = close.ewm(span=26, adjust=False).mean()

    prev_close = close.shift(1)
    tr = pd.concat([
        (high - low),
        (high - prev_close).abs(),
        (low - prev_close).abs(),
    ], axis=1).max(axis=1)
    atr_14 = tr.ewm(alpha=1 / 14, min_periods=14, adjust=False).mean()

    out["ema_diff_atr"] = (ema_fast - ema_slow) / atr_14.replace(0, np.nan)
    out["atr_pct"] = atr_14 / close
    out["volatility_10"] = close.pct_change().rolling(10).std()

    if "time" in df.columns:
        dt = pd.to_datetime(df["time"], unit="s", utc=True)
        out["hour"] = dt.dt.hour
        out["dow"] = dt.dt.dayofweek
    else:
        out["hour"] = 0
        out["dow"] = 0

    out["atr_14"] = atr_14  # kept for label building, not a model feature
    return out
