#!/bin/bash
# V6: persistence. Writes 3 unique messages, deletes ONLY the DB Pod,
# checks data + PVC UID, then checks that all web Pods show the same data.
set -euo pipefail
HOST=$(oc get route wall-web -o jsonpath='{.spec.host}')
sql() { oc exec deploy/wall-db -- sh -c "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" $*"; }
dbpod()  { oc get pod -l app.kubernetes.io/name=wall-db -o jsonpath='{.items[0].metadata.name}'; }
webinfo() {
  for P in $(oc get pod -l app.kubernetes.io/name=wall-web -o jsonpath='{.items[*].metadata.name}'); do
    IP=$(oc get pod $P -o jsonpath='{.status.podIP}')
    echo "-- $P ($IP)"
    oc exec wall-testclient -- wget -qO- -T 5 "http://$IP:8080/" | grep -oE 'Pod: <span class="pod">[^<]*|Messages: [0-9]+' || true
  done
}

TAG="V6-$(date +%H%M%S)"
echo "== $(date -Is) 1. Write 3 unique messages =="
for N in 1 2 3; do
  curl -sSk -L -d "author=Testperson&message=$TAG-$N" "https://$HOST/post" | grep -o "$TAG-$N" | head -1
done

echo "== 2. SQL: messages stored in table messages =="
sql "-c \"SELECT count(*) AS total FROM messages\" -c \"SELECT id, author, message FROM messages WHERE message LIKE 'V6-%' ORDER BY id\""

echo "== 3. UIDs BEFORE deleting the DB Pod =="
OLDPOD=$(dbpod)
echo "DB Pod:  $OLDPOD  UID=$(oc get pod $OLDPOD -o jsonpath='{.metadata.uid}')"
echo "PVC:     wall-db-data  UID=$(oc get pvc wall-db-data -o jsonpath='{.metadata.uid}')"

echo "== $(date -Is) 4. Delete ONLY the DB Pod =="

oc delete pod $OLDPOD --wait=true
oc wait --for=condition=Available deploy/wall-db --timeout=180s
until oc exec deploy/wall-db -- pg_isready -q; do sleep 2; done

echo "== 5. UIDs AFTER =="
NEWPOD=$(dbpod)
echo "DB Pod:  $NEWPOD  UID=$(oc get pod $NEWPOD -o jsonpath='{.metadata.uid}')"
echo "PVC:     wall-db-data  UID=$(oc get pvc wall-db-data -o jsonpath='{.metadata.uid}')"
sql "-c \"SELECT count(*) AS total FROM messages\" -c \"SELECT id, author, message FROM messages WHERE message LIKE 'V6-%' ORDER BY id\""

echo "== 6. Delete one web Pod; the new Pod must read the same data =="
WEBPOD=$(oc get pod -l app.kubernetes.io/name=wall-web -o jsonpath='{.items[0].metadata.name}')
oc delete pod $WEBPOD --wait=true
oc wait --for=condition=Available deploy/wall-web --timeout=180s
sleep 5
echo "== 7. Every web Pod shows the same data =="
webinfo
curl -sSk "https://$HOST/" | grep -o "$TAG-[0-9]" | sort -u
