#!/bin/bash
# V7 diagnostic run: 8 clients x 90 s. Measures CPU of ALL pods and the cgroup
# CPU-throttling counters (nr_throttled) of DB, web and load generator.
set -uo pipefail
snap() { echo "[$1] $2"; oc exec "$2" -- sh -c 'cat /sys/fs/cgroup/cpu.stat 2>/dev/null || cat /sys/fs/cgroup/cpu/cpu.stat' | grep -E "nr_periods|nr_throttled|throttled_usec|throttled_time"; }
DB=$(oc get pod -l app.kubernetes.io/name=wall-db -o name | head -1)
WEB=$(oc get pod -l app.kubernetes.io/name=wall-web -o name | head -1)
echo "== $(date -Is) BEFORE =="; snap db $DB; snap web $WEB
oc delete job wall-loadgen --ignore-not-found --wait=true
sed 's/2:45,4:60,8:120/8:90/' tester/wall-loadgen-job.yaml | oc apply -f -
( for i in $(seq 1 14); do
    echo "== $(date +%T)"
    oc get hpa wall-web --no-headers
    oc get hpa wall-web -o jsonpath='{range .status.conditions[*]}{.type}={.status}({.reason}) {end}{"\n"}'
    oc adm top pods --no-headers
    sleep 8
  done ) > tester/bevis/V7b-monitor.txt 2>&1 &
MON=$!
sleep 70
echo "== $(date -Is) DURING (t+70s) =="
LG=$(oc get pod -l app.kubernetes.io/name=wall-loadgen -o name | head -1)
snap loadgen $LG; snap db $DB; snap web $WEB
wait $MON

oc wait --for=condition=complete job/wall-loadgen --timeout=120s
echo "== $(date -Is) AFTER =="; snap db $DB; snap web $WEB
echo "== load generator result =="; oc logs job/wall-loadgen
