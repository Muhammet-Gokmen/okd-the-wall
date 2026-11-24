#!/bin/bash
# H3 / D5: logical backup -> verify -> delete DB + PVC -> fresh start on a NEW EMPTY PVC -> restore.
set -uo pipefail
HOST=$(oc get route wall-web -o jsonpath='{.spec.host}')
BK=~/okd-arsiv/backup; mkdir -p "$BK"; umask 077
F="$BK/wall-$(date +%Y%m%d-%H%M%S).sql"
sql() { oc exec deploy/wall-db -- sh -c "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" $*"; }
pvcuid() { oc get pvc wall-db-data -o jsonpath='{.metadata.uid}'; }

echo "== $(date -Is) 1. Backup (pg_dump, plain SQL) =="
echo "PVC UID: $(pvcuid)"
sql "-tAc \"SELECT count(*) FROM messages\""
oc exec deploy/wall-db -- sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --no-privileges' > "$F"
ls -l "$F"
echo "-- verify the backup before touching anything:"
if ! grep -q "PostgreSQL database dump complete" "$F" || ! grep -q "^COPY public.messages" "$F"; then
  echo "BACKUP INVALID - aborting, nothing was deleted"; exit 1
fi
echo "rows in dump: $(awk '/^COPY public.messages/{f=1;next} /^\\\./{f=0} f' "$F" | wc -l)"
echo "backup OK: $F"

echo "== $(date -Is) 2. Delete DB + PVC (data volume lost) =="
oc delete hpa wall-web
oc scale deploy/wall-web --replicas=0
oc wait --for=delete pod -l app.kubernetes.io/name=wall-web --timeout=120s
oc delete deploy wall-db
oc wait --for=delete pod -l app.kubernetes.io/name=wall-db --timeout=120s
oc delete pvc wall-db-data
oc get pvc 2>&1


echo "== $(date -Is) 3. Fresh start from Git: new EMPTY PVC =="
oc apply -f manifests/
oc rollout status deploy/wall-db --timeout=300s
oc rollout status deploy/wall-web --timeout=300s
echo "NEW PVC UID: $(pvcuid)"
echo -n "route: "; curl -sk -m 10 -o /dev/null -w "HTTP %{http_code}\n" "https://$HOST/"
curl -sk "https://$HOST/" | grep -oE "THE WALL_[^<]*|Messages: [0-9]+"
sql "-c \"\\dt\" -tAc \"SELECT count(*) FROM messages\""

echo "== $(date -Is) 4. Restore from the backup =="
oc exec -i deploy/wall-db -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q' < "$F"
sql "-tAc \"SELECT count(*) || ' rows, max id ' || max(id) FROM messages\""
sql "-tAc \"SELECT id || ' ' || message FROM messages ORDER BY id DESC LIMIT 3\""
curl -sk "https://$HOST/" | grep -oE "Messages: [0-9]+"
MSG="R-test-$(date +%H%M%S)"
curl -sSk -L -d "author=Testperson&message=$MSG" "https://$HOST/post" | grep -o "$MSG"
sql "-tAc \"SELECT count(*) || ' rows (after a new write)' FROM messages\""
