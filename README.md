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

## Observability

Every successful request writes a structured JSON line (timestamp, endpoint, request params, cache status) via ACE's [Log4j node](https://github.com/ot4i/node-for-log4j) — the "IAM3" `Log4jLoggingNode` SupportPac, IBM's documented way to get real Log4j2 logging out of an ESQL-only flow (there's no Java compute node here to reach Log4j from directly). Rotated and gzip-compressed on rollover via `log4j2-access.xml`.

Getting this working on this specific containerized install took some real trial and error, same spirit as the WSRequest/SHARED-variable findings above:

- The Log4j node's LIL loader needs the raw `.par` file sitting in a `lilPath` directory (set in `overrides/server.conf.yaml`) — pointing it at the `.par`'s *extracted* contents instead loads the classes fine but produces a wall of non-fatal `BIP4512S` warnings, because log4j-core's own multi-release JAR layout (`META-INF/versions/9/...`) isn't multi-release-aware-loaded by ACE's classloader. Harmless (this app doesn't use any of the optional features those classes are for — async logging, XML output, OSGi), but worth knowing about if you see it in the logs.
- The node's `logText` property reads from `Environment.Variables.Log4j.LogText` specifically (its documented default) — not just any `LocalEnvironment` path — so each Build Response ESQL module sets that exact variable before returning.

Right now this writes to a local rotated file inside the container. Shipping it into a central dashboard alongside the Mule weather API's own logs is tracked separately — see [observability-stack](https://github.com/MatthewJulioRibeiro/observability-stack).

## Running it yourself

The ACE runtime is a licensed IBM binary that can't be redistributed, so it isn't in this repo. To build the image:

1. Download **"IBM App Connect Enterprise for Developers"** (Linux x86_64) from IBM Fix Central — free registration, non-commercial/dev license.
2. Save it as `runtime/ace-developer.tar.gz`.
3. `docker build -t ace-currency-api .`
4. `docker run -p 7800:7800 ace-currency-api`

"For Developers" is IBM's free, non-time-boxed edition for non-production use — appropriate for a personal portfolio demo like this one.

## Deploy

`.github/workflows/deploy.yml` builds the image and redeploys it over SSH on every push to `main`, onto a small Oracle Cloud "Always Free" VM — the same CI/CD pattern used across this portfolio's other repos.
