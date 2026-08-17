# ace-currency-api

Portfolio demo API built with **IBM App Connect Enterprise (ACE)**, showing an HTTP-exposed flow with ESQL transformation, caching, and explicit error-path routing. Personal, non-commercial demo — part of [matheusribeiro.dev.br](https://matheusribeiro.dev.br).

## What it does

`GET /api/currency?from=USD&to=BRL&amount=100`

This install's `WSRequest` node (the ACE "web services" HTTP-family; `HTTPRequest` isn't present in this "ace-developer" download) never actually honours a dynamic destination override — confirmed by testing, not assumed: requesting different `from` currencies kept returning the same upstream response regardless of what the ESQL set. So instead of asking Frankfurter for one specific pair per request, the flow always fetches the same EUR-based bulk rate table (one static URL, no override needed), and the from/to conversion is computed by triangulating through EUR: `rate(from, to) = eur[to] / eur[from]`.

1. **HTTP Input** validates `from`/`to`/`amount`.
2. **Compute (ESQL)** checks a cache of the bulk rate table (a `SHARED` ESQL variable, 10-minute TTL). A cache hit skips the fetch entirely via the node's failure terminal.
3. **HTTP Request** (cache miss only) fetches the full EUR rate table from [Frankfurter](https://frankfurter.dev) — free, keyless.
4. **Compute (ESQL)** triangulates the requested pair and builds the response.
5. **Log4j node** writes one structured JSON line per request (endpoint, params, cache status) — see [Observability](#observability) below.
6. **HTTP Reply**. Two dedicated error-formatting Compute nodes handle client errors — missing params, unknown currency codes (400) — and upstream failures (502) instead of leaking internals.

`GET /api/currency/rates?base=USD`

Same cached bulk table, presented as a full base -> all-currencies rate list instead of a single pair.

`GET /api/currency/convert-many?pairs=USD-BRL,EUR-JPY,GBP-CAD&amount=100`

Triangulates every pair against the same cached bulk table in one call. Mirrors the Mule weather API's `/api/weather/compare` pattern: an invalid or unknown pair reports its own `ok`/`error` inline in `results` instead of failing the whole request.

No API keys anywhere — Frankfurter is free and keyless. CORS is open (`Access-Control-Allow-Origin: *`) so both endpoints can be called straight from a browser — see the live demo widget on [matheusribeiro.dev.br](https://matheusribeiro.dev.br).

Interactive API docs (Swagger UI, self-hosted): [ace-demo.matheusribeiro.dev.br/docs/](https://ace-demo.matheusribeiro.dev.br/docs/) — spec source at [`docs/openapi.yaml`](docs/openapi.yaml).

```bash
curl "https://ace-demo.matheusribeiro.dev.br/api/currency?from=USD&to=BRL&amount=100"
```

```json
{
  "from": "USD",
  "to": "BRL",
  "amount": 100,
  "rate": 5.104853,
  "convertedAmount": 510.4853,
  "baseDate": "2026-08-11",
  "cached": false
}
```

## Project layout

```
CurrencyApiApp/
  CurrencyApi.msgflow                    # the message flow: three HTTP Input paths sharing cache/error nodes
  CurrencyApi_BuildRequest.esql          # validates from/to/amount
  CurrencyApi_CheckRatesParam.esql       # validates base (for /rates)
  CurrencyApi_CheckPairsParam.esql       # validates pairs/amount (for /convert-many)
  CurrencyApi_Cache.esql                 # SHARED-variable cache, reused as both the check and write step
  CurrencyApi_BuildResponse.esql         # triangulates the requested pair, builds the /currency response
  CurrencyApi_BuildRatesResponse.esql    # builds the /rates response (hand-built JSON string -- see file comment)
  CurrencyApi_BuildManyResponse.esql     # triangulates every pair for /convert-many, one upstream fetch
  CurrencyApi_MissingParamError.esql     # 400 error path
  CurrencyApi_UpstreamError.esql         # 502 error path
  application.descriptor, .project       # ACE application project metadata
docs/                                    # self-hosted OpenAPI spec + vendored Swagger UI
Dockerfile                                # builds a BAR with ibmint and bundles it with the ACE runtime
```

## A note on the cache

`CurrencyApi_Cache.esql` is the correct, intended pattern for this kind of caching (a `SHARED` ESQL variable, reused across two flow steps so it's actually shared). Testing on this specific containerized install showed it not surviving between separate HTTP requests, though — so in practice every request currently takes the "fetch" path. The code is left as-is since it's genuinely how you'd do this on a normal ACE install; see the comment in that file for what was tried.

## A note on error status codes

`CurrencyApi_MissingParamError`/`CurrencyApi_UpstreamError` set `OutputLocalEnvironment.Destination.HTTP.ReplyStatusCode` to 400/502 the textbook-correct way — confirmed against real, live production ESQL using the same `WSInput`/`WSReply` node pair. On this specific containerized install, though, `WSReply` never actually honours it: it always replies `200`, confirmed by testing even the success path with a forced non-default status code. Same category of limitation as the `WSRequest`/`SHARED`-cache findings above. The status-setting code is left in (correct intent, and it'd start working on its own if a future ACE patch fixes this) — for now, clients need to check the `"error"` field in the JSON body rather than the HTTP status to detect a failed request.

## Observability

Every successful request writes a structured JSON line (timestamp, endpoint, request params, cache status) via ACE's [Log4j node](https://github.com/ot4i/node-for-log4j) — the "IAM3" `Log4jLoggingNode` SupportPac, IBM's documented way to get real Log4j2 logging out of an ESQL-only flow (there's no Java compute node here to reach Log4j from directly). Rotated and gzip-compressed on rollover via `log4j2-access.xml`.

Getting this working on this specific containerized install took some real trial and error, same spirit as the WSRequest/SHARED-variable findings above:

- The Log4j node's LIL loader needs the raw `.par` file sitting in a `lilPath` directory (set in `overrides/server.conf.yaml`) — pointing it at the `.par`'s *extracted* contents instead loads the classes fine but produces a wall of non-fatal `BIP4512S` warnings, because log4j-core's own multi-release JAR layout (`META-INF/versions/9/...`) isn't multi-release-aware-loaded by ACE's classloader. Harmless (this app doesn't use any of the optional features those classes are for — async logging, XML output, OSGi), but worth knowing about if you see it in the logs.
- The node's `logText` property reads from `Environment.Variables.Log4j.LogText` specifically (its documented default) — not just any `LocalEnvironment` path — so each Build Response ESQL module sets that exact variable before returning.

Every request also generates a `correlationId`, returned as an `X-Correlation-Id` response header and threaded through every log line for that request — `/api/currency` writes 4 (request received, Frankfurter response, countries.dev response, final access log), `/rates` and `/convert-many` write 1 each. `docker-entrypoint.sh` tails the local log file and ships each new line to the shared [observability-stack](https://github.com/MatthewJulioRibeiro/observability-stack)'s ingest endpoint (`INGEST_URL`/`INGEST_TOKEN` env vars, same pattern as `mule-weather-api`) alongside the Mule weather API's own logs, in addition to staying in the local rotated file. Both env vars are optional — the app runs fine without them, it just stays local-only (this is how `ace-local-test`/local dev runs by default).

## Running it yourself

The ACE runtime is a licensed IBM binary that can't be redistributed, so it isn't in this repo. To build the image:

1. Download **"IBM App Connect Enterprise for Developers"** (Linux x86_64) from IBM Fix Central — free registration, non-commercial/dev license.
2. Save it as `runtime/ace-developer.tar.gz`.
3. `docker build -t ace-currency-api .`
4. `docker run -p 7800:7800 ace-currency-api`

"For Developers" is IBM's free, non-time-boxed edition for non-production use — appropriate for a personal portfolio demo like this one.

The parent folder's [`docker-compose.local.yml`](../docker-compose.local.yml) builds this app alongside `mule-weather-api` and the full observability stack in one command, wired the same way production is (logs shipped to the same local Elasticsearch) — see that file's header comment for the exact command.

## Testing

ESQL has no unit-test framework reachable outside the full IBM Integration Toolkit (GUI-only; every flow in this repo has always been hand-authored against the trimmed "ace-developer" runtime, no Toolkit involved). So instead, [`test/api-contract-test.mjs`](test/api-contract-test.mjs) is a small black-box HTTP contract test — zero dependencies (Node's built-in `fetch`), asserting on the real JSON responses (including the `error` field, since this install's `WSReply` never honours a non-200 status code — see below).

```bash
node test/api-contract-test.mjs                      # against localhost:7800 (docker-compose.local.yml)
BASE_URL=https://ace-demo.matheusribeiro.dev.br node test/api-contract-test.mjs   # against production
```

Not yet wired into CI — see the sibling `mule-weather-api` repo for how a similar test job could gate the `deploy.yml` pipeline before the build/push step, using the runtime tarball that step already fetches from `ace-demo`.

## Deploy

`ace-demo` is a 1 vCPU / 1GB Oracle Cloud "Always Free" VM — too tight to
reliably run `docker build` itself (microdnf installs, unpacking the
~2.4GB ACE runtime, `ibmint package`) without swap-thrashing for 30-40+
minutes. `.github/workflows/deploy.yml` instead builds the image on the
GitHub Actions runner itself: it's x86_64 already (a *native* build, no
emulation needed), free (unlimited Actions minutes on a public repo),
and has real RAM/CPU to spare. The runner `scp`s the licensed runtime
down from `ace-demo` at the start of the job (it can't be committed to
the repo or a public image layer — see below), builds, then **pushes
the image to GitHub Container Registry** (`ghcr.io`, kept **private**
— it bakes in IBM's licensed runtime, same reason that runtime isn't
committed to this repo). `ace-demo` then just `docker pull`s and
restarts — no build at all on the resource-constrained VM.

A registry pull is layer-based and resumable, unlike a raw `scp`/pipe of
the whole ~2.5GB image in one shot (tried first, and it kept dying
mid-transfer on ace-demo's constrained bandwidth). It's also faster on
every deploy after the first: the ACE runtime layer doesn't change
between app-only changes, so `ace-demo` only re-downloads the small top
layers (BAR file, ESQL, Log4j config) once the base layers are already
cached locally.

(Two earlier versions of this pipeline were tried and replaced: cross-
building on a second VM via QEMU emulation — worked, but emulation is
slower than a native build; and building natively on the runner but
shipping the image back over a raw `scp` pipe — also worked once
manually, but the long SSH session for a multi-GB transfer was fragile
against ace-demo's limited bandwidth. GHCR fixes both.)
