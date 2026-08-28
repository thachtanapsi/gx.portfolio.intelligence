# Runbook vận hành GX Portfolio Intelligence V1

Tài liệu này hướng dẫn chạy toàn bộ hệ thống gồm:

- `gx.portfolio.intelligence`: Phoenix API, PostgreSQL và Oban orchestration.
- `TradingAgents`: chọn universe, thu thập evidence và tạo daily digest.
- `SimpleRAGChatBot`: index digest và phục vụ retrieval/chat.
- Ollama: mô hình chat local cho SimpleRAG.

`daily_digest_v1` chỉ cung cấp thông tin, catalyst, rủi ro và nội dung cần theo
dõi; profile này không tạo BUY/SELL/HOLD, giá mục tiêu, sizing hoặc quyết định
danh mục. Tùy chọn `full_report_v1` có thể chứa khuyến nghị, sizing, mục tiêu và
quyết định danh mục nhưng chỉ là kết quả research. GX PI không có API đặt lệnh,
không thực thi giao dịch và không tự động tái cấu trúc danh mục.

## 1. Điều kiện trước khi chạy

Cần có:

- Docker Engine hoặc Docker Desktop có Docker Compose V2.
- Ollama chạy trên host.
- `curl`, `jq` và `openssl`.
- Kết nối tới GX PostgreSQL bằng tài khoản read-only.
- Quick LLM API key.
- FireAnt token hợp lệ và quyền sử dụng dữ liệu phù hợp.
- Hai khóa Fernet riêng cho social archive và media archive.

Hệ thống V1 phải chạy đúng **một replica `gx-pi`**. Không dùng
`docker compose --scale gx-pi=...` vì concurrency của Oban được giới hạn theo
từng node.

### Cảnh báo về secret cũ

Không sử dụng lại `TradingAgents/.env.postgres-hosted`. Hãy rotate/revoke các
credential từng lưu trong file đó trước khi triển khai. File không được Git theo
dõi, nhưng đã bị đọc trong quá trình audit.

Nếu archive cũ đã có dữ liệu, không thay khóa mã hóa trực tiếp. Cần re-encrypt,
dual-key migration hoặc giữ khóa cũ an toàn để đọc lịch sử trước khi retire.

## 2. Tạo cấu hình deployment

Chạy từ repo điều phối:

```bash
cd /Users/thachtan/Documents/source/APG/gx.portfolio.intelligence
cp .env.example .env
chmod 600 .env
```

Tạo các secret mới. Không commit kết quả:

```bash
openssl rand -hex 64
openssl rand -hex 32
```

Điền tối thiểu các biến sau vào `.env`:

```dotenv
MIX_ENV=prod
DATABASE_URL=ecto://postgres:postgres@postgres/gx_portfolio_intelligence
SECRET_KEY_BASE=<secret mới, ít nhất 64 bytes>
GX_PI_API_TOKEN=<API token mới>
PORT=4010
PHX_HOST=localhost

TRADING_AGENTS_ROOT=/opt/trading_agents
TRADING_AGENTS_PYTHON=/opt/trading_agents/.venv/bin/python
GX_PI_ARTIFACT_ROOT=/data/gx-pi/artifacts

GX_DATA_TRANSPORT=postgres
GX_MARKET_INFO_DATABASE_URL=<GX PostgreSQL read-only URL>
GX_MARKET_INFO_EXPECTED_DB=g_market_info

TRADINGAGENTS_QUICK_LLM_PROVIDER=<provider>
TRADINGAGENTS_QUICK_THINK_LLM=<quick model>
TRADINGAGENTS_QUICK_LLM_API_KEY=<quick model API key>

TRADINGAGENTS_FIREANT_AUTHORIZED=true
TRADINGAGENTS_FIREANT_HOSTED_LLM_AUTHORIZED=false
FIREANT_ACCESS_TOKEN=<FireAnt token>
FIREANT_ARCHIVE_ENCRYPTION_KEY=<Fernet key>
TRADINGAGENTS_VN_SOCIAL_TICKERS=HPG,VIC,VHM,SHB,VIX

TRADINGAGENTS_VN_MEDIA_PROVIDERS=cafef_rss,vnexpress_rss
TRADINGAGENTS_CAFEF_RSS_AUTHORIZED=<true khi đã được phê duyệt>
TRADINGAGENTS_CAFEF_HOSTED_LLM_AUTHORIZED=<true khi được phép gửi tới remote Quick LLM>
TRADINGAGENTS_VNEXPRESS_RSS_AUTHORIZED=<true khi đã được phê duyệt>
TRADINGAGENTS_VNEXPRESS_HOSTED_LLM_AUTHORIZED=<true khi được phép gửi tới remote Quick LLM>
TRADINGAGENTS_VN_MEDIA_TICKERS=HPG,VIC,VHM,SHB,VIX
VN_MEDIA_ARCHIVE_ENCRYPTION_KEY=<Fernet key khác>

RAG_SERVICE_URL=http://simple-rag:8000
RAG_SERVICE_API_KEY=<shared token mới>

GX_PI_CRON_ENABLED=false
GX_PI_WEBHOOK_URL=<optional webhook URL>
GX_PI_WEBHOOK_TOKEN=<optional webhook token>
```

Lưu ý:

- GX database user phải là read-only.
- URL GX phải truy cập được từ container, không chỉ từ host.
- Chỉ đặt `TRADINGAGENTS_FIREANT_AUTHORIZED=true` khi đã có quyền sử dụng.
- Watchlist trong env phục vụ status và bounded backfill; daily top 500 vẫn
  nhận ticker động từ immutable universe manifest.
