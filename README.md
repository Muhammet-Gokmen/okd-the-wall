# The Wall on OKD

Individual hand-in for the container technology course: build, run and operate *The Wall*
(a Flask message board backed by PostgreSQL) on the course OKD 4.22 cluster.

| | |
|---|---|
| **Name** | Muhammet Gökmen |
| **OKD user / project** | `muhammet.gokmen@lerniastudent.se` / `student-muhammet-gokmen-lerniastudent-se` |
| **Route (HTTPS)** | https://wall-web-student-muhammet-gokmen-lerniastudent-se.apps.okd.cloud2.se |
| **Git repository** | https://github.com/Muhammet-Gokmen/okd-the-wall |
| **Upstream source** | https://github.com/jonasbjork/the-wall, commit `caa199b60b0218675bc2156f0dff00131d464512` |

## Architecture

```
Browser --HTTPS--> Route (edge TLS, HTTP->HTTPS redirect)
        --HTTP---> Service wall-web :80  -> Pods wall-web :8080 (Flask/Gunicorn, HPA 2-3 replicas)
        --5432---> Service wall-db  :5432 -> Pod wall-db (PostgreSQL 16, 1 replica, strategy Recreate)
                                              `-> PVC wall-db-data (1 GiB, ReadWriteOnce)
NetworkPolicy wall-db-allow-web: only wall-web Pods may open TCP 5432 on wall-db
```

## Own changes to the upstream code

* `app/Containerfile`, `app/start.sh` (new): packaging and start-up. `start.sh` first runs
  `initialize()` (retries until the database is reachable, then creates the table) and then
  `exec`s Gunicorn on `0.0.0.0:8080` (2 sync workers, `GUNICORN_WORKERS` changes it). If
  `initialize()` gives up (30 attempts) the container exits before Gunicorn has started.
* `app/app.py`: **v1 is the unmodified upstream file.** **v2** changes one line:
  `<h1>THE WALL_</h1>` becomes `<h1>THE WALL_ v2</h1>`
  (`tester/bevis/F-v2-diff.txt`, git tags `app-v1` and `app-v2`).

## Images and versions

| Component | Reference | Notes |
|---|---|---|
| Web v1 | `docker.io/muhammetgokmen/the-wall:v1`, digest `sha256:c2b7cb0f1b408d3b50025d42f5da6f0bd398895b4d5f2bcf41dd8c756dde33b0` | unmodified upstream code, public image |
| Web v2 (deployed) | `docker.io/muhammetgokmen/the-wall:v2@sha256:ae9c5e8d5fd1e99da1fa1ac31d79b7200fe752db559e59e3dde2f5936f4a162a` | v1 plus the header marker. The `v2` tag was rebuilt once by mistake (same source, digest `038b7193...` became `ae9c5e8d...`), so the manifest pins the digest |
| Database | `quay.io/kurs/postgresql:2026-10-29` | PostgreSQL 16.15. Image user is 1001, OKD assigns a random UID from the project range. Data directory `/var/lib/postgresql/data` (PGDATA is the sub-directory `pgdata`) |
| Base image | `docker.io/library/python:3.12-slim` | amd64, matches the cluster nodes |
| Python dependencies (built image) | Flask 3.1.3, psycopg 3.3.9 (+ psycopg-binary 3.3.9), gunicorn 23.0.0, Werkzeug 3.1.9, Jinja2 3.1.6, click 8.5.1, blinker 1.9.0, itsdangerous 2.2.0, MarkupSafe 3.0.4, packaging 26.3, typing_extensions 4.16.0 | complete list: `tester/bevis/V1-dependencies.txt` |

Registry: Docker Hub (public). The registry digests were read back in
`tester/bevis/V8-registry-digest.txt`.

## Repository layout

```
app/            app.py, requirements.txt, Containerfile, start.sh
manifests/      00 ConfigMap, 10 PVC, 20/21 DB Deployment + Service,
                30/31/32 web Deployment + Service + Route, 40 NetworkPolicy, 50 HPA
tester/         verifieringsprotokoll.md, bevis/ (raw evidence), test scripts,
                test client and load generator
drift/          runbook.md, incidentlogg.md, rotate-password.sh
rapport/        projektrapport.pdf
```

Secrets are never stored in Git; the Secret is created with the command below.

## Install (reproduce the environment in your own project)

Requirements: `oc` logged in to OKD 4.22 with the target project selected.

```sh
oc project <your-project>

