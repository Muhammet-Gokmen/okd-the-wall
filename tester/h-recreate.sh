#!/bin/bash
# H / V10: delete Deployments + Services (+ Route, HPA) and recreate them from Git,
# reusing the existing Secret and PVC. The data must survive.
set -uo pipefail
HOST=$(oc get route wall-web -o jsonpath='{.spec.host}')
sql() { oc exec deploy/wall-db -- sh -c "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" $*"; }
pvcuid() { oc get pvc wall-db-data -o jsonpath='{.metadata.uid}'; }

echo "== $(date -Is) 1. BEFORE =="
echo "PVC UID: $(pvcuid)"
sql "-tAc \"SELECT count(*) || ' rows, max id ' || max(id) FROM messages\""
sql "-tAc \"SELECT id || ' ' || message FROM messages ORDER BY id DESC LIMIT 3\""

echo "== $(date -Is) 2. Stop writes, shut the DB down in a controlled way =="
oc delete route wall-web
oc delete hpa wall-web
oc scale deploy/wall-web --replicas=0
oc wait --for=delete pod -l app.kubernetes.io/name=wall-web --timeout=120s
oc scale deploy/wall-db --replicas=0
oc wait --for=delete pod -l app.kubernetes.io/name=wall-db --timeout=120s

echo "== 3. Objects deleted =="
oc get deploy,svc -l app.kubernetes.io/part-of=the-wall -o name
oc delete deploy wall-web wall-db
oc delete svc wall-web wall-db
echo "-- remaining and reused (pvc, secret, configmap, networkpolicy):"
oc get pvc,secret,cm,networkpolicy -l app.kubernetes.io/part-of=the-wall -o name

echo "== $(date -Is) 4. Recreate from Git =="
oc apply -f manifests/

oc rollout status deploy/wall-db --timeout=240s
oc rollout status deploy/wall-web --timeout=240s
oc get deploy,svc,route,hpa,pvc,networkpolicy -l app.kubernetes.io/part-of=the-wall

echo "== $(date -Is) 5. Verify =="
echo "PVC UID: $(pvcuid)"
sql "-tAc \"SELECT count(*) || ' rows, max id ' || max(id) FROM messages\""
sql "-tAc \"SELECT id || ' ' || message FROM messages ORDER BY id DESC LIMIT 3\""
echo -n "route: "; curl -sk -m 10 -o /dev/null -w "HTTP %{http_code}\n" "https://$HOST/"
MSG="H-test-$(date +%H%M%S)"
curl -sSk -L -d "author=Testperson&message=$MSG" "https://$HOST/post" | grep -o "$MSG"
sql "-tAc \"SELECT count(*) || ' rows, max id ' || max(id) FROM messages\""
curl -sk "https://$HOST/" | grep -oE "THE WALL_[^<]*|Messages: [0-9]+"