- Chỉ bật `*_RSS_AUTHORIZED=true` cho nguồn RSS đã được phê duyệt. Các cờ
  `*_HOSTED_LLM_AUTHORIZED` là quyền riêng, chỉ bật nếu nội dung được phép gửi
  tới Quick LLM từ xa.
- `RAG_SERVICE_API_KEY` được dùng chung bởi Phoenix và SimpleRAG.
- Giữ `GX_PI_CRON_ENABLED=false` cho đến khi hoàn tất rollout 5/50/500.

## 3. Chuẩn bị Ollama

Cài model mặc định trên host:

```bash
ollama pull gemma4:e2b
curl --fail --silent http://127.0.0.1:11434/api/tags | jq
```

Nếu dùng model khác, cập nhật `RAG_CHAT_MODEL` trong `.env` và pull đúng model
đó trước khi khởi động.

Docker Compose mặc định kết nối Ollama qua:

```text
http://host.docker.internal:11434
```

Trên Linux, có thể phải cấu hình Ollama lắng nghe trên host gateway. Không
publish Ollama trực tiếp ra Internet.

## 4. Build SimpleRAG và preload BGE-M3

Build image:

```bash
docker compose --profile service build simple-rag
```

Tải embedding model vào persistent volume:

```bash
docker compose --profile service run --rm \
  -e HF_HUB_OFFLINE=0 \
  -e TRANSFORMERS_OFFLINE=0 \
  simple-rag python -c \
  'from sentence_transformers import SentenceTransformer; SentenceTransformer("BAAI/bge-m3"); print("BGE-M3 ready")'
```

Kiểm tra container truy cập được Ollama:

```bash
docker compose --profile service run --rm simple-rag \
  python -c \
  'import urllib.request; print(urllib.request.urlopen("http://host.docker.internal:11434/api/tags").status)'
```

Kết quả mong đợi là `200`.

### 4.1. Maintenance rollout cho canonical Full Report JSON

Migration này giữ nguyên `document_id` và `full_report_hash`, thêm canonical
envelope/typed decision vào SQLite và reindex riêng chunk
`decision.structured`. Không embed toàn bộ JSON và không đọc `session.json`, raw
evidence, prompt, tool call, credential hoặc absolute path.

Thực hiện trong maintenance window. Trước hết dừng cả hai writer, backup
PostgreSQL và toàn bộ volume `simple_rag_data` (SQLite + Chroma) theo mục 14:

```bash
docker compose --profile service stop gx-pi simple-rag
docker compose --profile service build simple-rag gx-pi
```

Chạy preflight không ghi dữ liệu, sau đó mới apply trên cùng volume:

```bash
docker compose --profile service run --rm --no-deps simple-rag \
  local-rag backfill-full-reports --dry-run | tee /tmp/full-report-dry-run.json

docker compose --profile service run --rm --no-deps simple-rag \
  local-rag backfill-full-reports --apply | tee /tmp/full-report-apply.json

jq -e '.failed == 0' /tmp/full-report-apply.json
```

Hai lệnh chỉ dựng dữ liệu từ `documents`, `digest_batches` và
`digest_sections`; không gọi LLM. Output luôn có
`scanned/stored/partial/requeued/failed`. `partial` là legacy report đọc được
nhưng thiếu field typed decision, không phải lỗi rollout. Dừng rollout và phục
hồi/xác minh backup nếu `failed != 0`.

Khi `failed=0`, chỉ start SimpleRAG và chờ toàn bộ reindex hoàn tất:

```bash
docker compose --profile service up -d --force-recreate simple-rag

until curl --fail --silent http://127.0.0.1:8000/api/health \
  | jq -e '.status == "ok" and .full_report_payloads_ready == true'; do
  sleep 5
done
```

Cuối cùng mới deploy/start GX PI và kiểm tra endpoint report có bearer token:

```bash
docker compose --profile service up -d --force-recreate gx-pi

curl --fail --silent \
  -H "Authorization: Bearer $GX_PI_API_TOKEN" \
  http://127.0.0.1:4010/api/v1/research-batches/10/full-analysis/items/FPT/report \
  | jq '.data.decision.portfolio.price_target'
```

Acceptance cho batch 10/FPT là `77000`; report vẫn có cùng `document_id` và
`full_report_hash`. Endpoint trả `409` khi item chưa promoted/ready và `503` nếu
RAG không sẵn sàng hoặc payload không qua kiểm tra integrity.

## 5. Khởi động toàn bộ hệ thống

```bash
docker compose --profile service up -d --build
docker compose ps
```

Release `gx-pi` tự chạy toàn bộ Ecto/Oban migrations trước khi start. Các volume
được giữ lại khi container được recreate:

- `gx_pi_postgres`: PostgreSQL orchestration.
- `gx_pi_artifacts`: universe, raw archive và daily artifacts.
- `simple_rag_data`: SQLite và Chroma.
- `simple_rag_models`: Hugging Face model cache.

Theo dõi startup:

```bash
docker compose logs -f postgres simple-rag gx-pi
```

## 6. Kiểm tra dependency và archive

### Health endpoints

```bash
curl --fail --silent http://127.0.0.1:8000/api/health | jq
curl --fail --silent http://127.0.0.1:4010/health/live | jq
curl --fail --silent http://127.0.0.1:4010/health/ready | jq
```

Kết quả mong đợi:

- SimpleRAG trả `"status": "ok"`.
- `/health/live` trả `"status": "ok"`.
- `/health/ready` trả HTTP 200, `"status": "ready"` và tất cả checks là
  `true`.

