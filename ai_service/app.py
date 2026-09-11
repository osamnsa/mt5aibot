"""
AI signal service - can run on your VPS alongside MT5, or be deployed
standalone on a platform like Koyeb (recommended: it stays up without you
managing a Python process, and your VPS only needs to run MT5 itself).

The AiSignalBot.mq5 Expert Advisor calls this over HTTP with recent price
bars and gets back a direction + confidence, computed by a real trained
model (see train_model.py) - not hardcoded rules.

Run locally with:
  python app.py
In production (Koyeb, or anywhere else) it's served via gunicorn - see
the Dockerfile.

If the API_KEY environment variable is set, every request except /health
must include a matching "X-API-Key" header - required once this service
is reachable from the public internet, not just localhost.
"""
import os

import pandas as pd
from flask import Flask, request, jsonify
import joblib

from features import compute_indicator_frame, FEATURE_COLUMNS

MODEL_PATH = "model.pkl"
CONFIDENCE_THRESHOLD = 0.60  # below this on both sides, respond "none"
API_KEY = os.environ.get("API_KEY", "")

app = Flask(__name__)

try:
    model = joblib.load(MODEL_PATH)
except FileNotFoundError:
    model = None
    print(f"WARNING: {MODEL_PATH} not found. Run train_model.py first. "
          f"/predict will return direction=none until a model exists.")


@app.before_request
def check_api_key():
    if request.path == "/health":
        return None
    if API_KEY and request.headers.get("X-API-Key") != API_KEY:
        return jsonify({"error": "unauthorized"}), 401
    return None


@app.route("/predict", methods=["POST"])
def predict():
    if model is None:
        return jsonify({"direction": "none", "confidence": 0.0,
                         "reason": "no model loaded - run train_model.py"}), 200

    payload = request.get_json(force=True, silent=True) or {}
    closes = payload.get("closes")
    highs = payload.get("highs")
    lows = payload.get("lows")
    times = payload.get("times")

    if not closes or not highs or not lows:
        return jsonify({"error": "missing closes/highs/lows"}), 400

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

    return jsonify({"direction": direction, "confidence": round(confidence, 4)})


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "model_loaded": model is not None})


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8787))
    app.run(host="0.0.0.0", port=port)
