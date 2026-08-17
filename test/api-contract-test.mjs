// Black-box HTTP contract tests for the ACE currency API.
//
// ESQL has no native unit-test framework reachable without the full IBM
// Integration Toolkit (GUI-only, not installed anywhere in this project's
// pipeline -- every .msgflow/.esql file here has always been hand-authored
// against the trimmed "ACE for Developers" runtime). So instead of testing
// ESQL modules in isolation, this hits the real deployed HTTP surface --
// the same thing a recruiter's browser or curl would do -- against a
// container that's actually running the packaged BAR file.
//
// Zero dependencies (Node's built-in fetch, Node >=18), so this can run
// unmodified in CI or against docker-compose.local.yml's ace-currency-api
// service.
//
// Usage:
//   node test/api-contract-test.mjs
//   BASE_URL=https://ace-demo.matheusribeiro.dev.br node test/api-contract-test.mjs

const BASE_URL = process.env.BASE_URL || 'http://localhost:7800';

let passed = 0;
let failed = 0;

function assert(condition, message) {
    if (condition) {
        passed++;
        console.log(`  ok   ${message}`);
    } else {
        failed++;
        console.error(`  FAIL ${message}`);
    }
}

async function get(path) {
    const res = await fetch(`${BASE_URL}${path}`);
    let body = null;
    try { body = await res.json(); } catch { /* non-JSON response */ }
    return { status: res.status, headers: res.headers, body };
}

async function run() {
    console.log(`Running contract tests against ${BASE_URL}\n`);

    {
        console.log('GET /health');
        const { status, body } = await get('/health');
        assert(status === 200, `status is 200 (got ${status})`);
        assert(body?.status === 'ok', `body.status is "ok" (got ${JSON.stringify(body)})`);
    }

    {
        console.log('\nGET /api/currency (no params)');
        const { body } = await get('/api/currency');
        // Known platform limitation (documented in PROGRESS.md and this
        // repo's README): WSReply on this ACE install never honours a
        // non-200 ReplyStatusCode, so error detection must go through the
        // JSON body's `error` field, not the HTTP status code.
        assert(body?.error === 'MISSING_PARAM', `body.error is MISSING_PARAM (got ${JSON.stringify(body)})`);
    }

    {
        console.log('\nGET /api/currency?from=USD&to=BRL&amount=100');
        const { body } = await get('/api/currency?from=USD&to=BRL&amount=100');
        assert(typeof body?.rate === 'number' && body.rate > 0, `rate is a positive number (got ${body?.rate})`);
        assert(Math.abs(body?.convertedAmount - body?.rate * 100) < 0.01, `convertedAmount = rate * amount (got ${body?.convertedAmount} vs rate*100=${body?.rate * 100})`);
        assert(typeof body?.toCurrencyName === 'string' && body.toCurrencyName.length > 0, `toCurrencyName is populated (got ${JSON.stringify(body?.toCurrencyName)})`);
    }

    {
        console.log('\nGET /api/currency?from=XXX&to=BRL&amount=100');
        const { body } = await get('/api/currency?from=XXX&to=BRL&amount=100');
        assert(body?.error === 'UNKNOWN_CURRENCY', `body.error is UNKNOWN_CURRENCY (got ${JSON.stringify(body)})`);
    }

    {
        console.log('\nGET /api/currency/rates?base=USD');
        const { body } = await get('/api/currency/rates?base=USD');
        assert(body?.base === 'USD', `base echoed back (got ${body?.base})`);
        assert(body?.rates && typeof body.rates === 'object' && Object.keys(body.rates).length > 10, `rates has a real set of currencies (got ${body?.rates ? Object.keys(body.rates).length : 0} entries)`);
    }

    {
        console.log('\nGET /api/currency/convert-many?pairs=USD-BRL,EUR-BRL&amount=10');
        const { body } = await get('/api/currency/convert-many?pairs=USD-BRL,EUR-BRL&amount=10');
        assert(Array.isArray(body?.results) && body.results.length === 2, `two results returned (got ${body?.results?.length})`);
        assert(body?.results?.every(r => r.ok === true), `every pair resolved ok (got ${JSON.stringify(body?.results?.map(r => r.ok))})`);
    }

    {
        console.log('\nCORS + correlation headers on a normal request');
        const res = await fetch(`${BASE_URL}/api/currency?from=USD&to=BRL`);
        assert(res.headers.get('access-control-allow-origin') === '*', `Access-Control-Allow-Origin is * (got ${res.headers.get('access-control-allow-origin')})`);
        assert(!!res.headers.get('x-correlation-id'), `X-Correlation-Id header is present (got ${res.headers.get('x-correlation-id')})`);
    }

    console.log(`\n${passed} passed, ${failed} failed`);
    if (failed > 0) process.exit(1);
}

run().catch((err) => {
    console.error('Contract test run crashed:', err);
    process.exit(1);
});