### Kiểm tra TradingAgents providers

```bash
docker compose --profile service exec gx-pi \
  /opt/trading_agents/.venv/bin/tradingagents-gx social status

docker compose --profile service exec gx-pi \
  /opt/trading_agents/.venv/bin/tradingagents-gx media status

docker compose --profile service exec gx-pi \
  /opt/trading_agents/.venv/bin/tradingagents-gx macro status
```

Không bật cron nếu provider hoặc archive status đang `FAIL`.

## 7. Initial collector backfill

Backfill là thao tác bounded, thực hiện riêng trước khi bật lịch. Bắt đầu với một
ticker được phép:

```bash
docker compose --profile service exec gx-pi \
  /opt/trading_agents/.venv/bin/tradingagents-gx social collect \
  --once --ticker HPG

docker compose --profile service exec gx-pi \
  /opt/trading_agents/.venv/bin/tradingagents-gx media collect \
  --once --ticker HPG

docker compose --profile service exec gx-pi \
  /opt/trading_agents/.venv/bin/tradingagents-gx macro collect --once
```

Mở rộng backfill theo từng nhóm ticker có kiểm soát. Không tự tạo vòng lặp đồng
thời không giới hạn; FireAnt đã có pacer 60 request/phút và tối đa bốn request
đồng thời.

## 8. Chạy ngay các mã tùy chọn bằng API ad-hoc

Endpoint ad-hoc dùng khi cần phân tích một danh sách mã **ngay tại thời điểm gọi
API**, không chờ các mốc 15:15/15:20/15:30/15:45. Request trả HTTP `202` sau khi
ghi batch và đưa universe job vào Oban; phần research và RAG tiếp tục chạy bất
đồng bộ.

### 8.1. Rebuild và migrate trước lần dùng đầu tiên

Thay đổi này có migration PostgreSQL mới cho canonical historical batch và
idempotency alias. Migration là **forward-only** vì lịch sử ad-hoc được giữ
vĩnh viễn; hãy backup PostgreSQL và volume SimpleRAG trước khi rollout.
SimpleRAG nâng SQLite tương thích ngược khi khởi động, giữ nguyên PDF/digest cũ
và không clear collection.

Dừng writer trước khi backup và preflight để không có batch mới xuất hiện giữa
lúc kiểm tra và rollout; lệnh này giữ nguyên toàn bộ volume:

```bash
docker compose --profile service stop gx-pi
```

Sau khi container dừng, thực hiện backup theo mục 14 rồi mới tiếp tục.

Với Docker Compose, image `gx-pi` đã đóng gói luôn phiên bản TradingAgents hiện
tại. Build cả hai image và nâng SimpleRAG trước để ứng dụng tự nâng schema
SQLite; chưa start image `gx-pi` mới ở bước này:

```bash
cd /Users/thachtan/Documents/source/APG/gx.portfolio.intelligence
docker compose --profile service build simple-rag gx-pi

docker compose --profile service up -d --force-recreate simple-rag
curl --fail --silent http://127.0.0.1:8000/api/health | jq
```

Khi SimpleRAG mới đã healthy và trước khi nâng `gx-pi`, kiểm tra **từng ngày
lịch sử dự kiến chạy** để chắc chắn chưa có batch mang cùng identity
`source + analysis_date + cutoff`. Lệnh dưới đây chỉ mở SQLite ở chế độ
read-only và coi `15:00 +07:00` tương đương `08:00Z`, nên phát hiện được cả hai
cách biểu diễn timestamp:

```bash
export GX_HISTORY_DATE='2026-08-24'

docker compose --profile service exec -T \
  -e GX_HISTORY_DATE="$GX_HISTORY_DATE" \
  simple-rag python -c \
  '
import os
import sqlite3

date = os.environ["GX_HISTORY_DATE"]
cutoff = f"{date}T15:00:00+07:00"
db = sqlite3.connect("file:/data/rag.sqlite3?mode=ro", uri=True)
rows = db.execute(
    "SELECT id, status, cutoff, research_mode, data_provenance "
    "FROM digest_batches "
    "WHERE source=? AND analysis_date=? AND datetime(cutoff)=datetime(?)",
    ("tradingagents_adhoc_research", date, cutoff),
).fetchall()
print(rows if rows else "OK: no collision")
raise SystemExit(1 if rows else 0)
'
```

Kết quả hợp lệ là `OK: no collision` và exit code `0`. Nếu lệnh in ra một hay
nhiều row rồi trả exit code `1`, dừng rollout cho ngày đó: batch hiện hữu đang
sở hữu logical identity trong RAG. Không xóa SQLite/Chroma để vượt qua kiểm tra;
hãy xác minh batch hiện hữu và chọn ngày hoặc namespace smoke-test khác.

Khi preflight sạch, nâng `gx-pi`; entrypoint sẽ chạy migration PostgreSQL trước
khi start ứng dụng:

```bash
docker compose --profile service up -d --force-recreate gx-pi
docker compose ps
docker compose logs --tail=100 gx-pi
```

Entrypoint của release tự chạy các Ecto/Oban migration còn thiếu trước khi
start. Không cần chạy migration thủ công lần thứ hai. Nếu triển khai release
ngoài Docker, chạy migration trước khi start:

```bash
bin/gx_portfolio_intelligence eval "GxPortfolioIntelligence.Release.migrate()"
```

Sau khi `gx-pi` start, xác minh migration và alias backfill bằng các truy vấn
read-only sau:

