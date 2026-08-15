#!/bin/bash
# Ships each new structured access-log line to the observability stack's
# ingest endpoint, in addition to it staying in the local rotated file.
# Mirrors mule-weather-api/docker-entrypoint.sh -- same INGEST_URL/TOKEN,
# same shared observability stack. Only forwards lines written from here
# on (-n0), so a container restart doesn't re-ship old history.
# INGEST_URL/INGEST_TOKEN are optional -- the app runs fine without them,
# it just stays local-only (this is also how local dev / ace-local-test
# testing runs, pointed at the local obs stack instead of production).
set -e

. /opt/ibm/ace/server/bin/mqsiprofile

mkdir -p /home/aceuser/ace-server/logs
touch /home/aceuser/ace-server/logs/currency-api-access.json.log

if [ -n "$INGEST_URL" ] && [ -n "$INGEST_TOKEN" ]; then
  ( tail -F -n0 /home/aceuser/ace-server/logs/currency-api-access.json.log 2>/dev/null | while IFS= read -r line; do
      curl -s -o /dev/null --max-time 5 -X POST "$INGEST_URL" \
        -H "Content-Type: application/json" \
        -H "X-Ingest-Token: $INGEST_TOKEN" \
        -d "$line" || true
    done ) &
fi

exec IntegrationServer --name "${ACE_SERVER_NAME}" -w /home/aceuser/ace-server
