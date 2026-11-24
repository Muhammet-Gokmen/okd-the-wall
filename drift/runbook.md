# Runbook: The Wall on OKD

All objects carry the label `app.kubernetes.io/part-of=the-wall` and the prefix `wall-`.
Commands are run from the repository root with `oc` logged in and the right project selected.
Passwords are never written to Git or to evidence files.

| Name | Kind |
|---|---|
| `wall-web` | Deployment, Service (80 to 8080), Route (edge TLS), HPA |
| `wall-db` | Deployment (1 replica, Recreate), Service (5432) |
| `wall-db-data` | PVC, 1 GiB, ReadWriteOnce |
| `wall-config` | ConfigMap (`DB_HOST`, `DB_PORT`, `DB_NAME`) |
| `wall-db-credentials` | Secret (`username`, `password`) |
| `wall-db-allow-web` | NetworkPolicy |

## 1. Build the image

```sh
git checkout app-v2 -- app/app.py
podman build --build-arg SOURCE_COMMIT=caa199b60b0218675bc2156f0dff00131d464512+okd-the-wall-<commit> \
  -t docker.io/<user>/the-wall:v2 app/
podman run --rm docker.io/<user>/the-wall:v2 cat /app/requirements.lock.txt   # dependency versions
podman push docker.io/<user>/the-wall:v2
```

Read the registry digest back and pin it in `manifests/30-web-deployment.yaml`
(`image: ...:v2@sha256:<digest>`). Never push a different build to an existing tag that is already
in use; use a new tag.

## 2. Install

```sh
oc create secret generic wall-db-credentials --from-literal=username=<user> --from-literal=password="<password>"
oc label secret wall-db-credentials app.kubernetes.io/part-of=the-wall
oc apply -f manifests/
oc rollout status deploy/wall-db --timeout=300s
oc rollout status deploy/wall-web --timeout=300s
```

## 3. Verify

```sh
HOST=$(oc get route wall-web -o jsonpath='{.spec.host}')
curl -sI "http://$HOST" | head -3                                  # redirect to https
curl -sk "https://$HOST/health"                                     # status ok
MSG="verify-$(date +%H%M%S)"
curl -sSk -L -d "author=Test&message=$MSG" "https://$HOST/post" | grep "$MSG"
oc get pods,pvc,hpa,networkpolicy -l app.kubernetes.io/part-of=the-wall
oc exec deploy/wall-db -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT count(*) FROM messages"'
```

Network isolation (see `tester/wall-testclient.yaml`): from a pod with other labels,
`wget -qO- -T 5 http://wall-web/health` works and `nc -w 5 wall-db 5432 </dev/null` fails
(exit 1 after 5 s).

## 4. Change the database password

The database image reads `POSTGRES_PASSWORD` **only when it initialises an empty data directory**.
Changing the Secret alone does not change the password the database accepts. Order of work:

1. change the password inside PostgreSQL (`ALTER ROLE`),
2. update the Secret,
3. restart the web Pods (environment variables are read when the process starts).

Between step 1 and the end of step 3 the old web processes cannot open new connections: planned
downtime, measured at about 4 seconds (`tester/bevis/V5-monitor.txt`).

```sh
bash drift/rotate-password.sh 2>&1 | tee tester/bevis/V5-losenord.txt   # does all three steps and checks them
```

Manual form:

```sh
oc get secret wall-db-credentials -o yaml > ~/okd-arsiv/secret-before-rotation.yaml   # rollback copy, NOT in Git
NEW=$(openssl rand -base64 18 | tr -d '/+=')
oc exec -i deploy/wall-db -- env NEWPW="$NEW" sh -c \
  'printf "ALTER ROLE \"%s\" PASSWORD \047%s\047;\n" "$POSTGRES_USER" "$NEWPW" | psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1'
oc patch secret wall-db-credentials --type merge -p "{\"stringData\":{\"password\":\"$NEW\"}}"
oc rollout restart deploy/wall-web && oc rollout status deploy/wall-web
```

Check with **new connections over the network** (a local `psql` inside the database Pod uses
trust authentication and would not prove anything): the script opens a connection from a web Pod
to `wall-db:5432` with the old password (must be denied) and with the new one (must work), then
writes and reads a message.

Rollback: `ALTER ROLE` back to the old password (from the saved Secret), restore the saved Secret
with `oc apply -f ~/okd-arsiv/secret-before-rotation.yaml`, then `oc rollout restart deploy/wall-web`.
The database Pod keeps the old value in its `POSTGRES_PASSWORD` environment variable until it is
restarted next time; this has no effect on a database that is already initialised.

## 5. Troubleshooting

Start with the same four questions every time:

```sh
oc get pods -l app.kubernetes.io/part-of=the-wall          # Running? Ready? RESTARTS?
oc get endpoints wall-db wall-web                          # does each Service have backends?
oc logs <pod> [--previous]                                 # what does the process say?
oc get events --sort-by=.lastTimestamp | tail -20          # what does the cluster say?
```