```bash
docker compose --profile service exec -T postgres \
  psql -U postgres -d gx_portfolio_intelligence -v ON_ERROR_STOP=1 \
  -c "SELECT version FROM schema_migrations WHERE version = 20260825000000; \
      SELECT batch_type, research_mode, count(*) FROM research_batches GROUP BY 1, 2 ORDER BY 1, 2; \
      SELECT count(*) AS missing_backfilled_aliases FROM research_batches rb \
      WHERE rb.batch_type = 'adhoc' \
        AND rb.idempotency_key_hash ~ '^[0-9a-f]{64}$' \
        AND rb.metadata->>'request_fingerprint' ~ '^[0-9a-f]{64}$' \
        AND NOT EXISTS (SELECT 1 FROM research_batch_request_keys rk \
                        WHERE rk.idempotency_key_hash = rb.idempotency_key_hash \
                          AND rk.research_batch_id = rb.id \
                          AND rk.request_fingerprint = rb.metadata->>'request_fingerprint'); \
      SELECT indexname FROM pg_indexes \
      WHERE indexname = 'research_batches_historical_analysis_date_index';"
```

Kết quả mong đợi: có version `20260825000000`, các cặp mode chỉ gồm
`eod/eod`, `adhoc/live` và (sau khi tạo replay) `adhoc/historical`,
`missing_backfilled_aliases = 0`, đồng thời unique index lịch sử được liệt kê.
Migration chỉ backfill alias cho batch cũ có đủ hai hash hợp lệ; raw
`Idempotency-Key` không được lưu.

### 8.2. Gọi API

Request body có `tickers` và tùy chọn `analysis_date`. API chấp nhận từ 1 đến 50 mã duy
nhất, chuẩn hóa thành chữ hoa và sắp xếp ổn định. Một mã hợp lệ theo cú pháp có
1–16 ký tự `A-Z` hoặc `0-9`; hai giá trị như `HPG` và `hpg` trong cùng request
được xem là trùng và bị từ chối.

```bash
export GX_TOKEN='<cùng giá trị GX_PI_API_TOKEN>'
export GX_REQUEST_KEY="adhoc-$(openssl rand -hex 16)"

curl --fail --silent --show-error \
  -H "Authorization: Bearer $GX_TOKEN" \
  -H "Idempotency-Key: $GX_REQUEST_KEY" \
  -H "Content-Type: application/json" \
  -X POST http://127.0.0.1:4010/api/v1/ad-hoc-research-batches \
  -d '{"tickers":["HPG","FPT","VCB","MBB","SSI"]}' \
  -o /tmp/gx-adhoc-batch.json

jq . /tmp/gx-adhoc-batch.json
export BATCH_ID="$(jq -r '.data.batch_id' /tmp/gx-adhoc-batch.json)"
```

Chạy dựng lại một ngày quá khứ tại cutoff cố định `15:00 Asia/Ho_Chi_Minh`:

```bash
export GX_REQUEST_KEY="historical-20260824-$(openssl rand -hex 8)"

curl --fail --silent --show-error \
  -H "Authorization: Bearer $GX_TOKEN" \
  -H "Idempotency-Key: $GX_REQUEST_KEY" \
  -H "Content-Type: application/json" \
  -X POST http://127.0.0.1:4010/api/v1/ad-hoc-research-batches \
  -d '{"analysis_date":"2026-08-24","tickers":["SSI","ACB"]}' | jq
```

`Idempotency-Key` phải dài 8–128 ký tự và chỉ gồm chữ, số, `.`, `_`, `:`, `-`.
Client phải lưu key cùng thao tác:

- Gửi lại cùng key và cùng payload trả cùng `batch_id`, với `replayed=true`.
- Dùng cùng key cho tập mã khác trả HTTP `409` với
  `idempotency_conflict`.
- Với chế độ live, muốn tạo một batch mới cho cùng tập mã, dùng key mới.
- Riêng ngày quá khứ, key mới với cùng tập mã vẫn trả canonical batch hiện có;
  key mới với tập mã khác trả `409 historical_batch_conflict`.

Không gửi `cutoff` trong body. Không có `analysis_date`, hoặc ngày bằng hôm nay,
server chạy live và đóng băng cutoff đúng thời điểm nhận request. Ngày quá khứ
dùng đúng 15:00; ngày tương lai/sai định dạng trả `422`. Retry không đẩy cutoff
sang thời điểm mới. Response `202` trả `research_mode`, `data_provenance` và
header `Location` trỏ tới endpoint theo dõi batch.

### 8.3. Theo dõi batch và items

Poll endpoint batch bằng `batch_id` trả về từ POST:

```bash
curl --fail --silent --show-error \
  -H "Authorization: Bearer $GX_TOKEN" \
  "http://127.0.0.1:4010/api/v1/research-batches/$BATCH_ID" | jq

curl --fail --silent --show-error \
  -H "Authorization: Bearer $GX_TOKEN" \
  "http://127.0.0.1:4010/api/v1/research-batches/$BATCH_ID/items?limit=50&offset=0" | jq
```

Ngay sau POST, danh sách items có thể còn rỗng trong lúc universe job đang
chạy. Tiếp tục poll cho đến khi batch đi qua
`pending/collecting -> researching -> indexing -> completed`. Có thể liệt kê
riêng các batch ad-hoc:

```bash
curl --fail --silent --show-error \
  -H "Authorization: Bearer $GX_TOKEN" \
  "http://127.0.0.1:4010/api/v1/research-batches?batch_type=adhoc&limit=20" | jq
```

### 8.4. Ngữ nghĩa dữ liệu và lỗi

