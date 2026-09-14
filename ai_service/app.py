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
and /telegram/webhook/<secret> must include a matching "X-API-Key" header.

Trade proposals are approved two ways: the desktop MT5 chart's Yes/No
buttons (free, always there when you're at the computer), or a Telegram
bot with real push notifications carrying tappable Approve/Deny buttons
(set TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, TELEGRAM_WEBHOOK_SECRET - see
AI_SETUP.md) for everywhere else. Whichever answers first wins, the other
clears automatically. This process holds the single current pending
proposal in memory, so it must run as exactly one worker process (see
the Dockerfile's gunicorn -w 1) - multiple workers would each have their
own copy and disagree.
"""
import os
import glob
import json
import time
import uuid
import threading

import pandas as pd
import requests
from flask import Flask, request, jsonify
import joblib

from features import compute_indicator_frame, FEATURE_COLUMNS

MODELS_DIR = "models"
LEGACY_MODEL_PATH = "model.pkl"  # older single-model deployments
CONFIDENCE_THRESHOLD = 0.60  # below this on both sides, respond "none"
API_KEY = os.environ.get("API_KEY", "")
PROPOSAL_MAX_AGE_SECONDS = 600  # stale-proposal safety net if the EA never clears one

TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "")
TELEGRAM_WEBHOOK_SECRET = os.environ.get("TELEGRAM_WEBHOOK_SECRET", "")
TELEGRAM_ENABLED = bool(TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID)

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
    if request.path.startswith("/telegram/webhook/"):
        return None  # protected by the secret path segment instead - Telegram can't send our API key
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


def _telegram_api(method: str, **params):
    if not TELEGRAM_ENABLED:
        return None
    try:
        resp = requests.post(
            f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/{method}",
            json=params, timeout=10,
        )
        return resp.json()
    except Exception as e:
        print(f"WARNING: Telegram API call '{method}' failed: {e}")
        return None


def send_telegram_proposal(proposal: dict):
    if not TELEGRAM_ENABLED:
        return
    warn = ("\n⚠️ Risk is higher than usual for this trade - check it before approving."
            if proposal.get("risk_pct", 0) > 1 else "")
    text = (
        f"{proposal['symbol']}  {proposal['direction'].upper()}\n"
        f"Confidence: {round(proposal['confidence'] * 100)}%\n"
        f"Lots: {proposal['lots']}  |  Risk: ${proposal['risk_money']} ({proposal['risk_pct']}%)\n"
        f"Entry ~ {proposal['entry_approx']}"
        f"{warn}"
    )
    keyboard = {
        "inline_keyboard": [[
            {"text": "✅ YES", "callback_data": f"yes:{proposal['id']}"},
            {"text": "❌ NO", "callback_data": f"no:{proposal['id']}"},
        ]]
    }
    result = _telegram_api("sendMessage", chat_id=TELEGRAM_CHAT_ID, text=text, reply_markup=keyboard)
    if result and result.get("ok"):
        proposal["telegram_message_id"] = result["result"]["message_id"]


def _finalize_telegram_message(proposal: dict, decision: str, decided_by: str):
    message_id = proposal.get("telegram_message_id")
    if not TELEGRAM_ENABLED or not message_id:
        return
    label = "✅ APPROVED" if decision == "yes" else "❌ DECLINED"
    text = f"{proposal['symbol']}  {proposal['direction'].upper()}\n\n{label} (via {decided_by})"
    _telegram_api("editMessageText", chat_id=TELEGRAM_CHAT_ID, message_id=message_id, text=text)


def _apply_decision(proposal_id: str, decision: str, decided_by: str) -> bool:
    """Shared by the HTTP /proposal/decide route and the Telegram webhook.
    Returns True if this call actually recorded the decision."""
    with _proposal_lock:
        _expire_if_stale()
        if _pending_proposal is None or _pending_proposal["id"] != proposal_id:
            return False
        if _pending_proposal["decision"] is not None:
            return False
        _pending_proposal["decision"] = decision
        _pending_proposal["decided_by"] = decided_by
        proposal_copy = dict(_pending_proposal)
    _finalize_telegram_message(proposal_copy, decision, decided_by)
    return True


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
            "telegram_message_id": None,
        }
        proposal_snapshot = dict(_pending_proposal)

    send_telegram_proposal(proposal_snapshot)
    with _proposal_lock:
        if _pending_proposal is not None and _pending_proposal["id"] == proposal_id:
            _pending_proposal["telegram_message_id"] = proposal_snapshot.get("telegram_message_id")

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

    _apply_decision(proposal_id, decision, decided_by)  # no-op if already decided/expired, that's fine
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


@app.route("/telegram/webhook/<secret>", methods=["POST"])
def telegram_webhook(secret):
    if not TELEGRAM_WEBHOOK_SECRET or secret != TELEGRAM_WEBHOOK_SECRET:
        return jsonify({"error": "unauthorized"}), 401

    update = request.get_json(force=True, silent=True) or {}
    callback = update.get("callback_query")
    if not callback:
        return jsonify({"ok": True})  # ignore anything that isn't a button tap

    data = callback.get("data", "")
    callback_id = callback.get("id", "")
    decision, _, proposal_id = data.partition(":")

    if decision in ("yes", "no") and proposal_id:
        applied = _apply_decision(proposal_id, decision, "telegram")
        ack_text = "Got it!" if applied else "Already handled or expired."
    else:
        ack_text = "Unrecognized action."

    _telegram_api("answerCallbackQuery", callback_query_id=callback_id, text=ack_text)
    return jsonify({"ok": True})


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
