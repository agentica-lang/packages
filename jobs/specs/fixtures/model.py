"""An independent model of the jobs contract as the memory backend keeps it, for the differential feature.

    python3 model.py SEED COUNT

writes COUNT+1 lines of JSON, `{"req": REQUEST, "reply": REPLY}`: a request of specs/protocol.agc and the reply the
driver must give. The first request starts the backend; the others are random calls on two queues, named leases
(a, b, c, d: some of them stale), and a manual clock. The model uses the standard library only, and none of the
Agentica code: a job waits (ordered by its time, then by insertion) or is leased until a time; a delivery counts at the
fetch; the last attempt that fails or expires is dead; a unique key is held until the job is acked or dead; a lease
token that is not the live one is lost.
"""

import json
import random
import sys

MAX_JOBS = 8
MAX_DEAD = 1000
QUEUES = ["q1", "q2"]
NAMES = ["a", "b", "c", "d"]


class Job:
    def __init__(self, ident, queue, payload, max_attempts, run_at, key, order):
        self.ident = ident
        self.queue = queue
        self.payload = payload
        self.max_attempts = max_attempts
        self.run_at = run_at
        self.key = key
        self.order = order
        self.attempt = 0
        self.token = None
        self.expires = 0


class Model:
    def __init__(self):
        self.now = 0
        self.live = {}
        self.dead = []
        self.keys = {}
        self.order = 1
        self.tokens = 0
        self.leases = {}

    def tick(self):
        expired = [j for j in self.live.values() if j.token is not None and j.expires <= self.now]
        for job in sorted(expired, key=lambda j: (j.expires, j.order)):
            if job.attempt >= job.max_attempts:
                self.kill(job)
            else:
                job.token = None

    def kill(self, job):
        self.finish(job)
        self.dead.append(job)

    def finish(self, job):
        del self.live[job.ident]
        if job.key is not None:
            del self.keys[(job.queue, job.key)]

    def owned(self, name):
        held = self.leases.get(name)
        if held is None:
            return None
        ident, token = held
        job = self.live.get(ident)
        if job is not None and job.token == token:
            return job
        return None

    def enqueue(self, queue, payload, max_attempts, run_in, key):
        if key is not None and (queue, key) in self.keys:
            return "ok %s duplicate" % self.keys[(queue, key)]
        if len(self.live) >= MAX_JOBS:
            return "error jobs.full"
        ident = str(self.order)
        run_at = self.now if run_in == 0 else self.now + run_in
        job = Job(ident, queue, payload, max_attempts, run_at, key, self.order)
        self.order += 1
        self.live[ident] = job
        if key is not None:
            self.keys[(queue, key)] = ident
        return "ok %s" % ident

    def fetch(self, queue, name, lease_ms):
        ready = [j for j in self.live.values() if j.queue == queue and j.token is None and j.run_at <= self.now]
        if not ready:
            return "ok none"
        job = min(ready, key=lambda j: (j.run_at, j.order))
        job.attempt += 1
        self.tokens += 1
        job.token = self.tokens
        job.expires = self.now + lease_ms
        self.leases[name] = (job.ident, job.token)
        return "ok %s attempt %d" % (job.payload, job.attempt)

    def with_lease(self, name, action):
        job = self.owned(name)
        if job is None:
            return "error jobs.lease_lost"
        action(job)
        return "ok"

    def retry(self, job, delay):
        if job.attempt >= job.max_attempts:
            self.kill(job)
        else:
            job.run_at = self.now + delay
            job.token = None

    def release(self, job):
        job.attempt -= 1
        job.token = None

    def extend(self, job, ms):
        job.expires = self.now + ms

    def counts(self, queue):
        mine = [j for j in self.live.values() if j.queue == queue]
        ready = len([j for j in mine if j.token is None and j.run_at <= self.now])
        scheduled = len([j for j in mine if j.token is None and j.run_at > self.now])
        leased = len([j for j in mine if j.token is not None])
        dead = len([j for j in self.dead if j.queue == queue])
        return "ready %d scheduled %d leased %d dead %d" % (ready, scheduled, leased, dead)


def table(**settings):
    return [["setting", "value"]] + [[k, str(v)] for k, v in settings.items() if v is not None]


def main():
    seed, count = int(sys.argv[1]), int(sys.argv[2])
    rng = random.Random(seed)
    model = Model()
    named = []
    payloads = 0
    lines = [({"op": "start", "table": table(max_jobs=MAX_JOBS, max_dead=MAX_DEAD)}, "ok")]
    for _ in range(count):
        model.tick()
        roll = rng.random()
        if roll < 0.28:
            payloads += 1
            queue = rng.choice(QUEUES)
            attempts = rng.choice([1, 2, 3, 5])
            run_in = rng.choice([0, 0, 0, 1000, 5000, 60000])
            key = rng.choice([None, None, "k1", "k2", "k3"])
            req = {
                "op": "enqueue", "queue": queue, "text": "p%d" % payloads,
                "table": table(max_attempts=attempts, run_in_ms=run_in or None, unique_key=key),
            }
            reply = model.enqueue(queue, "p%d" % payloads, attempts, run_in, key)
        elif roll < 0.52:
            queue, name, lease_ms = rng.choice(QUEUES), rng.choice(NAMES), rng.choice([1000, 5000, 30000])
            req = {"op": "fetch", "queue": queue, "name": name, "number": lease_ms}
            reply = model.fetch(queue, name, lease_ms)
            if reply != "ok none" and name not in named:
                named.append(name)
        elif roll < 0.72 and named:
            name = rng.choice(named)
            kind = rng.choice(["ack", "ack", "retry", "release", "kill", "extend"])
            amount = rng.choice([1, 500, 1000, 5000, 60000])
            req = {"op": kind, "name": name}
            if kind in ("retry", "extend"):
                req["number"] = amount
            actions = {
                "ack": model.finish,
                "retry": lambda job: model.retry(job, amount),
                "release": model.release,
                "kill": model.kill,
                "extend": lambda job: model.extend(job, amount),
            }
            reply = model.with_lease(name, actions[kind])
        elif roll < 0.86:
            ms = rng.choice([1, 500, 1000, 1001, 5000, 60000])
            req = {"op": "advance", "number": ms}
            model.now += ms
            reply = "ok"
        else:
            queue = rng.choice(QUEUES)
            req = {"op": "counts", "queue": queue}
            reply = model.counts(queue)
        lines.append((req, reply))
    for req, reply in lines:
        print(json.dumps({"req": req, "reply": reply}))


main()