- `evidence_policy=archive_as_of_request_cutoff`: research chỉ sử dụng evidence
  đã có trong archive và đủ điều kiện point-in-time tại `cutoff_at`. Endpoint
  không tự chạy collector mới và không chờ lịch EOD; nếu cần dữ liệu collector
  mới nhất, chạy collector được cấp quyền trước rồi mới gọi API.
- `research_mode=historical` dùng `data_provenance=historical_replay` và
  `evidence_policy=archive_as_of_historical_cutoff`. Universe dùng đúng 20 phiên
  `tvhistory1d` đến ngày D, không dùng `stocks_price`; không chạy collector live
  để lấp dữ liệu cũ. Archive/quote thiếu làm digest partial, không làm rò dữ liệu
  hiện tại vào kết quả quá khứ.
- Batch ad-hoc dùng source RAG riêng, có thể cùng tồn tại với batch EOD trong
  một ngày và không ghi đè digest EOD.
- `liquidity_rank` và `rank_scope=batch` là thứ hạng **trong tập mã request**,
  không khẳng định các mã đó thuộc top 500 thanh khoản toàn thị trường.
- Mỗi mã vẫn phải là cổ phiếu GX đủ điều kiện và có đủ dữ liệu 20 observations.
  Nếu một mã không đủ điều kiện, toàn batch chuyển `blocked` với
  `requested_tickers_unavailable`; hệ thống không âm thầm thay bằng mã khác.
- Batch ad-hoc không tham gia SLA EOD 490/500; API trả
  `sla_status=not_applicable`. Batch vẫn chỉ `completed` sau khi toàn bộ digest
  được RAG-ready và RAG batch được seal.
- HTTP `422` dùng cho body/header/ticker không hợp lệ, gồm thiếu hoặc sai
  `Idempotency-Key`, danh sách ngoài 1–50, mã sai cú pháp, mã trùng hoặc có field
  thừa, ngày sai định dạng hoặc ngày tương lai. HTTP `409` chỉ ra key đã được
  dùng cho payload khác hoặc một historical batch khác tập mã đã khóa ngày đó.
- `GET /api/v1/research-batches/:id` trả `last_error_code` đã làm sạch để chẩn
  đoán batch `blocked`; không trả stderr, raw evidence hoặc credential.

## 9. Chạy smoke batch 5 mã EOD

Chạy sau 15:45 vào một ngày giao dịch. Nếu chạy trước 15:45, Oban sẽ schedule
các bước còn lại theo đúng slot thay vì chạy ngay.

```bash
export GX_TOKEN='<cùng giá trị GX_PI_API_TOKEN>'
export GX_DATE='2026-08-24'

curl --fail --silent \
  -H "Authorization: Bearer $GX_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST http://127.0.0.1:4010/api/v1/research-batches \
  -d "{\"analysis_date\":\"$GX_DATE\",\"limit\":5}" | jq
```

POST trả `job_id`. Batch chỉ xuất hiện sau khi universe hoàn tất. Tìm `batch_id`:

```bash
curl --fail --silent \
  -H "Authorization: Bearer $GX_TOKEN" \
  "http://127.0.0.1:4010/api/v1/research-batches?analysis_date=$GX_DATE" | jq
```

Khi response có batch, đặt ID:

```bash
export BATCH_ID='<batch id>'
```

Theo dõi batch và items:

```bash
curl --fail --silent \
  -H "Authorization: Bearer $GX_TOKEN" \
  "http://127.0.0.1:4010/api/v1/research-batches/$BATCH_ID" | jq

curl --fail --silent \
  -H "Authorization: Bearer $GX_TOKEN" \
  "http://127.0.0.1:4010/api/v1/research-batches/$BATCH_ID/items?limit=100&offset=0" | jq
```

Luồng trạng thái thông thường:

```text
collecting -> researching -> indexing -> completed
```

Batch 5 mã thành công khi:

- Universe có đúng 5 ranks duy nhất.
- Có 5 research items `complete` hoặc `partial`.
- Có 5 items `rag_status=ready`.
- SimpleRAG batch được seal.
- Không có raw title/body/excerpt trong RAG hoặc API response.

## 10. Retry batch lỗi

```bash
curl --fail --silent \
  -H "Authorization: Bearer $GX_TOKEN" \
  -X POST \
  "http://127.0.0.1:4010/api/v1/research-batches/$BATCH_ID/retry" | jq
```

Lưu ý:

- Batch ad-hoc bị `blocked` **trước khi có snapshot**
  (`universe_snapshot_id=null`) có thể schedule lại một universe job; response
  trả `retry_items=1`.
- Batch ad-hoc đã có frozen snapshot mà bị `blocked` là bất biến. Retry trả HTTP
  `202` với `retry_items=0`, không dựng lại universe, không thay ticker/cutoff và
  không gọi lại LLM. Hãy đọc `last_error_code` để xử lý nguyên nhân; không sửa
  trực tiếp PostgreSQL hoặc xóa RAG để ép chạy lại canonical historical batch.
- Python durable claim bảo đảm cùng identity không gọi LLM lần hai.
- LLM lỗi sẽ tạo deterministic data-only digest với trạng thái `partial`.
- RAG document `stale` bị block và không được retry vô hạn. Cần kiểm tra clock,
  `source_updated_at` và document mới hơn đang có trong RAG.

## 11. Rollout 50 và 500 mã

Chạy lần lượt:

1. `limit=5`.
2. `limit=50`.
3. `limit=500`.

Universe của một ngày là bất biến. Không chạy 5 rồi đổi thành 50 hoặc 500 trên
cùng `analysis_date` và cùng artifact/database namespace. Chọn một trong hai:

