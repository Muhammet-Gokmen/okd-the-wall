# Verification protocol – The Wall on OKD

Student: Muhammet Gökmen · Project: `student-muhammet-gokmen-lerniastudent-se`
Route: https://wall-web-student-muhammet-gokmen-lerniastudent-se.apps.okd.cloud2.se

All tests were run from the repository checkout (`~/okd-the-wall`). Every evidence file is in
`tester/bevis/` and the scripts are in `tester/`. Times are local time (Europe/Stockholm).
Evidence files without a time stamp inside the file have the time of their Git commit
(`git log --format=%aI -- tester/bevis/<file>`). Passwords and tokens are never written to the
evidence files; the database password exists only in the Secret `wall-db-credentials` (not in Git).
Test data is fictional (`Testperson`, `V2-test-…`, `G1-test-…`).

## Overview

| Test | Requirement | What is verified | Result |
|---|---|---|---|
| V1 | A | Image builds, starts on an empty database, runs as non-root | Pass |
| V2 | B | Route over HTTPS, HTTP redirects to HTTPS, write and read through the Route | Pass |
| V3 | B | NetworkPolicy: only the web Pods can reach the database | Pass |
| V4 | C, D | Non-root/SCC, Secret use, database and PVC state | Pass |
| V5 | C | Password rotation without data loss, old password rejected | Pass |
| V6 | D | Data survives deletion of the database Pod | Pass |
| V7 | E | Probes, resource limits, HPA scale-out and scale-in, bottleneck analysis | Pass |
| V8 | F | Release v1 → v2, failed release, rollback, live state equals Git | Pass |
| V9 | G | Two incidents diagnosed and fixed | Pass |
| V10 | H | Recreation from Git, backup and restore on a new empty volume | Pass |

The V numbers follow the evidence file names. Supplementary evidence without its own V number
(C1, E1–E3, E-olay) is listed under the test it supports.

---

## V1 – Image build and start-up (requirement A)

| | |
|---|---|
| Time | Build: see `V1-build.txt` (commit time) · image references 2026-11-20 16:41:26 · local start-up test 2026-11-24 11:04:29 |
| Command / script | `podman build` (Containerfile in `app/`), `podman push`; local test: block in `tester/bevis/V1-lokal-test.txt` (PostgreSQL image + web image on a podman network); `oc get pod -o jsonpath` for image IDs |
| Expected | Image builds with pinned dependency ranges; container initialises the schema on an empty database and then starts Gunicorn; runs as a non-root UID; `/health` answers; write returns 302; the message can be read back. The cluster runs images referenced by digest. |
| Actual | First attempt reported `Waiting for database (1/30): connection refused` (database still starting), then `Database initialized`, Gunicorn 23.0.0 with 2 sync workers on port 8080. `uid=12345 gid=0`. `/health` returned `{"status":"ok",…}`. POST returned `302 FOUND`; the new message appeared on the page. On the cluster the web Pods run `the-wall:v1` with digest `sha256:c2b7cb0f…de33b0`, the database Pods run `quay.io/kurs/postgresql:2026-10-29` with digest `sha256:5e175093…b640d82f`. |
| Evidence | `V1-build.txt`, `V1-dependencies.txt`, `V1-imageid.txt`, `V1-lokal-test.txt` |
| Note | The local test used the `:v2` image (the app differs from v1 only by the page heading). The locally shown `Digest` (`aa4880ae…`) is podman's local value and differs from the registry digest; the registry digest is the one used in the manifests (see V8). |

## V2 – Route, TLS and traffic (requirement B)

| | |
|---|---|
| Time | 2026-11-19 15:00:39 · TLS re-check 2026-11-24 (see `V2b-tls.txt`) |
| Command / script | `curl -sI http://<route>/`, `curl https://<route>/health`, `curl -k`, `curl -v` certificate lines, `curl -X POST …/post`, read page |
| Expected | HTTP redirects to HTTPS; HTTPS works; the certificate covers the Route host; writing and reading through the Route works. |
| Actual | HTTP gave `302 Found` with `location: https://wall-web-…`. HTTPS returned `{"pod":"wall-web-79c8bb7f57-bgmc8","status":"ok"}`. The message `V2-test-150040` was written and read back. In this first run the certificate check ended with `unable to get local issuer certificate (20), continuing anyway` because `-k` was used, so it did not prove trust. The re-check in `V2b-tls.txt` shows subject `CN=api.okd.cloud2.se`, issuer Let's Encrypt, subject alternative names `*.apps.okd.cloud2.se` and `api.okd.cloud2.se`, valid until 2027-01-05, and `curl` without `-k` gave `verify=0 http=200`. |
| Evidence | `V2-trafik.txt`, `V2b-tls.txt` |

## V3 – NetworkPolicy (requirement B)

| | |
|---|---|
| Time | 2026-11-19 15:08:47 – 15:09:37 |
| Command / script | Test client Pod (`tester/wall-testclient.yaml`) connects to `wall-db:5432` before and after applying `manifests/40-db-networkpolicy.yaml`; the same check from a web Pod |
| Expected | Before the policy the client can connect. After it, only Pods labelled as the web tier can reach the database. |
| Actual | Client → database: exit code 0 before the policy and exit code 1 after. Web Pod → database still works (the application keeps serving). |
| Evidence | `V3-natverk.txt` |

