# PolyMan

PolyMan is a long-running Polymarket position manager daemon.

## What it does

- Polls open positions every `POLL_INTERVAL_S` seconds.
- Uses trailing-stop only for active positions with positive `current_value`.
- If a position is redeemable, it queues redeem action.
- If a position is loser/zero-value, it queues best-effort close-out (`sell -> redeem -> transfer/sweep`).
- Uses queue + worker model so one slow task does not block all positions.
- Tracks worker runtime, checks real progress, kills stalled workers, and retries safely.
- Prevents duplicate assignment for the same task while it is queued/in-flight.

## Configure in compose.yml

Important environment variables:

- `POLL_INTERVAL_S` default `2`
- `WORKER_COUNT` default `2`
- `WORKER_TIMEOUT_S` default `30`
- `WORKER_MAX_RETRIES` default `2`
- `RESULT_DIR` default `/tmp/polyman-results`
- `LOSER_SWEEP_TO` optional destination wallet for loser transfer fallback
- `SL_SET_TO`, `TS_TRIGGER_AT`, `TS_MOVE_EACH`
- `TP1_TRIGGER_PCT`, `TP1_CLOSE_PCT`, `TP2_TRIGGER_PCT`, `TP2_CLOSE_PCT`
- `MAX_LOSS_PCT`
- `CLOSE_ON_REDEEMABLE`

## Run tests

```bash
prove -Ilib -It/lib t/*.t
```

The test suite includes:
- unit tests for `TrailingStop`, `Positions`, and manager helpers
- queue/worker tests including duplicate-task prevention and worker lifecycle
- 100 trailing-stop scenario flow tests
- bulk tests with 500+ assertions across high-level functions