- Chạy mỗi mức vào một ngày giao dịch khác nhau; hoặc
- Dùng deployment/database/artifact namespace độc lập cho từng smoke run.

Với batch 500:

- SLA đạt khi ít nhất `490/500` mã RAG-ready trước 08:00.
- Batch chỉ `completed` khi đủ `500/500`.
- Universe dưới 500 giữ trạng thái `degraded` và phát webhook cảnh báo.
- Các mã lỗi tiếp tục được maintenance retry sau SLA.

Items API phân trang tối đa 100 bản ghi. Dùng các offset `0`, `100`, `200`,
`300`, `400` để kiểm tra toàn bộ 500 mã.

## 12. Bật lịch tự động

Sau khi 5/50/500 đều đạt, backup PostgreSQL, artifacts và SimpleRAG trước. Sửa:

```dotenv
GX_PI_CRON_ENABLED=true
```

Recreate đúng một `gx-pi` replica:

```bash
docker compose --profile service up -d --force-recreate gx-pi
docker compose ps
```

Lịch `Asia/Ho_Chi_Minh`:

| Thời gian | Công việc |
| --- | --- |
| 09:15, 10:15, 11:15, 13:15, 14:15 | Candidate universe 600 và incremental social/media |
| 15:15 | Freeze top 500 |
| 15:20 | Final social/media |
| 15:30 | Final macro/media |
| 15:45 | Fan-out research |
| 07:30 hôm sau | Early SLA warning |
| 08:00 hôm sau | Final SLA evaluation |
| Mỗi 15 phút | Dependency, disk và recovery maintenance |

## 13. Theo dõi hằng ngày

```bash
docker compose ps
docker compose logs --tail=200 gx-pi
docker compose logs --tail=200 simple-rag

curl --silent http://127.0.0.1:4010/health/ready | jq
curl --silent \
  -H "Authorization: Bearer $GX_TOKEN" \
  "http://127.0.0.1:4010/api/v1/research-batches?limit=10" | jq
```

Webhook có thể phát:

- `batch_sla_missed`.
- `batch_blocked`.
- `batch_recovered`.
- `dependency_unhealthy`.

Payload dùng allowlist và không chứa raw evidence hoặc credential.

## 14. Backup và retention

Trước migration, upgrade hoặc thay model:

1. Dừng `gx-pi` để không tạo job mới.
2. Dừng `simple-rag` để SQLite và Chroma có snapshot nhất quán.
3. Snapshot PostgreSQL volume.
4. Snapshot nguyên `simple_rag_data` volume.
5. Snapshot `gx_pi_artifacts` và lưu cùng archive encryption key version.

Raw archive, universe, digest và RAG history được giữ vô thời hạn trong V1.
Theo dõi dung lượng và xử lý webhook `artifact_disk_capacity_low` trước khi đầy
đĩa.

## 15. Dừng và khởi động lại

Dừng service nhưng giữ dữ liệu:

```bash
docker compose --profile service stop
```

Khởi động lại:

```bash
docker compose --profile service up -d
```

Không dùng `docker compose down -v` trừ khi chủ động muốn xóa toàn bộ database,
artifacts, archive, model cache và RAG history.

## 16. Xử lý lỗi thường gặp

| Hiện tượng | Kiểm tra |
| --- | --- |
| `/health/ready` trả 503 | Xem trường `checks.database`, `checks.trading_agents`, `checks.rag` |
| SimpleRAG `degraded` | Kiểm tra BGE-M3 cache, Ollama URL và `RAG_CHAT_MODEL` |
| Không tạo batch | Kiểm tra ngày nghỉ, GX PostgreSQL, thời điểm 15:15 và UniverseWorker logs |
| Universe `degraded` | Có dưới target mã đủ đúng 19 historical rows + current G1 |
| FireAnt 429 | Để Oban retry; không tăng concurrency/RPM tùy tiện |
| Item `partial` | Kiểm tra LLM/provider; data-only digest vẫn được RAG index |
| RAG `stale` | Kiểm tra clock và `source_updated_at`; không POST lặp cùng digest cũ |
| Batch dừng ở `indexing` | Kiểm tra SimpleRAG writer, embedding model và RAG status endpoint |
| Disk alert | Mở rộng volume hoặc backup/archive theo chính sách trước khi hết chỗ |

## 17. Chạy Phoenix trên host thay vì Docker

Chỉ dùng cho development:

```bash
docker compose up -d postgres

export GX_PI_DB_PORT=5434
export GX_PI_DB_NAME=gx_portfolio_intelligence
export GX_PI_API_TOKEN='<token>'
export TRADING_AGENTS_ROOT='/absolute/path/to/TradingAgents'
export TRADING_AGENTS_PYTHON='/absolute/path/to/TradingAgents/.venv/bin/python'
export GX_PI_ARTIFACT_ROOT='/absolute/path/to/artifacts'
export RAG_SERVICE_URL='http://127.0.0.1:8000'
export RAG_SERVICE_API_KEY='<shared token>'

mix setup
mix phx.server
```

Không source `.env.example` production cho flow chạy trên host.

## 18. Trend và Full Analysis (tùy chọn)

Full Analysis là pipeline best-effort nằm sau daily digest. Nó không thay đổi
`completed_count`, `rag_ready_count`, ngưỡng `490/500`, trạng thái SLA hoặc retry
của batch digest. Một digest `complete` hoặc data-only `partial` đều có thể làm
đầu vào; nếu full report không publishable thì document digest hiện hữu được giữ
nguyên.

