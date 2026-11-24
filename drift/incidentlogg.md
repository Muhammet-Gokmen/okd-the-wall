# Incident log

Times are local time (CET, UTC+1). Evidence files are in `tester/bevis/`. Each entry records time,
symptoms, hypotheses, evidence, action, verification and a preventive improvement.

---

## Incident 1: database dependency broken (wrong Service selector)

**Test script:** `tester/g-incident1.sh` (evidence `V9-incident1.txt`). **Date:** 2026-11-20.

| Time | Event |
|---|---|
| 17:26:05 | Baseline: both web Pods `READY true`, `RESTARTS 0`; endpoints for `wall-db` and `wall-web` present; Route `HTTP 200` |
| 17:26:06 | Fault: the selector of Service `wall-db` was changed to `app.kubernetes.io/name=wall-db-wrong` |
| 17:26:38 (t+30 s) | Both web Pods `READY false`, **`RESTARTS 0`**; `wall-db` endpoints `<none>`; `wall-web` endpoints empty; Route `HTTP 503` |
| 17:26:38 | Direct `oc port-forward` to a running web Pod: `GET /health` returned 200, `GET /` returned 503 "Database unavailable" |
| 17:27:32 (t+90 s) | Unchanged: not ready, `RESTARTS 0` |
| 17:27:32 | Fix: `oc apply -f manifests/21-db-service.yaml` |
| 17:27:53 | Both Pods ready, Route `HTTP 200`, new message written (`G1-test-172753`), `Messages: 13` |

**Symptoms:** the site returned 503 although every Pod was `Running`; no Pod restarted.

**Hypotheses and how each was decided**

1. *Web Pods crashed or hung.* Rejected: Pods `Running`, `RESTARTS 0`, and `/health` answered 200 through the port-forward.
2. *Database Pod down.* Rejected: `wall-db` Pod `1/1 Running`, labels `app.kubernetes.io/name=wall-db`.
3. *NetworkPolicy blocking the web Pods.* Unlikely: the policy was unchanged since the earlier passing test and selects the database Pods from the web Pods.
4. *Service `wall-db` does not select the database Pod.* **Confirmed:** `Selector: app.kubernetes.io/name=wall-db-wrong`, `Endpoints:` empty, `oc get endpoints wall-db` shows `<none>`; the web log shows `connection failed ... server closed the connection unexpectedly`.

**Deciding evidence:** empty endpoints of `wall-db` together with a healthy database Pod and a
selector that does not match its labels.

**Readiness removal versus container restart:** the readiness probe uses `GET /`, which runs a SQL
query, so it failed as soon as the database could not be reached and Kubernetes removed the Pods from
the Service endpoints (no traffic reaches them, Route has no backends). The liveness probe uses
`/health`, which never touches the database, so it kept passing and the containers were **not**
restarted (`restartCount` stayed 0). Restarting the web Pods would not have helped, since the
fault is outside them.

**Action:** re-applied the Service manifest from Git. **Verification:** endpoints restored, Pods ready,
Route 200, read and write work.

**Prevention:** change cluster objects only by applying Git and check drift regularly with
`oc diff -f manifests/`; alert on a Service with zero endpoints (proposed, not implemented);
validate label selectors against the Pod template in a review or CI step (proposed).

---

## Incident 2: application configuration (wrong `DB_NAME`)

**Test script:** `tester/g-incident2.sh` (evidence `V9-incident2.txt`). **Date:** 2026-11-20.

| Time | Event |
|---|---|
| 17:31:15 | Baseline: two Pods ready, Route `HTTP 200`, `wall-db` endpoint present |
| 17:31:16 | Fault: ConfigMap `wall-config` `DB_NAME=walldb_missing` and `oc rollout restart deploy/wall-web` |
| 17:31:38 (t+20 s) | New Pod `0/1`; the two old Pods ready; Route `HTTP 200` |
| 17:32:43 (t+80 s) | New Pod `RESTARTS 1`; Route `HTTP 200` |
| 17:33:47 (t+140 s) | New Pod `RESTARTS 2`; Route `HTTP 200` |
| 17:33:50 | Fix: ConfigMap applied from Git, `oc rollout restart deploy/wall-web` |
| 17:34:01 | New Pods running; one `HTTP 000` seen while the old Pods were terminating; then a write succeeded (`G2-test-173406`, `Messages: 14`) and the ConfigMap shows `DB_NAME: walldb` |

