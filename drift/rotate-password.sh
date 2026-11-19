#!/bin/bash
# Rotate the database password (see drift/runbook.md). Never prints passwords.
# Order: 1) ALTER ROLE in the database  2) update Secret  3) restart web.
set -euo pipefail
SECRET=wall-db-credentials
HOST=$(oc get route wall-web -o jsonpath='{.spec.host}')

dbcheck() {  # $1 = password; opens a NEW connection from a web pod to the DB Service
  oc exec -i deploy/wall-web -- env PW="$1" python - <<'PY'
import os, psycopg
try:
    psycopg.connect(host=os.environ["DB_HOST"], port=os.environ["DB_PORT"],
                    dbname=os.environ["DB_NAME"], user=os.environ["DB_USER"],
                    password=os.environ["PW"], connect_timeout=3).close()
    print("OK: connection accepted")
except psycopg.Error as e:
    print("DENIED:", str(e).strip().splitlines()[-1])
PY
}

OLD=$(oc get secret $SECRET -o jsonpath='{.data.password}' | base64 -d)
NEW=$(openssl rand -base64 18 | tr -d '/+=')

umask 077
mkdir -p ~/okd-arsiv
oc get secret $SECRET -o yaml > ~/okd-arsiv/secret-before-rotation.yaml   # rollback copy, outside Git

echo "== $(date -Is) BEFORE: old password =="; dbcheck "$OLD"
echo "== monitor started =="
( while true; do echo "$(date +%T) $(curl -sk -m 3 -o /dev/null -w '%{http_code}' https://$HOST/)"; sleep 1; done ) > tester/bevis/V5-monitor.txt &

MON=$!
sleep 5

echo "== $(date -Is) 1. ALTER ROLE in the database =="
oc exec -i deploy/wall-db -- env NEWPW="$NEW" sh -c 'printf "ALTER ROLE \"%s\" PASSWORD \047%s\047;\n" "$POSTGRES_USER" "$NEWPW" | psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1'
echo "== $(date -Is) 2. Update Secret =="
oc patch secret $SECRET --type merge -p "{\"stringData\":{\"password\":\"$NEW\"}}"
echo "== $(date -Is) 3. Restart web =="
oc rollout restart deploy/wall-web
oc rollout status deploy/wall-web --timeout=180s
echo "== $(date -Is) rotation finished =="
sleep 5
kill $MON 2>/dev/null || true

echo "== AFTER: old password =="; dbcheck "$OLD"
echo "== AFTER: new password =="; dbcheck "$NEW"
echo "== App write + read through the Route =="
MSG="V5-test-$(date +%H%M%S)"
curl -sSk -L -d "author=Testperson&message=$MSG" "https://$HOST/post" | grep "$MSG"
echo "== Earlier messages still present =="
curl -sSk "https://$HOST/" | grep -o "V[0-9]-test-[0-9]*" | sort -u
echo "== Monitor summary (HTTP status: count) =="
awk '{print $2}' tester/bevis/V5-monitor.txt | uniq -c