Khác với daily digest, full report có thể chứa khuyến nghị, sizing, mục tiêu và
quyết định danh mục. Đây vẫn chỉ là research output: hệ thống không có API đặt
lệnh, không tự động execution và không tự động rebalancing.

### 18.1 Migration và cấu hình

Backup PostgreSQL GX PI và SimpleRAG trước, sau đó deploy SimpleRAG có endpoint
promotion, deploy TradingAgents có nhóm lệnh `analysis`, rồi mới migrate GX PI:

```bash
docker compose --profile service stop gx-pi
docker compose --profile service build simple-rag gx-pi
docker compose --profile service up -d simple-rag
docker compose --profile service run --rm gx-pi \
  bin/gx_portfolio_intelligence eval 'GxPortfolioIntelligence.Release.migrate()'
docker compose --profile service up -d gx-pi
```

Bốn migration forward-only phải được áp dụng theo thứ tự:

- `20260825010000_add_full_analysis_workflow`: thêm `analysis_depth` và state
  bền vững cho trend/full analysis.
- `20260825011000_add_full_analysis_stage_leases`: thêm claim, lease và attempt
  để stage có thể resume an toàn sau crash.
- `20260825012000_add_full_analysis_restart_keys`: thêm idempotency bền vững cho
  explicit restart.
- `20260825013000_add_adv20_to_trend_members`: bổ sung ADV20 bắt buộc cho
  trend-member và backfill an toàn các row pre-release.

Các migration không xóa universe, digest, Oban jobs hay document RAG cũ.

Cấu hình rollout ban đầu:

```dotenv
GX_PI_TREND_ENABLED=true
GX_PI_FULL_ANALYSIS_ENABLED=false
GX_PI_FULL_ANALYSIS_LIMIT=5
GX_PI_FULL_ANALYSIS_BACKLOG_WARNING_THRESHOLD=20
GX_PI_FULL_ANALYSIS_PINNED_TICKERS=
TRADING_AGENTS_FULL_STAGE_TIMEOUT_MS=1800000
TRADING_AGENTS_FULL_LLM_MAX_RETRIES=0
TRADING_AGENTS_FULL_MAX_TOOL_ROUNDS=8
TRADINGAGENTS_QUICK_LLM_PROVIDER=openai
TRADINGAGENTS_QUICK_THINK_LLM=gpt-5.4-mini
TRADINGAGENTS_QUICK_LLM_API_KEY=<secret-manager>
TRADINGAGENTS_DEEP_LLM_PROVIDER=openai
TRADINGAGENTS_DEEP_THINK_LLM=gpt-5.5
TRADINGAGENTS_DEEP_LLM_API_KEY=<secret-manager>
OBAN_TREND_CONCURRENCY=1
OBAN_FULL_ANALYSIS_CONCURRENCY=2
```

Full Analysis dùng cả hai profile: bốn analyst dùng Quick, còn
research/trader/risk dùng Deep. Nếu provider dùng endpoint riêng, cấu hình thêm
`TRADINGAGENTS_QUICK_LLM_BASE_URL` và `TRADINGAGENTS_DEEP_LLM_BASE_URL`. Có thể
dùng canonical provider key (ví dụ `OPENAI_API_KEY`) thay role-specific key,
nhưng không ghi credential thật vào repo hoặc log.

`GX_PI_FULL_ANALYSIS_ENABLED=true` chỉ bật tự động cho EOD. Ticker EOD được chọn
trong official frozen top 500 theo trend score, mặc định 5 mã. Ticker pin được
ưu tiên theo thứ tự cấu hình nhưng ticker ngoài top 500 bị loại và phát
`dependency_unhealthy`; số ticker pin lớn hơn limit làm `/health/ready` không
sẵn sàng. Khi target EOD tự động lớn hơn ngưỡng backlog (mặc định 20), hệ thống
phát đúng một cảnh báo dedup `dependency_unhealthy` cho batch; cảnh báo này
không block và không thay đổi digest SLA.

### 18.2 Chạy ad-hoc full ngay

Ad-hoc `analysis_depth=full` chạy full analysis cho **toàn bộ** ticker yêu cầu,
không áp dụng limit EOD:

```bash
export GX_REQUEST_KEY="full-$(date +%Y%m%d-%H%M%S)"

curl --fail --silent --show-error \
  -H "Authorization: Bearer $GX_TOKEN" \
  -H "Idempotency-Key: $GX_REQUEST_KEY" \
  -H "Content-Type: application/json" \
  -X POST http://127.0.0.1:4010/api/v1/ad-hoc-research-batches \
  -d '{"tickers":["SSI","ACB"],"analysis_depth":"full"}' \
  | tee /tmp/gx-full-create.json | jq

export BATCH_ID="$(jq -r '.data.batch_id' /tmp/gx-full-create.json)"
test -n "$BATCH_ID" && test "$BATCH_ID" != "null"
```

Ví dụ copy/paste để chạy ngay Full Analysis cho 5 mã:

