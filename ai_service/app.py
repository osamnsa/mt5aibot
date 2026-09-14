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

Some instruments validate well on one side (buy or sell) and poorly on
the other - that's a real, observed pattern for some symbols, not a
bug. To ship only the trustworthy side, add an optional sidecar
models/<SYMBOL>.json next to the model, e.g.:
  {"disabled_directions": ["sell"]}
Any direction listed there is suppressed (mapped to "none") even if the
model itself would have called it.

Run locally with:
  python app.py
In production (Render, or anywhere else) it's served via gunicorn - see
the Dockerfile.

If the API_KEY environment variable is set, every request except /health
must include a matching key - either an "X-API-Key" header (what the EA
sends) or a "?key=..." query parameter (what the phone approval page at
/panel uses, so it can be a plain bookmarked link).

/panel is a phone-friendly page for approving/denying the EA's trade
proposals remotely, alongside the existing desktop chart Yes/No buttons -
whichever answers first wins, the other side clears automatically. This
process holds the single current pending proposal in memory, so it must
run as exactly one worker process (see the Dockerfile's gunicorn -w 1) -
multiple workers would each have their own copy and disagree.
"""
import os
import glob
import json
import time
import uuid
import threading

import pandas as pd
from flask import Flask, request, jsonify, Response
import joblib

from features import compute_indicator_frame, FEATURE_COLUMNS

MODELS_DIR = "models"
LEGACY_MODEL_PATH = "model.pkl"  # older single-model deployments
CONFIDENCE_THRESHOLD = 0.60  # below this on both sides, respond "none"
API_KEY = os.environ.get("API_KEY", "")
PROPOSAL_MAX_AGE_SECONDS = 600  # stale-proposal safety net if the EA never clears one

app = Flask(__name__)

_proposal_lock = threading.Lock()
_pending_proposal = None  # dict, or None when nothing is awaiting a decision


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


def load_direction_configs():
    configs = {}
    for path in glob.glob(os.path.join(MODELS_DIR, "*.json")):
        symbol = os.path.splitext(os.path.basename(path))[0]
        try:
            with open(path) as f:
                cfg = json.load(f)
            disabled = set(cfg.get("disabled_directions", []))
            if disabled:
                configs[symbol] = disabled
                print(f"'{symbol}': disabled directions {sorted(disabled)} per {path}")
        except Exception as e:
            print(f"WARNING: failed to load {path}: {e}")
    return configs


MODELS = load_models()
DIRECTION_CONFIGS = load_direction_configs()


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
    if not API_KEY:
        return None
    supplied = request.headers.get("X-API-Key") or request.args.get("key")
    if supplied != API_KEY:
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

    disabled = DIRECTION_CONFIGS.get(symbol, set())
    if direction in disabled:
        return jsonify({"direction": "none", "confidence": 0.0,
                         "reason": f"{direction} suppressed for {symbol} "
                                   f"(validated unreliable for this side)"}), 200

    return jsonify({"direction": direction, "confidence": round(confidence, 4),
                     "model_used": used_key})


def _expire_if_stale():
    global _pending_proposal
    if _pending_proposal and (time.time() - _pending_proposal["created_at"]) > PROPOSAL_MAX_AGE_SECONDS:
        _pending_proposal = None


@app.route("/propose", methods=["POST"])
def propose():
    global _pending_proposal
    payload = request.get_json(force=True, silent=True) or {}
    required = ["symbol", "direction", "confidence", "lots", "risk_money", "risk_pct", "entry_approx"]
    if any(k not in payload for k in required):
        return jsonify({"error": f"missing one of {required}"}), 400

    with _proposal_lock:
        proposal_id = uuid.uuid4().hex
        _pending_proposal = {
            "id": proposal_id,
            "symbol": payload["symbol"],
            "direction": payload["direction"],
            "confidence": payload["confidence"],
            "lots": payload["lots"],
            "risk_money": payload["risk_money"],
            "risk_pct": payload["risk_pct"],
            "entry_approx": payload["entry_approx"],
            "created_at": time.time(),
            "decision": None,
            "decided_by": None,
        }
    return jsonify({"id": proposal_id})


@app.route("/proposal", methods=["GET"])
def get_proposal():
    with _proposal_lock:
        _expire_if_stale()
        if _pending_proposal is None:
            return jsonify({})
        return jsonify(_pending_proposal)


@app.route("/proposal/decide", methods=["POST"])
def decide_proposal():
    payload = request.get_json(force=True, silent=True) or {}
    proposal_id = payload.get("id", "")
    decision = payload.get("decision", "")
    decided_by = payload.get("decided_by", "unknown")

    if decision not in ("yes", "no"):
        return jsonify({"ok": False, "reason": "decision must be 'yes' or 'no'"}), 400

    with _proposal_lock:
        _expire_if_stale()
        if _pending_proposal is None or _pending_proposal["id"] != proposal_id:
            return jsonify({"ok": False, "reason": "no matching pending proposal (may have expired)"}), 200
        if _pending_proposal["decision"] is None:
            _pending_proposal["decision"] = decision
            _pending_proposal["decided_by"] = decided_by
    return jsonify({"ok": True})


@app.route("/proposal/clear", methods=["POST"])
def clear_proposal():
    global _pending_proposal
    payload = request.get_json(force=True, silent=True) or {}
    proposal_id = payload.get("id", "")
    with _proposal_lock:
        if _pending_proposal is not None and (not proposal_id or _pending_proposal["id"] == proposal_id):
            _pending_proposal = None
    return jsonify({"ok": True})


PANEL_HTML = """<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AiSignalBot</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background:#0d0d0d; color:#eee;
         margin:0; padding:20px; }
  .status { text-align:center; color:#888; margin-top:80px; font-size:16px; }
  .card { background:#1a1a1a; border-radius:14px; padding:24px; margin-top:16px; }
  .symbol { font-size:20px; font-weight:600; }
  .dir { font-size:44px; font-weight:800; margin:8px 0; }
  .buy { color:#3ddc84; } .sell { color:#ff5c5c; }
  .detail { color:#aaa; font-size:14px; margin:4px 0; }
  .warn { color:#ffa500; font-size:13px; margin-top:10px; }
  .buttons { display:flex; gap:12px; margin-top:24px; }
  button { flex:1; padding:20px; font-size:20px; font-weight:700; border:none; border-radius:12px; color:#fff; }
  .yes { background:#1e7e34; } .no { background:#a52834; }
  button:active { opacity:0.6; }
</style>
</head>
<body>
<div id="app"><div class="status">Loading...</div></div>
<script>
const params = new URLSearchParams(window.location.search);
const key = params.get('key') || '';

async function poll() {
  try {
    const res = await fetch('/proposal?key=' + encodeURIComponent(key));
    if (res.status === 401) {
      document.getElementById('app').innerHTML = '<div class="status">Wrong or missing key in the URL.</div>';
      return;
    }
    render(await res.json());
  } catch (e) {
    document.getElementById('app').innerHTML = '<div class="status">Connection error, retrying...</div>';
  }
}

function render(data) {
  const app = document.getElementById('app');
  if (!data.id || data.decision) {
    app.innerHTML = '<div class="status">Waiting for a signal...</div>';
    return;
  }
  const dirClass = data.direction === 'buy' ? 'buy' : 'sell';
  const warn = (data.risk_pct && data.risk_pct > 1)
    ? '<div class="warn">Risk is higher than usual for this trade - check it before approving.</div>'
    : '';
  app.innerHTML =
    '<div class="card">' +
      '<div class="symbol">' + data.symbol + '</div>' +
      '<div class="dir ' + dirClass + '">' + data.direction.toUpperCase() + '</div>' +
      '<div class="detail">Confidence: ' + Math.round(data.confidence * 100) + '%</div>' +
      '<div class="detail">Lots: ' + data.lots + ' | Risk: $' + data.risk_money + ' (' + data.risk_pct + '%)</div>' +
      '<div class="detail">Entry ~ ' + data.entry_approx + '</div>' +
      warn +
      '<div class="buttons">' +
        '<button class="yes" onclick="decide(\\'' + data.id + '\\',\\'yes\\')">YES</button>' +
        '<button class="no" onclick="decide(\\'' + data.id + '\\',\\'no\\')">NO</button>' +
      '</div>' +
    '</div>';
}

async function decide(id, decision) {
  document.getElementById('app').innerHTML = '<div class="status">Sending...</div>';
  try {
    await fetch('/proposal/decide?key=' + encodeURIComponent(key), {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify({id: id, decision: decision, decided_by: 'phone'})
    });
  } catch (e) {}
  setTimeout(poll, 500);
}

poll();
setInterval(poll, 3000);
</script>
</body>
</html>
"""


@app.route("/panel", methods=["GET"])
def panel():
    return Response(PANEL_HTML, mimetype="text/html")


@app.route("/health", methods=["GET"])
def health():
    return jsonify({
        "status": "ok",
        "models_loaded": sorted(MODELS.keys()),
        "direction_restrictions": {k: sorted(v) for k, v in DIRECTION_CONFIGS.items()},
    })


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8787))
    app.run(host="0.0.0.0", port=port)
