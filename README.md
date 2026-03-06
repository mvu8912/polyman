# PolyMan

PolyMan is a **long-running Polymarket position management daemon** designed for traders who want disciplined, automated handling of open positions.

Instead of manually watching every market and deciding when to act, PolyMan continuously evaluates your positions and executes predefined risk-management actions through a queue/worker engine.

---

## Why this project exists

Managing Polymarket positions manually is hard to do consistently, especially if you have many simultaneous positions.

### Without PolyMan

Typical workflow:
- You monitor markets manually.
- You decide when to cut losses, trail stops, redeem, and clean up dust/losing positions.
- You risk delayed reactions during volatility.
- You repeat operational tasks (sell/redeem/transfer) across many positions.

Common pain points:
- Missed exits because you were offline/asleep.
- Emotional decision-making replacing systematic rules.
- Operational overhead from repetitive cleanup tasks.
- Inconsistent execution quality across positions.

### With PolyMan

PolyMan provides:
- A **continuous polling loop** for open positions.
- Rule-based position lifecycle management.
- Worker isolation so one slow action does not block all other positions.
- Retry and stall detection for safer long-running automation.
- Automatic handling paths for redeemable and losing positions.

In short: PolyMan turns position management from ad hoc manual work into a repeatable operational process.

---

## Who should use PolyMan

PolyMan is a good fit for:
- Active Polymarket traders with multiple concurrent positions.
- Users who want automation around stop behavior and cleanup flows.
- Operators who value reliability features (timeouts, retries, queue safety).
- People running a dedicated bot/service environment (local server/VPS/container).

PolyMan is probably **not** ideal for:
- Casual users with very infrequent trading.
- Traders who prefer 100% discretionary/manual execution for every action.
- Users who do not want to manage environment variables and daemon operations.

---

## Problems PolyMan is trying to solve

1. **Reaction-time risk**  
   Markets move quickly; manual monitoring can miss windows.

2. **Operational fatigue**  
   Repeated sell/redeem/cleanup actions are tedious and error-prone.

3. **Execution consistency**  
   Rules are applied consistently across all managed positions.

4. **Concurrency bottlenecks**  
   Slow single actions should not freeze management of other positions.

5. **Long-running reliability**  
   Workers are monitored for progress, can be timed out, and retried safely.

---

## Key features

- **Continuous position polling** every `POLL_INTERVAL_S` seconds.
- **Trailing-stop logic** for active positions with positive `current_value`.
- **Redeem queueing** for positions that are redeemable.
- **Loser/zero-value handling** with best-effort close-out (`sell -> redeem -> transfer/sweep`).
- **Queue + worker architecture** to decouple task scheduling and execution.
- **Worker stall protection** with runtime tracking and timeout checks.
- **Retry controls** via configurable retry limits.
- **Duplicate-task prevention** to avoid conflicting work on the same position/task.

---

## How PolyMan works (high-level)

1. Poll open positions.
2. Determine which management action applies (trail, redeem, close-out, etc.).
3. Enqueue tasks.
4. Workers process tasks concurrently.
5. Manager tracks worker health/progress, handles timeout/retry behavior.
6. Loop repeats continuously.

---

## Setup

> You can run PolyMan with Docker (recommended for reproducibility) or directly on your machine.

### Option A: Run with Docker

1. Ensure Docker + Docker Compose are installed.
2. Create or edit your `compose.yml` (or equivalent) with environment variables.
3. Start the service:

```bash
docker compose up -d
```

4. View logs:

```bash
docker compose logs -f
```

5. Stop service:

```bash
docker compose down
```

### Option B: Run without Docker

1. Install Perl and project dependencies used by this repository.
2. Set required environment variables in your shell.
3. Start the PolyMan daemon/entrypoint using your local runtime command.

> Tip: if you run locally on a VPS, use a process manager (for example `systemd`, `supervisord`, or `tmux`/`screen`) so PolyMan survives disconnects and restarts cleanly.

---

## Configuration

Important environment variables (commonly configured in `compose.yml`):

- `POLL_INTERVAL_S` (default `2`): polling interval in seconds
- `WORKER_COUNT` (default `2`): concurrent worker count
- `WORKER_TIMEOUT_S` (default `30`): per-worker timeout threshold
- `WORKER_MAX_RETRIES` (default `2`): max retries for failed/stalled tasks
- `RESULT_DIR` (default `/tmp/polyman-results`): output/results directory
- `LOSER_SWEEP_TO` (optional): destination wallet for loser transfer fallback
- `SL_SET_TO`, `TS_TRIGGER_AT`, `TS_MOVE_EACH`: stop/trailing parameters
- `TP1_TRIGGER_PCT`, `TP1_CLOSE_PCT`, `TP2_TRIGGER_PCT`, `TP2_CLOSE_PCT`: take-profit controls
- `MAX_LOSS_PCT`: hard loss cap behavior
- `CLOSE_ON_REDEEMABLE`: auto-close behavior for redeemable states

---

## Scenarios PolyMan handles well

1. **You hold many active positions and need systematic trailing-stop updates.**  
   PolyMan keeps applying your configured rules continuously.

2. **Some markets resolve while others are still active.**  
   Redeemable positions are queued for redemption while active ones continue being managed.

3. **You have losing/near-zero positions to clean up.**  
   PolyMan can run the best-effort close-out flow automatically.

4. **One operation hangs or is slow.**  
   Queue/worker separation and timeout/retry logic reduce total-system blockage.

---

## Scenarios PolyMan does *not* handle (or is not meant for)

- **Alpha generation / strategy discovery.**  
  PolyMan manages execution and lifecycle, not signal generation.

- **Guaranteeing profitability.**  
  It enforces configured rules; it cannot remove market risk.

- **Eliminating exchange/network/chain failure modes.**  
  Retries help, but external failures can still impact outcomes.

- **Fully hands-off operation without configuration oversight.**  
  You must choose and maintain sane risk parameters.

---

## Expectations and operating model

When using PolyMan, expect:
- **Automation of defined behaviors**, not human-like discretionary trading.
- **Deterministic rule execution** based on your environment configuration.
- **Need for parameter tuning** as market conditions and strategy preferences change.
- **Need for monitoring** (logs, task outcomes, retries, unresolved edge cases).

Practical guidance:
- Start with conservative settings.
- Run in a small-size or paper-like environment first (if available in your workflow).
- Review logs frequently after any config changes.
- Treat PolyMan as risk-ops infrastructure, not a profit guarantee engine.

---

## Testing

Run test suite:

```bash
prove -Ilib -It/lib t/*.t
```

Coverage includes:
- Unit tests for `TrailingStop`, `Positions`, and manager helpers
- Queue/worker tests including duplicate-task prevention and worker lifecycle
- 100 trailing-stop scenario flow tests
- Bulk tests with 500+ assertions across high-level functions