## V4 – Security context, Secret and database state (requirements C, D)

| | |
|---|---|
| Time | `V4-guvenlik.txt` 2026-11-19 15:15:58 · `V4-db-durum.txt` no time stamp in file (commit time, 2026-11-19) |
| Command / script | `oc exec … id`, `oc get pod -o jsonpath` of `securityContext`, `oc get pvc`, `psql \conninfo`, `\dt`, `SELECT` |
| Expected | Pods run as a random non-root UID under the restricted SCC without privilege escalation and with all capabilities dropped; credentials come from the Secret; the database has the table owned by the application user and the PVC is bound. |
| Actual | `uid=1000840000 gid=0 groups=0,1000840000`; `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `runAsUser: 1000840000`. PVC `wall-db-data` is `Bound`, 1Gi, `RWO`, class `gp3-csi`. Connected to `walldb` as `wallapp`; table `public.messages` owned by `wallapp`; rows 1 (`Gokmen`) and 2 (`Testperson`, `V2-test-150040`). |
| Supplementary | `C1-configmap.txt` (2026-11-19 15:14:24): changing the ConfigMap does not reach running Pods; a restart is required, which is why configuration changes go through `oc rollout restart`. |
| Evidence | `V4-guvenlik.txt`, `V4-db-durum.txt`, `C1-configmap.txt` |

## V5 – Password rotation (requirement C)

| | |
|---|---|
| Time | 2026-11-19 15:22:48 – 15:22:59 |
| Command / script | `drift/rotate-password.sh` (order: `ALTER ROLE` in the database, update the Secret, restart the web Deployment), monitor loop in `V5-monitor.txt` |
| Expected | Old password rejected, new password accepted over a network connection, data kept, short and bounded interruption. |
| Actual | Old password denied and new password accepted. During the switch the monitor saw 3 × HTTP 503 and 1 × connection failure (000), about 4 seconds, then normal service. Passwords are not shown in the files. |
| Evidence | `V5-losenord.txt`, `V5-monitor.txt` |
| Note | The test uses a network connection from a web Pod, because the database accepts local socket connections without a password. |

## V6 – Persistence (requirement D)

| | |
|---|---|
| Time | 2026-11-20 14:54:15 – 14:54:17 |
| Command / script | `tester/v6-persistens.sh`: write a message, delete the database Pod, wait for the new Pod, compare |
| Expected | New database Pod, same PVC, same data, all web Pods show the same number of messages. |
| Actual | The database Pod UID changed; the PVC UID `21f1143b…` was unchanged; all rows were kept; every web Pod showed the same count. |
| Evidence | `V6-persistens.txt` |
| Note | The PVC was deliberately recreated later in V10b; the current PVC UID is `c240ac1c-24f1-4f03-b18d-f656c8b216f6`. |

## V7 – Probes, resources and scaling (requirement E)

| | |
|---|---|
| Time | Probes 2026-11-20 15:17:18 · resource incident 15:12:11 · bottleneck tests 15:36:26 – 15:38:35 and 15:51:28 – 15:53:44 · `V7-yuk`, `V7-hpa`, `V7-monitor`, `E3-kaynak-bosta` have no time stamp in the file (commit time, 2026-11-20) |
| Command / script | `tester/loadgen.py` as Job (`tester/wall-loadgen-job.yaml`, at most 8 clients, deadline 300 s), `tester/v7-flaskhals.sh`, `oc get hpa -w`, `oc adm top`, cgroup `cpu.stat` (`nr_throttled`) |
| Expected | Probes keep the Pods healthy without restarts; readiness removes a Pod without a database; under bounded load the HPA scales 2 → 3 and back to 2 without errors; limits and requests are justified by measurement. |
| Actual | All Pods showed restart count 0 after the probe rollout (`E1-E2-probes.txt`). HPA scaled 2 → 3 → 2 with 0 request errors (`V7-hpa.txt`, `V7-yuk.txt`). Bottleneck: with the database CPU limit at 500m the database was throttled about 92 % (884 of 957 CPU periods) and throughput was about 88 requests/s with 8 clients (`V7b-flaskhals.txt`); after raising the limit to 1000m throughput rose to about 127.7 requests/s, database throttling fell to about 6.9 % (68 of 987 periods) and a web Pod became throttled about 72 % (663 of 926 periods) at its 500m limit (`V7c-flaskhals.txt`). The namespace quota (`limits.cpu` 4) prevents raising the web limits further. |
| Incident during the work | A database Pod stayed `Pending` with `0/3 nodes are available: 3 Insufficient cpu` after a rollout; the scheduler decides on requests, so the database request was lowered from 200m to 100m (`E-olay-yetersiz-cpu.txt`, `E3-kaynak-bosta.txt`). |
| Evidence | `E1-E2-probes.txt`, `E3-kaynak-bosta.txt`, `E-olay-yetersiz-cpu.txt`, `V7-yuk.txt`, `V7-hpa.txt`, `V7-monitor.txt`, `V7b-flaskhals.txt`, `V7b-monitor.txt`, `V7c-flaskhals.txt`, `V7c-monitor.txt` |

## V8 – Releases and rollback (requirement F)

| | |
|---|---|
| Time | v1 → v2 rollout 2026-11-20 16:43:12 · image references 17:16:38 · invalid image and rollback 17:17:22 – 17:19:02 · registry digest 17:24:50 · pinned v2 17:37:17 |
| Command / script | `git diff app-v1 app-v2`, `oc rollout status`, `tester/f-rollback.sh` (set a non-existent image tag, observe, `oc rollout undo`), `oc diff -f manifests/` |
| Expected | v2 replaces v1 with the messages kept; a faulty release does not take the application down; rollback restores service; the live state equals Git; images are referenced immutably. |
| Actual | The only code change is the heading `THE WALL_` → `THE WALL_ v2`; messages were preserved. With a non-existent image tag the new Pod went to `ImagePullBackOff` while the old Pods kept serving; `oc rollout undo` created a new revision (revision 9) and service continued. `oc diff -f manifests/` returned exit code 0. After the `:v2` tag had been pushed again and drifted from the version running in the cluster, the manifest was pinned to the registry digest `sha256:ae9c5e8d…a162a` (`V8-registry-digest.txt`, `V8-v2-pinned.txt`). |
| Evidence | `F-v2-diff.txt`, `F-v2-build.txt`, `F-v2-rollout.txt`, `V8-image-referanslari.txt`, `V8-registry-digest.txt`, `V8-v2-pinned.txt`, `V8-rollback.txt` |
| Notes | `V8-v2-pinned.txt` was captured in the middle of a rollout and still shows one Pod from the previous ReplicaSet. `F-v2-diff.txt` and `F-v2-rollout.txt` were committed empty by mistake once and were regenerated from Git. |

## V9 – Incidents (requirement G)

| | |
|---|---|
| Time | Incident 1: 2026-11-20 17:26:05 – 17:27:53 · Incident 2: 17:31:15 – 17:34:01 |
| Command / script | `tester/g-incident1.sh`, `tester/g-incident2.sh` (introduce the fault, observe, diagnose, repair); analysis in `drift/incidentlogg.md` |
| Expected | Each fault shows distinct symptoms; the cause is found from the evidence; the repair restores service; the incident log records symptom, cause, repair, prevention. |
| Actual | **Incident 1** (Service selector `wall-db-wrong`): the Service had no endpoints, readiness failed, restart count stayed 0, `/health` still returned 200 through port-forward; restored in about 1 min 47 s. **Incident 2** (`DB_NAME=walldb_missing` in the ConfigMap): `initialize()` failed before Gunicorn started, each attempt took about 61 s, the new Pod went to `CrashLoopBackOff` while the old Pods kept the Route at 200; repaired by restoring the ConfigMap and restarting. |
| Evidence | `V9-incident1.txt`, `V9-incident2.txt` |
| Note | One `HTTP 000` appeared at the end of the Incident 2 rollout, while the Pods were being replaced. |
| Instructor session | The unexpected fault from the incident session is recorded in `drift/incidentlogg.md` after the session. |

## V10 – Recreation and backup/restore (requirement H)

| | |
|---|---|
| Time | Recreation 2026-11-20 17:38:02 – 17:38:39 · backup/restore 2026-11-24 10:53:07 – 10:53:35 |
| Command / script | `tester/h-recreate.sh` (delete all application objects, keep data volume, apply `manifests/`), `tester/h-backup-restore.sh` (`pg_dump`, verify dump, delete database and PVC, apply `manifests/` with a new empty PVC, restore) |
| Expected | The whole application is rebuilt from Git and the runbook; with the volume kept the data is intact; with a new empty volume the data is restored from the backup. |
| Actual | Recreation took about 36 s; PVC UID unchanged; messages kept (14, then 15 after a new write). Backup/restore: the dump (15 rows, verified before anything was deleted) was taken from PVC `21f1143b…`; after deleting the database and PVC a new empty PVC `c240ac1c-24f1-4f03-b18d-f656c8b216f6` was created from Git; the Route returned 200 with `THE WALL_ v2` and `Messages: 0`; table owner `wallapp`; after the restore 15 rows, max id 15, and a new write gave 16 rows. |
| Evidence | `V10-recreate.txt`, `V10b-backup-restore.txt` |
| Note | The backup file is stored outside Git (`~/okd-arsiv/backup/`). |

---

## Known limitations

- The first TLS check (V2) used `-k`; trust was verified separately in `V2b-tls.txt`.
- `V8-v2-pinned.txt` is a transitional snapshot (see V8).
- Throughput figures in V7 come from short, bounded runs (at most 8 clients, at most 240 s) and show the bottleneck order, not the capacity of the cluster.
- Multi-project rollout methods are described in the report and marked there as tested or proposed.
