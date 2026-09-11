"""
AI signal service - can run on your VPS alongside MT5, or be deployed
standalone on a platform like Render (recommended: it stays up without you
managing a Python process, and your VPS only needs to run MT5 itself).

The AiSignalBot.mq5 Expert Advisor calls this over HTTP with recent price
bars and gets back a direction + confidence, computed by a real trained
model (see train_model.py) - not hardcoded rules.

Models are per-symbol: put a trained file at models/<SYMBOL>.pkl, named
exactly like the symbol appears in MT5 (e.g. models/XAUUSD.pkl,
models/EURUSD.pkl, models/BTC.pkl). A request for a symbol with no
matching file gets direction=none rather than a wrong-instrument guess -
a gold-trained model has no business predicting a forex pair, and vice
versa, so this never silently falls back to a mismatched model.

Run locally with:
  python app.py
In production (Render, or anywhere else) it's served via gunicorn - see
the Dockerfile.

If the API_KEY environment variable is set, every request except /health
must include a matching "X-API-Key" header - required once this service
is reachable from the public internet, not just localhost.
"""
import os
import glob

import pandas as pd
from flask import Flask, request, jsonify
import joblib

from features import compute_indicator_frame, FEATURE_COLUMNS

MODELS_DIR = "models"
LEGACY_MODEL_PATH = "model.pkl"  # older single-model deployments
CONFIDENCE_THRESHOLD = 0.60  # below this on both sides, respond "none"
API_KEY = os.environ.get("API_KEY", "")

app = Flask(__name__)


def load_models():
    models = {}
    for path in glob.glob(os.path.join(MODELS_DIR, "*.pkl")):
        symbol = os.path.splitext(os.path.basename(path))[0]
        try:
            models[symbol] = joblib.load(path)
            print(f"Loaded model for symbol '{symbol}' from {path}")
        except Exception as e:
            print(f"WARNING: failed to load {path}: {e}")

    if os.path.exists(LEGACY_MODEL_PATH):
        try:
            models["__default__"] = joblib.load(LEGACY_MODEL_PATH)
            print(f"Loaded legacy default model from {LEGACY_MODEL_PATH} "
                  f"(used only for symbols with no models/<SYMBOL>.pkl match)")
        except Exception as e:
            print(f"WARNING: failed to load {LEGACY_MODEL_PATH}: {e}")

    if not models:
        print(f"WARNING: no models found in {MODELS_DIR}/ or {LEGACY_MODEL_PATH}. "
              f"Run train_model.py first. /predict will return direction=none until one exists.")
    return models


MODELS = load_models()


def model_for_symbol(symbol: str):
    if symbol in MODELS:
        return MODELS[symbol], symbol
    if "__default__" in MODELS:
        return MODELS["__default__"], "__default__ (legacy model.pkl)"
    return None, None


@app.before_request
def check_api_key():
    if request.path == "/health":
        return None
    if API_KEY and request.headers.get("X-API-Key") != API_KEY:
        return jsonify({"error": "unauthorized"}), 401
    return None


@app.route("/predict", methods=["POST"])
def predict():
    payload = request.get_json(force=True, silent=True) or {}
    symbol = payload.get("symbol", "")
    closes = payload.get("closes")
    highs = payload.get("highs")
    lows = payload.get("lows")
    times = payload.get("times")

    if not closes or not highs or not lows:
        return jsonify({"error": "missing closes/highs/lows"}), 400

    model, used_key = model_for_symbol(symbol)
    if model is None:
        return jsonify({"direction": "none", "confidence": 0.0,
                         "reason": f"no trained model for symbol '{symbol}' - "
                                   f"add models/{symbol}.pkl"}), 200

    n = len(closes)
    if n < 40:
        return jsonify({"direction": "none", "confidence": 0.0,
                         "reason": "not enough bars sent"}), 200

    df = pd.DataFrame({
        "time": times if times and len(times) == n else list(range(n)),
        "open": closes,
        "high": highs,
        "low": lows,
        "close": closes,
    })

    feats = compute_indicator_frame(df)
    last_row = feats[FEATURE_COLUMNS].iloc[[-1]]
    if last_row.isnull().values.any():
        return jsonify({"direction": "none", "confidence": 0.0,
                         "reason": "warmup period, send more history"}), 200

    proba_up = float(model.predict_proba(last_row)[0][1])

    if proba_up >= CONFIDENCE_THRESHOLD:
        direction, confidence = "buy", proba_up
    elif proba_up <= (1 - CONFIDENCE_THRESHOLD):
        direction, confidence = "sell", 1 - proba_up
    else:
        direction, confidence = "none", max(proba_up, 1 - proba_up)

    return jsonify({"direction": direction, "confidence": round(confidence, 4),
                     "model_used": used_key})


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "models_loaded": sorted(MODELS.keys())})


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8787))
    app.run(host="0.0.0.0", port=port)