**Symptoms:** the new Pod never became ready and kept restarting; the site stayed up because the old Pods kept serving.

**Evidence from the new Pod:** log lines `Waiting for database (n/30): connection failed ... FATAL: database "walldb_missing" does not exist`;
previous container ends with `Waiting for database (30/30)` and `RuntimeError: Database could not be initialized`, `Exit Code: 1`
(started 17:32:20, finished 17:33:21, 61 s). Events show `Startup probe failed ... connection refused` on `/health`.

**Hypotheses and how each was decided**

1. *Same fault as incident 1 (Service/selector).* Rejected: `oc get endpoints wall-db` shows `10.128.1.226:5432`, the database Pod is `1/1 Running`, and the server **answered** (the `FATAL` message comes from PostgreSQL), so network, Service and authentication work.
2. *Database down or unreachable.* Rejected for the same reason.
3. *Startup probe kills the Pod.* Rejected: `Last State: Terminated, Reason: Error, Exit Code: 1`. The application exited by itself after 30 attempts (61 s); the probe window is 200 s.
4. *Wrong database name in the configuration.* **Confirmed:** `oc get cm wall-config` shows `DB_NAME: walldb_missing`, and the databases that exist are `postgres` and `walldb`.

**Deciding evidence:** the PostgreSQL message `database "walldb_missing" does not exist`, the list of existing databases, and the ConfigMap value.

**Observed sequence and the difference from incident 1:** the error appears **before the web server
starts**: `start.sh` runs `initialize()` first and, because of `set -e`, the container exits when
it gives up, so Gunicorn never listens. Therefore `/health` does not answer in the new Pod
(in incident 1 it answered 200), the container restarts and goes into `CrashLoopBackOff`
(in incident 1 `restartCount` stayed 0), and the failure message is specific (database name)
instead of a connection error. The Route kept returning 200 because a rolling update does not remove
old Pods until the new Pod is ready.

**Action:** applied the correct ConfigMap and restarted the web Pods (environment variables are read
at process start, so a restart is required). **Verification:** Pods ready, read and write work,
`DB_NAME: walldb`.

**Prevention:** review ConfigMap changes in Git, gate rollouts with `oc rollout status` and roll
back automatically with `oc rollout undo` when it fails (proposed), and consider `minReadySeconds`
and a `preStop` delay to avoid the short `HTTP 000` seen at the end of the rollout (observed, not investigated further).

---

## Unplanned event: database Pod stuck in Pending (insufficient CPU on the nodes)

**Evidence:** `E-olay-yetersiz-cpu.txt`, `E3-kaynak-bosta.txt`. **Date:** 2026-11-20 around 15:00-15:15 (exact timestamps in the evidence files).

**Trigger:** applying the probe changes recreated the database Pod (strategy `Recreate`).

**Symptoms:** `wall-db` Pod `Pending` for more than 8 minutes; the new web Pod in `CrashLoopBackOff`
(no database); the site returned 503 although the data was safe on the PVC.

**Hypotheses:** (1) the new probes fail, (2) volume or zone problem, (3) not enough resources.
**Deciding evidence:** `PodScheduled False` and the event `0/3 nodes are available: 3 Insufficient cpu`.
A Pod that is `Pending` has not started a container, so no probe can have run (rejects 1). The PVC was
`Bound` and the earlier Pod had used the same volume (rejects 2). The scheduler looks at the CPU
**request** (200m), not at real use; the database used about 3m when idle.

**Action:** lowered the database CPU request from 200m to 100m (limit unchanged), applied the
manifest and deleted the back-off web Pod so Kubernetes created a new one without the back-off delay.
**Verification:** the Pod was scheduled within about a minute (`Successfully assigned`, volume attached),
`1/1 Running`, probes passed, `/` returned 200.

**Prevention:** set requests from observations (`oc adm top pods`), watch `FailedScheduling` events,
and keep requests small enough to be rescheduled on a busy shared cluster. Raising the CPU **limit** later
(500m to 1000m after the load test) did not change scheduling because the request stayed at 100m.

---

## Instructor incident session

To be completed after the session: date and time, what the instructor changed, clues, hypotheses tried
(and rejected, with the evidence), the deciding evidence, the fix, the verification, and what I would
improve (monitoring, alerts, runbook).

| Field | Notes |
|---|---|
| Date and time | |
| Symptoms seen | |
| Clues | |
| Hypotheses tried | |
| Deciding evidence | |
| Action | |
| Verification | |
| Help used | |
| Prevention | |