| Symptom | Likely cause | Check and fix |
|---|---|---|
| Route answers 503 "Application is not available", web Pods Running but `READY 0/1`, `RESTARTS 0` | database not reachable from the web Pods; readiness (`GET /`) fails, liveness (`/health`) still passes | `oc get endpoints wall-db`: empty means the Service selector does not match the Pod labels (`oc describe svc wall-db`, compare `oc get pod --show-labels`). Re-apply `manifests/21-db-service.yaml`. Reach a Pod directly with `oc port-forward pod/<web> 18080:8080` and compare `/health` and `/` |
| New web Pod `CrashLoopBackOff`, `/health` refuses connections, old Pods still serve | the process stops in `initialize()` before Gunicorn starts. Log shows `database "<name>" does not exist` | the ConfigMap `DB_NAME` is wrong: `oc get cm wall-config -o jsonpath='{.data}'`, list databases with `psql ... SELECT datname FROM pg_database`. Apply the ConfigMap from Git and `oc rollout restart deploy/wall-web` |
| Log shows `password authentication failed` | Secret and the password inside PostgreSQL differ (interrupted rotation) | follow the rollback in section 4 |
| Pod `Pending`, event `Insufficient cpu` | no node has room for the Pod's CPU **request** | `oc describe quota`, lower the request to what is observed (`oc adm top pods`), see the unplanned event in `incidentlogg.md` |
| Pod `ImagePullBackOff`, event `manifest unknown` | image tag or digest does not exist, or the repository is private | check the reference in the Deployment, `oc describe pod` events |
| HPA shows `<unknown>` | metrics not yet available or no CPU request on the Pods | wait 30-60 s, `oc describe hpa wall-web` |
| Rollout stuck (`UP-TO-DATE` lower than `READY`) | new ReplicaSet cannot become ready; old Pods keep serving | `oc rollout status`, `oc get rs`, `oc describe pod` of the new Pod, then roll back (section 6) |

## 6. Roll back a release

```sh
oc rollout history deploy/wall-web
oc rollout undo deploy/wall-web                      # previous revision, or --to-revision=<n>
oc rollout status deploy/wall-web
oc diff -f manifests/30-web-deployment.yaml; echo $?  # 0 = the live Deployment equals Git
```

If you roll back to an image that is not the one in Git, update the manifest in Git afterwards so
Git again describes what runs. Do not run `oc apply` while a load test is running (it resets
`replicas` to the manifest value and fights the HPA).

## 7. Restart with the data volume preserved

Stop writes first, shut the database down in a controlled way, delete Deployments and Services,
and recreate them from Git. The PVC, Secret, ConfigMap and NetworkPolicy stay.

```sh
bash tester/h-recreate.sh 2>&1 | tee tester/bevis/V10-recreate.txt
```

Manually: `oc delete route wall-web hpa/wall-web`, `oc scale deploy/wall-web --replicas=0`,
`oc scale deploy/wall-db --replicas=0`, wait for the Pods to disappear, `oc delete deploy wall-web wall-db`,
`oc delete svc wall-web wall-db`, then `oc apply -f manifests/`. Check that the PVC UID and the row
count are unchanged and that a new message can be written. Tested: about 36 seconds without service.

## 8. Backup, and a fresh start on a new empty volume

Backup (logical dump, plain SQL; keep the file **outside** Git and outside the cluster):

```sh
mkdir -p ~/okd-arsiv/backup
oc exec deploy/wall-db -- sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --no-privileges' \
  > ~/okd-arsiv/backup/wall-$(date +%Y%m%d-%H%M%S).sql
grep -c "^COPY public.messages" ~/okd-arsiv/backup/wall-*.sql ; tail -2 ~/okd-arsiv/backup/wall-*.sql   # must end with "dump complete"
```

Restore into a running database:

```sh
oc exec -i deploy/wall-db -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q' < ~/okd-arsiv/backup/wall-<timestamp>.sql
```

Fresh start on a new empty PVC (also what a new project does): delete the web Deployment/HPA, the
database Deployment and the PVC `wall-db-data`, then `oc apply -f manifests/`. PostgreSQL initialises
the empty volume with the Secret's credentials, the web Pods create the table, the page shows
"Messages: 0". Restore the backup as above. The whole sequence is scripted and was tested:

```sh
bash tester/h-backup-restore.sh 2>&1 | tee tester/bevis/V10b-backup-restore.txt
```

**Proposed, not tested:** a scheduled `pg_dump` (CronJob) writing to storage outside the cluster,
regular restore tests, and a retention policy. A PVC alone does not protect against deleting the
volume or losing the storage.

## 9. Clean up test objects

```sh
oc delete job wall-loadgen --ignore-not-found
oc delete pod wall-testclient --ignore-not-found
oc delete cm wall-loadgen --ignore-not-found
# make sure no intentional fault is left
oc get cm wall-config -o jsonpath='{.data}{"\n"}'                 # DB_NAME must be walldb
oc get svc wall-db -o jsonpath='{.spec.selector}{"\n"}'           # must select app.kubernetes.io/name=wall-db
oc get deploy wall-web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
oc diff -f manifests/; echo "oc diff exit code: $?"
```
