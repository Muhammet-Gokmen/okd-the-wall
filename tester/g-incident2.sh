#!/bin/bash
# G / Incident 2: wrong DB_NAME in the web configuration. Observations are saved BEFORE the fix.
set -uo pipefail
HOST=$(oc get route wall-web -o jsonpath='{.spec.host}')
state() {
  oc get pods -l app.kubernetes.io/name=wall-web
  echo -n "-- route: "; curl -sk -m 5 -o /dev/null -w "HTTP %{http_code}\n" "https://$HOST/"
}

echo "== $(date -Is) BASELINE =="; state
oc get endpoints wall-db --no-headers 2>/dev/null

echo "== $(date -Is) FAULT: DB_NAME=walldb_missing in ConfigMap + restart =="
oc patch cm wall-config --type merge -p '{"data":{"DB_NAME":"walldb_missing"}}'
oc rollout restart deploy/wall-web
sleep 20; echo "== $(date -Is) t+20s =="; state
sleep 60; echo "== $(date -Is) t+80s =="; state
sleep 60; echo "== $(date -Is) t+140s =="; state

NEW=$(oc get pods -l app.kubernetes.io/name=wall-web --sort-by=.metadata.creationTimestamp -o name | tail -1)
echo "-- logs of the new pod $NEW (current container):"
oc logs $NEW --tail=8 2>&1
echo "-- logs of the previous container (after a restart):"
oc logs $NEW --previous --tail=6 2>&1
echo "-- events / state of the new pod:"
oc describe $NEW | sed -n '/Last State:/,/Ready:/p;/^Events:/,$p' | tail -25

echo "-- is the DB side healthy? (Service endpoints + pod)"
oc get endpoints wall-db --no-headers 2>/dev/null
oc get pods -l app.kubernetes.io/name=wall-db
echo "-- which databases exist?"
oc exec deploy/wall-db -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT datname FROM pg_database WHERE NOT datistemplate"'
echo "-- configuration the web pods are given:"
oc get cm wall-config -o jsonpath='{.data}{"\n"}'

echo "== $(date -Is) FIX: restore ConfigMap from Git + restart =="
oc apply -f manifests/00-configmap.yaml
oc rollout restart deploy/wall-web
oc rollout status deploy/wall-web --timeout=240s
echo "== $(date -Is) AFTER FIX =="; state
MSG="G2-test-$(date +%H%M%S)"
curl -sSk -L -d "author=Testperson&message=$MSG" "https://$HOST/post" | grep -o "$MSG"
curl -sk "https://$HOST/" | grep -oE "Messages: [0-9]+"
oc get cm wall-config -o jsonpath='{.data}{"\n"}'