```bash
cd /Users/thachtan/Documents/source/APG/gx.portfolio.intelligence

export GX_TOKEN="token-gx-pi-cua-ban"
export GX_REQUEST_KEY="full-5-$(date +%Y%m%d-%H%M%S)"

curl --fail --silent --show-error \
  -H "Authorization: Bearer $GX_TOKEN" \
  -H "Idempotency-Key: $GX_REQUEST_KEY" \
  -H "Content-Type: application/json" \
  -X POST http://127.0.0.1:4010/api/v1/ad-hoc-research-batches \
  -d '{
    "tickers": ["SSI", "ACB", "HPG", "FPT", "VCB"],
    "analysis_depth": "full"
  }' | tee /tmp/gx-full-5.json | jq

export BATCH_ID="$(jq -r '.data.batch_id' /tmp/gx-full-5.json)"
test -n "$BATCH_ID" && test "$BATCH_ID" != "null"
echo "BATCH_ID=$BATCH_ID"

curl --fail --silent --show-error \
  -H "Authorization: Bearer $GX_TOKEN" \
  "http://127.0.0.1:4010/api/v1/research-batches/$BATCH_ID/full-analysis" | jq

curl --fail --silent --show-error \
  -H "Authorization: Bearer $GX_TOKEN" \
  "http://127.0.0.1:4010/api/v1/research-batches/$BATCH_ID/full-analysis/items?limit=50" | jq
```

Lệnh này dùng cutoff tại thời điểm gọi. Muốn tạo execution mới, dùng
`GX_REQUEST_KEY` mới; gửi lại cùng key và cùng payload chỉ replay batch hiện có.

Có thể thêm `"analysis_date":"2026-08-24"` để historical replay. Cùng key nhưng
đổi `analysis_depth` trả `409 idempotency_conflict`. Với key mới và đúng tập mã,
historical canonical batch `digest` được nâng một chiều lên `full`; request
`digest` vào canonical batch đã là `full` chỉ trả lại batch đó và không hạ cấp.
Key mới nhưng tập mã khác vẫn trả `409 historical_batch_conflict`.

### 18.3 Theo dõi và resume

```bash
curl --fail --silent \
  -H "Authorization: Bearer $GX_TOKEN" \
  "http://127.0.0.1:4010/api/v1/research-batches/$BATCH_ID/full-analysis" | jq

curl --fail --silent \
  -H "Authorization: Bearer $GX_TOKEN" \
  "http://127.0.0.1:4010/api/v1/research-batches/$BATCH_ID/full-analysis/items?limit=50" | jq

curl --fail --silent \
  -H "Authorization: Bearer $GX_TOKEN" \
  "http://127.0.0.1:4010/api/v1/research-batches/$BATCH_ID/full-analysis/items/SSI/stages" | jq
```

Bảy stage chạy tuần tự cho từng ticker:

```text
market -> sentiment -> news -> fundamentals -> research -> trader -> risk
```

Mỗi stage có state bền vững và worker gọi `analysis status` trước khi tiếp tục,
do đó crash sau Python nhưng trước commit PostgreSQL sẽ reconcile artifact thay
vì sinh lại stage. Full item chỉ promotion khi core `research`, `trader`, `risk`
đều `complete`, digest hash/parent identity vẫn khớp và RAG batch đã seal.

Retry riêng full pipeline:

```bash
curl --fail --silent \
  -H "Authorization: Bearer $GX_TOKEN" \
  -X POST \
  "http://127.0.0.1:4010/api/v1/research-batches/$BATCH_ID/full-analysis/retry" | jq
```

Resume mặc định giữ nguyên `execution_generation`, execution key, digest
identity và các stage đã complete. Nó không clear document và không gọi lại
daily digest LLM.

Chỉ khi item đang `failed`/`blocked` **trước export**, `full_report_hash` còn
trống, `rag_status=pending` và chưa promotion, có thể explicit restart để tạo
generation mới. Thao tác này bắt buộc một `Idempotency-Key` mới; gửi lại cùng
key/payload là no-op:

```bash
export GX_RESTART_KEY="full-restart-$BATCH_ID-$(openssl rand -hex 8)"

curl --fail --silent --show-error \
  -H "Authorization: Bearer $GX_TOKEN" \
  -H "Idempotency-Key: $GX_RESTART_KEY" \
  -H "Content-Type: application/json" \
  -X POST \
  "http://127.0.0.1:4010/api/v1/research-batches/$BATCH_ID/full-analysis/retry" \
  -d '{"mode":"restart","tickers":["SSI"]}' | jq
```

Không restart item đang `queued`/`submitted`/`indexing`, item lỗi sau khi gửi
RAG, hoặc item đã `ready`/promoted. Các trường hợp đó trả `409`; controlled
replacement của full report đã promoted nằm ngoài V1.

### 18.4 Kiểm tra trend và rollout EOD

```bash
curl --fail --silent \
  -H "Authorization: Bearer $GX_TOKEN" \
  "http://127.0.0.1:4010/api/v1/trend-snapshots?analysis_date=$GX_DATE" | jq
```

Chỉ bật `GX_PI_FULL_ANALYSIS_ENABLED=true` sau khi candidate/final trend có
fingerprint hợp lệ, final `cutoff_at` tương ứng 15:00 và selection chỉ chứa rank
1–500. Sau khi đổi env phải recreate container:

```bash
docker compose --profile service up -d --force-recreate gx-pi
docker compose ps
curl --silent http://127.0.0.1:4010/health/ready | jq
```

Theo dõi hai queue mới `trend:1`, `full_analysis:2`. Không tăng concurrency cho
đến khi smoke 2 mã ad-hoc và EOD 5 mã đều promotion thành công. Promotion dùng
cùng logical RAG document; `promoted` thay chunks/vector digest, `unchanged` là
no-op, `stale/conflict` giữ digest và ghi `last_error_code` an toàn.

Các feature flag chỉ ngăn **lịch tạo job mới**; chúng không hủy job đã được ghi
vào Oban. Khi cần dừng khẩn cấp, giữ container chạy để state bền vững không mất,
tạm pause queue `trend`/`full_analysis` trong Oban hoặc chờ các job hiện tại về
terminal rồi mới đánh giá rollback. Không dùng `docker compose down -v`.
