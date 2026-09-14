# AiSignalBot — real ML-powered version, setup guide

## What changed from TrendSignalBot

`TrendSignalBot.mq5` decides trades with fixed rules (EMA crossover + RSI).
`AiSignalBot.mq5` instead sends recent price bars to a small Python service
which runs those bars through a **trained machine-learning model** and
returns a direction + confidence. Everything else — the YES/NO panel, risk
sizing, daily loss limit, push notifications — works exactly the same as
before.

Be clear-eyed about what "AI-powered" means here: it's a statistical model
(gradient boosting) trained on past price patterns, not a crystal ball. The
training script prints an honest validation report specifically so you can
see whether it found any real edge before you trust it with money — read
that report, don't skip it.

## The two pieces, and where each one runs

1. **MT5 + `AiSignalBot.mq5`** — must run on a Windows machine (your VPS or
   PC) with the MT5 terminal logged into your account. No way around this,
   same platform limit as before.
2. **The AI service** (`ai_service/`) — this is just an HTTP API. It does
   **not** need to be on the same machine as MT5. Two ways to run it:
   - **Render (or a similar container platform)** — deployed from GitHub,
     stays running for you, nothing to babysit on your VPS.
   - **Directly on the VPS** — simpler to reason about, but you're
     responsible for keeping the Python process alive.

---

## Option A — Host the AI service on a free container platform (recommended)

Koyeb was the first choice here, but it's currently **not accepting new
signups**. The good news: this Dockerfile-based setup works identically on
several platforms, so nothing about the bot or the code changes — just
which dashboard you click through. Use **Render** below (open for
signups as of this writing); if Koyeb reopens later, its steps are the
same as Render's, just on koyeb.com instead.

### 1. Train one model per symbol

Models are per-symbol, in `ai_service/models/<SYMBOL>.pkl` — **the filename
must exactly match the symbol's name in MT5's Market Watch** (case-sensitive:
e.g. `models/BTC.pkl`, `models/XAUUSD.pkl`, `models/EURUSD.pkl`). A gold
model has no business predicting a forex pair's direction, so the service
never falls back to a mismatched one - a symbol with no matching file just
gets skipped (no trade proposed) until you train one for it.

1. In MT5: press **F2** (or Market Watch → right-click **Symbols**), pick
   the symbol/timeframe you'll trade (match `InpTimeframe` in the EA), and
   **Export** to CSV. Get as much history as your broker offers — months
   at minimum, a year+ is better. Repeat per symbol you want the bot
   trading (e.g. once for BTC, once for each metal, once for each forex
   pair).
2. On your computer, once per symbol:
   ```
   cd ai_service
   pip install -r requirements.txt
   python train_model.py path/to/XAUUSD_export.csv --out models/XAUUSD.pkl
   ```
3. **Read the printed validation report before going further, every time.**
   If the confident-signal up/down rates on held-out data aren't clearly
   above 50%, that particular symbol's model found no real edge — don't
   ship it for that instrument. Each symbol is a separate judgment call;
   a good result on one doesn't mean the others will be.
4. Commit the models into the repo so the deploy picks them up:
   ```
   git add ai_service/models/
   git commit -m "Add trained models"
   git push
   ```

### 2. Deploy on Render

1. Sign up at render.com and connect your GitHub account.
2. **New +** → **Web Service** → select the `mt5aibot` repo.
3. Set **Root Directory** to `ai_service`.
4. **Runtime**: Docker (Render auto-detects the `Dockerfile` already in
   that folder).
5. Under **Environment Variables**, add `API_KEY` = some random string you
   make up (e.g. a long password) — this is what stops random strangers on
   the internet from hitting your endpoint once it's public.
6. Under **Health Check Path**, set `/health` (so Render knows the service
   is up correctly).
7. Deploy. Render gives you a URL like `https://your-app-name.onrender.com`.
8. Confirm it's alive: open `https://your-app-name.onrender.com/health` in
   a browser — should show `{"status": "ok", "models_loaded": ["BTC", ...]}`
   listing every symbol you trained. If a symbol you expect is missing,
   its `models/<SYMBOL>.pkl` commit didn't make it into the build — check
   step 4.

**Free-tier note:** Render's free web services spin down after ~15 minutes
of no traffic and take 30-60 seconds to wake up on the next request. If the
EA's first proposal after a quiet spell seems slow, that's why — not a bug.
If that delay ever causes a missed signal window, an upgrade to Render's
smallest paid tier removes the sleep behavior.

### 3. Point the EA at it

In the EA's Inputs tab:
- `InpAiServiceUrl` → `https://your-app-name.onrender.com/predict`
- `InpAiApiKey` → the same random string you set as `API_KEY` on Render

