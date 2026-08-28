# GX Portfolio Intelligence

Hướng dẫn cài đặt, rollout và vận hành đầy đủ: [docs/RUNBOOK.vi.md](docs/RUNBOOK.vi.md).

Phoenix/Oban orchestrator for the V1 end-of-day research pipeline: freeze the 500 most liquid Vietnamese equities, run one isolated TradingAgents process per ticker, and index sanitized daily digests in SimpleRAG.

The optional full-analysis extension scores trend at every universe slot, selects
a bounded set from the immutable official top 500, resumes seven durable
TradingAgents stages per ticker, and promotes the existing daily RAG document
in place. It is disabled by default and never changes the daily digest SLA.

The `daily_digest_v1` profile remains informational and excludes BUY/SELL/HOLD,
target prices, sizing and portfolio decisions. The optional `full_report_v1`
profile may contain recommendations, sizing, targets and a portfolio decision;
those are research output only. GX PI exposes no order-placement, execution or
automatic rebalancing API.

## Architecture

1. Oban schedules point-in-time universe and evidence collection jobs in `Asia/Ho_Chi_Minh`.
2. `TradingAgents` is called through `Port.open({:spawn_executable, ...})`; no shell is used and every path must stay under `GX_PI_ARTIFACT_ROOT`.
3. A final non-empty 15:15 snapshot creates the daily research batch. A holiday/no-session response is a no-op and creates no batch.
4. Research queue concurrency is four by default. Python's durable claim file owns at-most-once LLM semantics; an Elixir retry calls `run-one` again and Python recovers without a second LLM call.
5. Digests are submitted to SimpleRAG in groups of at most 50. Submission is not counted as ready: the worker polls RAG status, counts only `ready`, retries failed open-batch items, then seals after every actual frozen member is ready.

An ad-hoc path is also available for researching 1–50 explicitly requested
tickers immediately. It freezes its own request-time cutoff and remains isolated
from the immutable top-500 EOD batch, including its RAG source and SLA status.

Run exactly **one application replica in V1**. Oban queue concurrency is per node; adding replicas would multiply the provider/LLM concurrency limit.

## Local setup

Requirements: Elixir/Erlang, PostgreSQL, an absolute TradingAgents Python executable, and SimpleRAG.

```sh
docker compose up -d postgres
export GX_PI_DB_PORT=5434
export GX_PI_DB_NAME=gx_portfolio_intelligence
mix setup
mix phx.server
```

The PostgreSQL container publishes port `5434` on the host; the two exported
variables deliberately override Phoenix's host-development defaults. Do not
source or copy the production `.env.example` for this host-development flow.
Configure the host TradingAgents executable, artifact root, RAG URL and tokens
through your normal local secret/config mechanism.

The compose application profile is optional. Its image builds a Linux
TradingAgents virtual environment with the `gx-postgres`, `fireant`, `vn-media`
and `vn-macro` extras; it never mounts a host/macOS `.venv`. Before starting the
profile, create a deployment `.env` from the example using a secret manager,
preload the SimpleRAG embedding model as documented in
`../SimpleRAGChatBot/README.md`, and make sure the configured Ollama model is
available. Then run:

```sh
docker compose --profile service up -d --build
```

The container entrypoint runs all pending Ecto/Oban migrations before starting
the single service replica. For a non-container release, run
`bin/gx_portfolio_intelligence eval "GxPortfolioIntelligence.Release.migrate()"`
before `start`.

Cron is deliberately disabled by default. Keep `GX_PI_CRON_ENABLED=false` through manual 5-, 50-, and 500-ticker verification, then enable it on the single worker replica.

The child Python process inherits the orchestrator environment. Configure the
read-only GX PostgreSQL DSN, Quick LLM profile, collector authorization and
encryption keys in the deployment secret manager. Keep the social, media and
macro archive paths under the persistent `GX_PI_ARTIFACT_ROOT`; the example
environment already does this.

## API

All `/api/v1` routes require `Authorization: Bearer $GX_PI_API_TOKEN`.

- `POST /api/v1/research-batches` with optional `{"analysis_date":"2026-08-21","limit":5}` schedules the final universe job. `limit` is intended for the 5/50/500 rollout and defaults to 500. The DB batch is created only after TradingAgents confirms a non-trading-day-safe, non-empty snapshot.
- `POST /api/v1/ad-hoc-research-batches` accepts `{"tickers":["HPG","FPT"]}` and an optional `analysis_date`. It requires an `Idempotency-Key` header and accepts 1–50 unique tickers. An omitted/current date runs live at request time; a past date runs one canonical `historical_replay` batch at 15:00 Asia/Ho_Chi_Minh.
- The ad-hoc request also accepts `"analysis_depth":"digest"|"full"` (default
  `digest`). `full` runs all requested tickers after their daily digest is
  durable. The field participates in idempotency; reusing a key with another
  depth returns `409 idempotency_conflict`. For a historical canonical batch, a
  new key with the same ticker set may upgrade `digest` to `full`; the upgrade
  is monotonic and a later digest request never downgrades it.
