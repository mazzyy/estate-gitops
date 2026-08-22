"""checkout-svc — a small service that fails in two realistic, reproducible ways.

This exists to be broken on camera. Both failure modes are real: the process
genuinely exits, the kubelet genuinely restarts it, and the reasons that appear
in `kubectl describe` are genuinely CrashLoopBackOff and OOMKilled. Nothing here
is simulated, because the hackathon requires unedited live execution and a demo
that fakes its own failure proves nothing.

Failure 1 — bad config. PAYMENT_ENDPOINT with an unsupported URL scheme makes
startup validation fail and the process exit 1. The log line it emits is the
one the Diagnostician is expected to find, and it is byte-identical to what
warden/estate/fake.py produces offline, so the agent behaves the same in both.

Failure 2 — OOM. WARMUP_MB above the container memory limit gets the process
killed by the cgroup OOM killer, exit 137.
"""

from __future__ import annotations

import logging
import os
import sys
from urllib.parse import urlparse

from fastapi import FastAPI

VALID_SCHEMES = {"http", "https"}

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "info").upper(),
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("checkout")

VERSION = "1.4.2"
_warm_cache: list[bytearray] = []


def validate_config() -> str:
    """Fail fast and loudly. A service that starts half-configured is worse."""
    endpoint = os.environ.get("PAYMENT_ENDPOINT", "")
    log.info("starting checkout-svc %s", VERSION)
    log.info("config: PAYMENT_ENDPOINT=%s", endpoint)

    scheme = urlparse(endpoint).scheme
    if scheme not in VALID_SCHEMES:
        # This exact string is what the Diagnostician correlates against the
        # deploy that introduced it. Keep it stable — fake.py mirrors it.
        log.critical('FATAL: unsupported URL scheme "%s" in PAYMENT_ENDPOINT', scheme)
        log.info("shutting down after 0.4s")
        sys.exit(1)
    return endpoint


def warm_cache() -> None:
    """Allocate WARMUP_MB. Above the container limit, the cgroup kills us."""
    target_mb = int(os.environ.get("WARMUP_MB", "8"))
    log.info("warming cache (%sMB target)", target_mb)
    for _ in range(target_mb):
        _warm_cache.append(bytearray(1024 * 1024))
    log.info("cache warm: %sMB resident", target_mb)


PAYMENT_ENDPOINT = validate_config()
warm_cache()

app = FastAPI(title="checkout-svc", version=VERSION)


@app.get("/healthz")
def healthz() -> dict:
    return {"status": "ok", "version": VERSION}


@app.get("/")
def root() -> dict:
    return {"service": "checkout-svc", "version": VERSION, "payments": PAYMENT_ENDPOINT}


@app.post("/checkout")
def checkout(amount_cents: int = 0) -> dict:
    if amount_cents <= 0:
        return {"error": "amount_cents must be positive"}
    return {"status": "accepted", "amount_cents": amount_cents, "via": PAYMENT_ENDPOINT}


if __name__ == "__main__":
    import uvicorn

    log.info("listening on :8080")
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level="warning")