Then whitelist it in MT5: **Tools → Options → Expert Advisors** →
check "Allow WebRequest for listed URL" → add
`https://your-app-name.onrender.com` → OK.

That's it — your VPS only needs to run MT5. The AI brain lives on Render.

---

## Option B — Run the AI service directly on the VPS

Only do this if you'd rather not use Render. Needs Python 3.10+ on the same
Windows VPS as MT5.

1. Copy the `ai_service/` folder onto the VPS (e.g. `C:\ai_service\`).
2. `cd C:\ai_service` then `pip install -r requirements.txt`.
3. Train each symbol's model the same way as Option A step 1, saving into
   `C:\ai_service\models\<SYMBOL>.pkl`.
4. Run it: `python app.py` (leave the window open, or use `pythonw app.py`
   to run it without a visible console, or set it up as a scheduled task
   that starts at login).
5. Confirm: open `http://127.0.0.1:8787/health` in a browser on the VPS.
6. In MT5: **Tools → Options → Expert Advisors** → Allow WebRequest for
   listed URL → add `http://127.0.0.1:8787`.
7. Leave the EA's `InpAiServiceUrl` at its default
   (`http://127.0.0.1:8787/predict`) and `InpAiApiKey` blank — no key
   needed since nothing outside the VPS can reach localhost.

---

## Installing the EA itself (either option)

Same as `TrendSignalBot.mq5` before it: compile `AiSignalBot.mq5` in
MetaEditor, attach it to a chart, Common tab → Allow live trading, Inputs
tab → set `InpConfirmLiveRiskUnderstood` to `true` when you're ready to go
live, make sure Algo Trading is on in the toolbar.

The chart's status overlay shows the AI URL it's using, confirming it's
wired up. If the Journal/Experts log shows repeated "WebRequest blocked" or
"WebRequest ... failed" messages, re-check the whitelist step for whichever
option you chose, and double check `InpAiApiKey` matches exactly if you're
on Render (or whichever platform you used).

## Which symbols the EA actually scans

Set the EA's `InpSymbols` input to a comma-separated list matching exactly
the symbols you've trained models for (e.g. `BTC,XAUUSD,EURUSD`). A symbol
in that list with no trained model just gets skipped silently (checkable
via `/health`'s `models_loaded` list) — it won't crash anything, but it
also won't ever propose a trade until you train and deploy one for it.

## Trailing stop

Once a bot-opened position moves favorably by `InpTrailingStartATR` worth
of ATR (default 1.0), the stop-loss starts trailing behind price at
`InpTrailingDistanceATR` (default 1.5 ATR), tightening only — it never
loosens the stop back, and never touches the take-profit. Set
`InpTrailingEnabled` to `false` to turn this off and go back to a fixed
SL/TP with no adjustment. This runs every scan regardless of the daily
loss halt or a pending proposal, since protecting an already-open position
is separate from opening new risk.

## Approving trades from your phone (the /panel page)

Push notifications are text-only — MT5 has no way to put a clickable
Yes/No button inside a phone notification, that's a platform limit, not
something this project can work around. Instead, the AI service itself
hosts a small mobile-friendly page that shows the current proposal and
lets you tap YES/NO from your phone, no MT5 mobile app involved.

**The link to bookmark on your phone:**
```
https://your-app-name.onrender.com/panel?key=YOUR_API_KEY
```
(same `API_KEY` value you set on Render / put in `InpAiApiKey`). Bookmark
it once — it works immediately every time after that, no login prompt.

How it behaves:
- When the EA proposes a trade, it registers it with the AI service *and*
  shows the usual desktop chart panel — both at once.
- Open the bookmarked page and it shows the same symbol/direction/risk
  details, with big YES/NO buttons.
- **Whichever you answer first wins** — tap it on your phone, and the
  desktop panel clears on its own within one scan interval (up to
  `InpScanIntervalSeconds`, 30s by default). Click the desktop panel
  instead, and the phone page clears itself the same way.
- If a proposal is not needed on the desktop side and `InpConfirmLiveRiskUnderstood`
  is `true`, tapping YES on the phone places the trade exactly the same
  way clicking YES on the chart would.
- Set `InpRemoteApprovalEnabled` to `false` to turn this off entirely and
  go back to desktop-only approval.

No new setup beyond what you already have — the phone panel is served by
the same Render deployment you're already running.

## Everything else is unchanged

Risk sizing (`InpRiskPercent`), the daily loss kill-switch
(`InpDailyLossLimitPercent`), the YES/NO panel, and phone push notifications
all work exactly like `TrendSignalBot.mq5` — see the main `README.md` for
those. The only difference is where the BUY/SELL/none decision comes from.