- `GET /api/v1/research-batches?analysis_date=2026-08-21` discovers the eventual batch created by the asynchronous POST.
- `GET /api/v1/research-batches?batch_type=adhoc` lists only ad-hoc batches.
- `GET /api/v1/research-batches/:id`
- `GET /api/v1/research-batches/:id/items?limit=50&offset=0&ticker=HPG&status=failed`
- `POST /api/v1/research-batches/:id/retry`
- `GET /api/v1/research-batches/:id/full-analysis`
- `GET /api/v1/research-batches/:id/full-analysis/items`
- `GET /api/v1/research-batches/:id/full-analysis/items/:ticker/report`
- `GET /api/v1/research-batches/:id/full-analysis/items/:ticker/stages`
- `POST /api/v1/research-batches/:id/full-analysis/retry`
- `GET /api/v1/trend-snapshots?analysis_date=2026-08-21`
- `GET /api/v1/universe-snapshots?analysis_date=2026-08-21`
- `GET /health/live` and `GET /health/ready` are unauthenticated.

The report endpoint returns the canonical `full_report_v1` envelope plus a typed
portfolio/trading decision. GX validates exact keys, identity, hashes, the
256-KiB report/64-KiB decision limits and the mutually exclusive price-target
contract before returning it. It returns `404` for a missing item, `409` until
promotion/indexing is ready, and `503` for an unavailable or invalid RAG
payload. The public API never returns command stderr, unvalidated RAG response
bodies, credentials, raw evidence, or absolute artifact paths.

Ad-hoc research uses only evidence already archived and point-in-time eligible at
the request cutoff (`archive_as_of_request_cutoff`). Its liquidity rank is scoped
to the requested selection, not the EOD top-500 universe. EOD SLA evaluation
does not apply to these batches (`sla_status=not_applicable`). See the
[Vietnamese runbook](docs/RUNBOOK.vi.md#8-chạy-ngay-các-mã-tùy-chọn-bằng-api-ad-hoc)
for deployment, invocation, polling and error semantics.

## Schedule

Configured schedule (weekdays, Asia/Ho_Chi_Minh):

- Candidate universe + FireAnt/media: 09:15, 10:15, 11:15, 13:15, 14:15.
- Optional trend snapshots run after each candidate universe. The final trend
  calculation runs after the official freeze but uses data cutoff 15:00.
- Freeze top 500: 15:15.
- Final social/media: 15:20; macro/media: 15:30.
- Fan-out research: 15:45.
- SLA checks: 07:30 and 08:00 next weekday; SLA is met at 490 RAG-ready, while batch completion requires 500.
- Dependency and artifact disk check: every 15 minutes.

Delayed retries retain the original slot timestamp; a 09:15 retry never reads a 15:45 point-in-time cutoff.

## Data and security

- PostgreSQL stores immutable universe ranks, workflow state, sanitized digest sections, opaque hashes, and alert deduplication state.
- Trading digest identity is `(source, ticker, analysis_date, cutoff)`. EOD uses
  `tradingagents_daily_research`; ad-hoc uses the isolated
  `tradingagents_adhoc_research` source. Historical replay keeps that production
  source but is explicitly tagged `research_mode=historical` and
  `data_provenance=historical_replay` in SQLite/Chroma and citations.
- Only the exact nine claim sections and `{text, confidence, evidence_ids}` are accepted. Unknown/raw fields are discarded by rejection, not persisted.
- Raw encrypted FireAnt/RSS archives remain owned by TradingAgents and are retained indefinitely. Chroma/SQLite receive only sanitized digest claims and metadata.
- Webhook payloads use an allowlist and contain no raw evidence or credentials. Disk use at or above `GX_PI_DISK_ALERT_PERCENT` produces `dependency_unhealthy`.

## Verification and rollout

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Before enabling cron: back up SimpleRAG, migrate both databases, run the
TradingAgents collector initial backfill as a separate manual operation, verify
the four CLI JSON contracts, run 5/50/500 manual batches, confirm RAG
pending-to-ready polling, and verify webhook/SLA dashboards. Database and
artifact retention are intentionally unbounded in V1; operational disk alerts
are therefore mandatory.

Full analysis requires the forward GX migration and a compatible SimpleRAG
promotion endpoint before enabling either feature flag. Start with
`GX_PI_TREND_ENABLED=true` and keep `GX_PI_FULL_ANALYSIS_ENABLED=false`; inspect
trend snapshots, then enable automatic EOD full analysis with the default limit
of five. See the runbook for the exact rollout and rollback-safe controls.
