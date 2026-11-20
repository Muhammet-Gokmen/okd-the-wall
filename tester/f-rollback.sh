#!/bin/bash
# V8 part 2: working revision -> deliberately invalid image -> investigate -> rollback.
set -uo pipefail
HOST=$(oc get route wall-web -o jsonpath='{.spec.host}')
rev() { oc get deploy wall-web -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}'; }

echo "== $(date -Is) 1. Working revision (v2) =="
WORKING=$(rev); echo "revision=$WORKING"
oc get deploy wall-web -o jsonpath='image={.spec.template.spec.containers[0].image}{"\n"}'
oc rollout history deploy/wall-web --revision=$WORKING | head -12

echo "== $(date -Is) 2. Deploy an intentionally invalid image =="
oc set image deploy/wall-web web=docker.io/muhammetgokmen/the-wall:v999-does-not-exist
sleep 60
echo "-- rollout status (expected to stall)"
oc rollout status deploy/wall-web --timeout=30s
echo "-- deployment / replicasets / pods"
oc get deploy wall-web
oc get rs -l app.kubernetes.io/name=wall-web
oc get pods -l app.kubernetes.io/name=wall-web
echo "-- why: events of the stuck pod"
BAD=$(oc get pods -l app.kubernetes.io/name=wall-web --no-headers | awk '/ImagePull|ErrImage/{print $1; exit}')
oc describe pod "$BAD" | sed -n '/Events:/,$p'
echo "-- site still served by the old pods?"
curl -sk -o /dev/null -w "HTTP %{http_code}\n" "https://$HOST/"
curl -sk "https://$HOST/" | grep -oE "THE WALL_[^<]*"
echo "-- deployment conditions"
oc get deploy wall-web -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'

echo "== $(date -Is) 3. Roll back =="

oc rollout undo deploy/wall-web
oc rollout status deploy/wall-web --timeout=240s
echo "revision now: $(rev)"
oc get deploy wall-web -o jsonpath='image={.spec.template.spec.containers[0].image}{"\n"}'
oc get pods -l app.kubernetes.io/name=wall-web -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].image}{"\n  imageID: "}{.status.containerStatuses[0].imageID}{"\n"}{end}'

echo "== 4. Verify: function, write, previous data =="
curl -sk "https://$HOST/" | grep -oE "THE WALL_[^<]*|Messages: [0-9]+"
MSG="F-test-$(date +%H%M%S)"
curl -sSk -L -d "author=Testperson&message=$MSG" "https://$HOST/post" | grep -o "$MSG"
curl -sk "https://$HOST/" | grep -oE "Messages: [0-9]+"
curl -sk "https://$HOST/" | grep -o "V6-[0-9]*-[0-9]" | sort -u | head -3
echo "-- live Deployment vs manifest in Git (empty diff = identical)"
oc diff -f manifests/30-web-deployment.yaml; echo "oc diff exit code: $?"
