# Bounded load generator: repeated GET / through the wall-web Service.
# Max 8 concurrent clients, 5 s request timeout, ramped 2 -> 4 -> 8 clients.
import threading, time, urllib.request

URL = "http://wall-web/"
STAGES = [(2, 45), (4, 60), (8, 120)]   # (clients, seconds) -> 225 s total
TIMEOUT = 5
lock = threading.Lock()

def worker(stop, stats):
    while not stop.is_set():
        t = time.time()
        try:
            with urllib.request.urlopen(URL, timeout=TIMEOUT) as r:
                r.read()
                ok = (r.status == 200)
        except Exception:
            ok = False
        dt = time.time() - t
        with lock:
            stats["n"] += 1
            stats["err"] += (not ok)
            stats["lat"] += dt

for clients, secs in STAGES:
    stop = threading.Event()
    stats = {"n": 0, "err": 0, "lat": 0.0}
    ths = [threading.Thread(target=worker, args=(stop, stats), daemon=True)
           for _ in range(clients)]
    t0 = time.time()
    for t in ths:
        t.start()
    time.sleep(secs)
    stop.set()
    for t in ths:
        t.join(timeout=TIMEOUT + 1)
    el = time.time() - t0
    n = max(stats["n"], 1)
    print(f"{time.strftime('%H:%M:%S')} clients={clients} secs={secs} "
          f"requests={stats['n']} errors={stats['err']} "
          f"rps={stats['n']/el:.1f} avg_latency_ms={stats['lat']/n*1000:.0f}",
          flush=True)
