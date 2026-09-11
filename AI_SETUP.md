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
   - **Koyeb (recommended)** — deployed from GitHub, stays running for you,
     nothing to babysit on your VPS.
   - **Directly on the VPS** — simpler to reason about, but you're
     responsible for keeping the Python process alive.

---

## Option A — Host the AI service on Koyeb (recommended)

### 1. Train the model locally first

The trained model file (`model.pkl`) needs to already exist and be
committed to the repo before Koyeb builds it — Koyeb doesn't train
anything, it just runs what you give it.

1. In MT5: **Tools → History Center** (or a chart's right-click menu),
   pick the symbol/timeframe you'll trade (match `InpTimeframe` in the
   EA), and **Export** to CSV. Get as much history as your broker offers —
   months at minimum, a year+ is better.
2. On your computer:
   ```
   cd ai_service
   pip install -r requirements.txt
   python train_model.py path/to/your_export.csv --out model.pkl
   ```
3. **Read the printed validation report before going further.** If the
   confident-signal up/down rates on held-out data aren't clearly above
   50%, the model found no real edge in this data — don't ship it. Try
   more history or a different symbol first.
4. Commit the model into the repo so Koyeb picks it up on deploy:
   ```
   git add ai_service/model.pkl
   git commit -m "Add trained model"
   git push
   ```

### 2. Deploy on Koyeb

1. Sign up at koyeb.com and connect your GitHub account.
2. Create a new App → select your GitHub repo.
3. Set the **working directory / build context** to `ai_service`
   (Koyeb supports deploying a subfolder of a repo — look for "Work
   directory" or similar in the service settings).
4. Builder: **Dockerfile** (one is already included in that folder).
5. Under environment variables, add `API_KEY` = some random string you
   make up (e.g. a long password) — this is what stops random strangers on
   the internet from hitting your endpoint once it's public.
6. Deploy. Koyeb gives you a URL like `https://your-app-name.koyeb.app`.
7. Confirm it's alive: open `https://your-app-name.koyeb.app/health` in a
   browser — should show `{"status": "ok", "model_loaded": true}`. If
   `model_loaded` is `false`, the model.pkl commit didn't make it into the
   build — check step 4.

**Free-tier note:** some Koyeb plans idle/sleep a service after a period
of no traffic, which can make the *first* request after a quiet spell slow
to respond. If the EA's proposals seem to lag right after a quiet period,
that's likely why — not a bug.

### 3. Point the EA at it

In the EA's Inputs tab:
- `InpAiServiceUrl` → `https://your-app-name.koyeb.app/predict`
- `InpAiApiKey` → the same random string you set as `API_KEY` on Koyeb

Then whitelist it in MT5: **Tools → Options → Expert Advisors** →
check "Allow WebRequest for listed URL" → add
`https://your-app-name.koyeb.app` → OK.

That's it — your VPS only needs to run MT5. The AI brain lives on Koyeb.

---

## Option B — Run the AI service directly on the VPS

Only do this if you'd rather not use Koyeb. Needs Python 3.10+ on the same
Windows VPS as MT5.

1. Copy the `ai_service/` folder onto the VPS (e.g. `C:\ai_service\`).
2. `cd C:\ai_service` then `pip install -r requirements.txt`.
3. Train the model the same way as Option A step 1 (steps 1-3), saving
   `model.pkl` directly into `C:\ai_service\`.
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
on Koyeb.

## Everything else is unchanged

Risk sizing (`InpRiskPercent`), the daily loss kill-switch
(`InpDailyLossLimitPercent`), the YES/NO panel, and phone push notifications
all work exactly like `TrendSignalBot.mq5` — see the main `README.md` for
those. The only difference is where the BUY/SELL/none decision comes from.
