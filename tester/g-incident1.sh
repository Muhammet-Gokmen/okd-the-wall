#!/bin/bash
# G / Incident 1: wrong selector on the DB Service. Observations are saved BEFORE the fix.
set -uo pipefail
HOST=$(oc get route wall-web -o jsonpath='{.spec.host}')
WEB=$(oc get pod -l app.kubernetes.io/name=wall-web -o jsonpath='{.items[0].metadata.name}')
state() {
  echo "-- web pods (ready / restartCount):"
  oc get pods -l app.kubernetes.io/name=wall-web -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount --no-headers
  echo "-- endpoints:"
  oc get endpoints wall-db wall-web --no-headers 2>/dev/null
  echo -n "-- route: "; curl -sk -m 5 -o /dev/null -w "HTTP %{http_code}\n" "https://$HOST/"
}

echo "== $(date -Is) BASELINE =="; state

echo "== $(date -Is) FAULT: wrong selector on Service wall-db =="
oc patch svc wall-db --type merge -p '{"spec":{"selector":{"app.kubernetes.io/name":"wall-db-wrong"}}}'
sleep 30
echo "== $(date -Is) t+30s =="; state

echo "-- direct port-forward to running web pod $WEB (bypasses Service/Route)"
oc port-forward pod/$WEB 18080:8080 >/dev/null 2>&1 &
PF=$!; sleep 3
echo -n "GET /health: "; curl -s -m 5 -w " -> HTTP %{http_code}\n" localhost:18080/health
echo -n "GET /:       "; curl -s -m 8 -w " -> HTTP %{http_code}\n" localhost:18080/
kill $PF 2>/dev/null
echo "-- web log (last lines):"; oc logs $WEB --tail=4

echo "-- diagnosis: is the DB pod healthy, and what does the Service select?"
oc get pods -l app.kubernetes.io/name=wall-db --show-labels
oc describe svc wall-db | grep -E "^Selector|^Endpoints"
oc get networkpolicy

sleep 45
echo "== $(date -Is) t+90s (restartCount must still be unchanged) =="; state

echo "== $(date -Is) FIX: re-apply the Service manifest from Git =="
oc apply -f manifests/21-db-service.yaml
sleep 20
echo "== $(date -Is) AFTER FIX =="; state
MSG="G1-test-$(date +%H%M%S)"
curl -sSk -L -d "author=Testperson&message=$MSG" "https://$HOST/post" | grep -o "$MSG"
curl -sk "https://$HOST/" | grep -oE "Messages: [0-9]+"