# 1. Database credentials: choose your OWN username and password.
#    They are used by the web app (DB_USER/DB_PASSWORD) and by the database image
#    (POSTGRES_USER/POSTGRES_PASSWORD).
oc create secret generic wall-db-credentials \
  --from-literal=username=<db-user> \
  --from-literal=password="<choose-a-password>"
oc label secret wall-db-credentials app.kubernetes.io/part-of=the-wall

# 2. Everything else: ConfigMap, PVC, Deployments, Services, Route, NetworkPolicy, HPA
oc apply -f manifests/
oc rollout status deploy/wall-db  --timeout=300s
oc rollout status deploy/wall-web --timeout=300s

# 3. Address
oc get route wall-web -o jsonpath='https://{.spec.host}{"\n"}'
```

A new, empty PVC (`wall-db-data`, 1 GiB, ReadWriteOnce) is created automatically. On the first
start PostgreSQL is initialised with the Secret's username and password and the database
`walldb`; the web Pods create the `messages` table themselves. The database image reads the
credentials **only at first initialisation**, so later password changes follow the procedure in
`drift/runbook.md`. If the project still has a PVC from an earlier run, delete it first to get a
truly empty start. The default storage class is used (`gp3-csi` on this cluster).

## Verify

```sh
HOST=$(oc get route wall-web -o jsonpath='{.spec.host}')
curl -sI  "http://$HOST" | head -3                       # redirect to https
curl -sk  "https://$HOST/health"                         # {"pod":"...","status":"ok"}
curl -sSk -L -d "author=Test&message=Hello fictional" "https://$HOST/post" | grep "Hello fictional"
oc get pods,pvc,hpa,networkpolicy,route -l app.kubernetes.io/part-of=the-wall
```

## Build the images

```sh
# v1: unmodified upstream source
git checkout app-v1 -- app/app.py
podman build --build-arg SOURCE_COMMIT=caa199b60b0218675bc2156f0dff00131d464512 \
  -t docker.io/<user>/the-wall:v1 app/
# v2: v1 plus the header marker
git checkout app-v2 -- app/app.py
podman build --build-arg SOURCE_COMMIT=caa199b60b0218675bc2156f0dff00131d464512+okd-the-wall-<commit> \
  -t docker.io/<user>/the-wall:v2 app/
podman push docker.io/<user>/the-wall:v2
```

Put the pushed image's **registry digest** in `manifests/30-web-deployment.yaml` (a tag can be
moved, a digest cannot). The running image ID can be read with
`oc get pod -l app.kubernetes.io/name=wall-web -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'`.

## Configuration summary

| Object | Purpose |
|---|---|
| ConfigMap `wall-config` | `DB_HOST=wall-db`, `DB_PORT=5432`, `DB_NAME=walldb` (read when the process starts, so a change needs a restart of the web Pods) |
| Secret `wall-db-credentials` | `username`, `password` for both web and database |
| Deployment `wall-web` | 2 replicas (HPA 2-3, 50 % of the CPU request), requests 100m / 128Mi, limits 500m / 256Mi, startup + liveness on `/health`, readiness on `GET /` |
| Deployment `wall-db` | 1 replica, strategy Recreate, requests 100m / 256Mi, limits 1000m / 512Mi, probes with `pg_isready` and `SELECT 1` |
| PVC `wall-db-data` | 1 GiB, ReadWriteOnce, mounted at `/var/lib/postgresql/data` |
| NetworkPolicy `wall-db-allow-web` | ingress to the database Pods only from `wall-web` Pods on TCP 5432 |
| Security | both Pods run non-root with a random UID (SCC `restricted-v2`), `allowPrivilegeEscalation: false`, all capabilities dropped, `RuntimeDefault` seccomp |

## Where to find what

* Tests (command, expected and actual result, evidence file): `tester/verifieringsprotokoll.md`,
  raw output in `tester/bevis/`.
* Operations (build, install, verify, password change, troubleshooting, rollback, restart with a
  preserved volume, fresh start): `drift/runbook.md`.
* Two required incidents and one unplanned event: `drift/incidentlogg.md`.
* Report: `rapport/projektrapport.pdf`.
