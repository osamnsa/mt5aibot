# TrendSignalBot — ask-before-it-trades MT5 bot

## What this actually is

This is a file (`TrendSignalBot.mq5`) that installs **into your MetaTrader 5 terminal**
and runs there — not inside this chat. MT5 bots (called "Expert Advisors") have to run
on the same machine as your live-connected terminal, so that's where this lives. Once
installed, it works exactly like you asked: it watches the market, and when it finds a
trade it likes, it shows a small box on your chart with the symbol and one word — **BUY**
or **SELL** — plus YES/NO buttons. Nothing is sent to your broker unless you click YES.

## Install (5 minutes)

1. Open MetaTrader 5, go to **File → Open Data Folder**.
2. Open the `MQL5\Experts` folder and copy `TrendSignalBot.mq5` into it.
3. Back in MT5, right-click **Expert Advisors** in the Navigator panel → **Refresh**.
   (Or open MetaEditor with F4, open the file, and press **F7** to compile — it should
   say "0 errors".)
4. Open a chart for any symbol (it doesn't matter which — the bot scans your whole
   Market Watch list, not just the chart it's attached to).
5. Drag **TrendSignalBot** from the Navigator onto the chart.
6. In the dialog that pops up, go to the **Common** tab and make sure "Allow live
   trading" is checked.
7. Make sure the **Algo Trading** button in the MT5 toolbar is turned on (green).
8. In the **Inputs** tab, set `InpConfirmLiveRiskUnderstood` to **true**. This is a
   safety switch — until it's true, the bot will show you proposals but will never
   place a real order. See "Before you flip that switch" below.
9. Click OK. You should see a status message in the top-left of the chart saying
   "Scanning... ".

That's the whole install. It keeps running as long as MT5 is open and Algo Trading is on.

## Getting alerts on your Android phone

The bot itself can only run on a computer (that's a MetaTrader platform limit, not something
this file can work around) — but it will **push a notification straight to your phone** the
moment it finds a trade, so you don't have to sit at the computer:

1. On your phone, install the official **MetaTrader 5** app (Google Play) and log into the
   same account.
2. In the app: **Settings → Messages → scan the QR code**, or note the **MetaQuotes ID**
   shown there.
3. On the computer, in MT5: **Tools → Options → Notifications** tab. Check "Enable
   Push Notifications" and paste that MetaQuotes ID in. Click "Test" — you should get a
   test push on your phone within seconds.
4. That's it. From now on, every proposal, every filled order, and every daily-loss halt
   gets pushed to your phone automatically (this is already built into the bot — nothing
   else to set up).

**Important limit to understand:** the YES/NO buttons only exist on the desktop chart —
the phone notification is one-way. If you're away from the computer and want to act on a
notification, you'd place that trade yourself in the MT5 Android app's normal order screen,
using the lot size shown in the notification. The bot only auto-executes when you click
YES on the computer itself. For it to keep scanning and pushing alerts 24/7 without your
computer needing to stay on, you'd move it to a small always-on Windows VPS (~$3-5/month,
several MT5 brokers offer one) — say the word if you want help setting that up later.

## How it decides what to show you

Every 30 seconds (configurable) it checks the symbols in your Market Watch for a simple
trend/momentum signal on the 15-minute chart (also configurable):

- A **BUY** is proposed when the fast EMA (12) crosses above the slow EMA (26) and RSI
  confirms upward momentum.
- A **SELL** is proposed the same way, mirrored.

It only ever holds one proposal open at a time, and if you don't answer within 2 minutes
it auto-cancels so it doesn't pile up.

## About your $15 account and risk

You asked for 0.1% risk per trade. On a $15 account that's **$0.015** — far below what
any broker's minimum trade size actually risks. The bot handles this honestly instead of
pretending: it computes the ideal size, then rounds up to your broker's minimum lot, and
**tells you the real risk %** on the proposal box (and flags it in orange if it's well
above your 0.1% target). Some symbols may show risk of 20%, 50%, even more of your
account on a single trade, because that's what the broker's minimum trade size actually
means at this balance. You decide with YES/NO — read the number before you click.

**Practical suggestion:** with $15, most brokers' standard-lot minimums will make almost
every trade oversized relative to your balance. Ask your broker whether your account is
a cent/micro account (minimum lots there are far smaller), or add funds, before relying
on this for real risk control.

## Before you flip `InpConfirmLiveRiskUnderstood` to true

- This places **real orders with real money** the moment you click YES.
- $15 is a very small account; a couple of losing trades at broker-minimum lot size
  could wipe a large share of it. That's not a flaw in the bot — it's the math of small
  accounts, which the risk % on each proposal will show you honestly.
- Consider running it for a day with the switch left `false` first, just to see what it
  would have proposed, before letting it place real orders.
- This is not financial advice, and moving-average/RSI crossovers are a basic strategy
  with no guarantee of profit.

## Other settings you can change (Inputs tab)

| Input | Default | What it does |
|---|---|---|
| `InpSymbols` | (empty) | Comma-separated list to restrict scanning, e.g. `EURUSD,XAUUSD`. Empty = scan everything in Market Watch. |
| `InpTimeframe` | M15 | Chart timeframe the signal is calculated on. |
| `InpFastEMA` / `InpSlowEMA` | 12 / 26 | Crossover periods. |
| `InpRSIBuyLevel` / `InpRSISellLevel` | 55 / 45 | Momentum confirmation filter. |
| `InpSLATRMult` / `InpTPATRMult` | 1.5 / 3.0 | Stop-loss / take-profit distance as a multiple of ATR (volatility). |
| `InpRiskPercent` | 0.1 | Target risk per trade as % of balance. |
| `InpDailyLossLimitPercent` | 3.0 | Stops proposing new trades for the rest of the day once equity is down this % from the day's start. Existing open trades keep their SL/TP. |
| `InpMaxOpenTrades` | 1 | Won't propose a new trade while this many are already open. |
| `InpScanIntervalSeconds` | 30 | How often it checks for a fresh signal. |
| `InpProposalTimeoutSeconds` | 120 | Auto-dismiss an unanswered proposal after this long. |

## If something looks wrong

Open the **Experts** tab (bottom of MT5) — the bot logs every decision there: why it
skipped a symbol, what it calculated for lot size, and the result of every order it
sends. That log is the source of truth if a trade result on the proposal box doesn't
match what actually happened.
