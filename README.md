# ace-currency-api

Portfolio demo API built with **IBM App Connect Enterprise (ACE)**, showing an HTTP-exposed flow with ESQL transformation, an outbound HTTP call, and explicit error-path routing. Personal, non-commercial demo — part of [matheusribeiro.dev.br](https://matheusribeiro.dev.br).

## What it does

`GET /api/currency?from=USD&to=BRL&amount=100`

1. **HTTP Input** node receives the request.
2. **Compute (ESQL)** validates the `from`/`to` query params (routes to an error path via its `failure` terminal if missing) and builds the outbound request URL.
3. **HTTP Request** node calls [Frankfurter](https://frankfurter.dev) — a free, keyless exchange-rate API.
4. **Compute (ESQL)** reshapes the response: resolves the requested currency's rate dynamically from the JSON payload and computes the converted amount.
5. **HTTP Reply** node returns the result. Two dedicated error-formatting Compute nodes handle missing params (400) and upstream failures (502) instead of leaking internals.

No API keys anywhere — Frankfurter is free and keyless.

```bash
curl "https://ace-demo.matheusribeiro.dev.br/api/currency?from=USD&to=BRL&amount=100"
```

```json
{
  "from": "USD",
  "to": "BRL",
  "amount": 100,
  "rate": 5.4023,
  "convertedAmount": 540.23,
  "baseDate": "2026-08-08"
}
```

## Project layout

```
CurrencyApiApp/
  CurrencyApi.msgflow                    # the message flow (HTTP Input -> Compute -> HTTP Request -> Compute -> HTTP Reply)
  CurrencyApi_BuildRequest.esql          # validates params, builds the outbound request URL
  CurrencyApi_BuildResponse.esql         # dynamic field lookup + currency conversion math
  CurrencyApi_MissingParamError.esql     # 400 error path
  CurrencyApi_UpstreamError.esql         # 502 error path
  application.descriptor, .project       # ACE application project metadata
Dockerfile                                # builds a BAR with ibmint and bundles it with the ACE runtime
```

## Running it yourself

The ACE runtime is a licensed IBM binary that can't be redistributed, so it isn't in this repo. To build the image:

1. Download **"IBM App Connect Enterprise for Developers"** (Linux x86_64) from IBM Fix Central — free registration, non-commercial/dev license.
2. Save it as `runtime/ace-developer.tar.gz`.
3. `docker build -t ace-currency-api .`
4. `docker run -p 7800:7800 ace-currency-api`

"For Developers" is IBM's free, non-time-boxed edition for non-production use — appropriate for a personal portfolio demo like this one.

## Deploy

`.github/workflows/deploy.yml` builds the image and redeploys it over SSH on every push to `main`, onto a small Oracle Cloud "Always Free" VM — the same CI/CD pattern used across this portfolio's other repos.
