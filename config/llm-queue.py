#!/usr/bin/env python3
"""Per-client queueing gateway for the omallama LLM door.

Sits between the nginx door (:6969 public) and whatever backend serves
127.0.0.1:6969. Contract, from the client's chair:

  - A request is ACCEPTED, never rejected for concurrency. If the client's
    lane cap is reached the request WAITS here until one of that client's
    own in-flight requests finishes, then forwards. Hermes sees one slow
    request, not a 429.
  - If the backend is down (mode switch, watchdog restart, crash) a held
    request keeps waiting and is forwarded the moment it returns — reload
    windows ride out inside the connection.
  - Status reads (/health, /v1/models, /metrics, ...) bypass queueing:
    dashboards must never queue behind generation.

Lanes come from ~/.config/llama-server/llm-limits.json (the same state the
widget edits): {"default": N, "clients": {"ip": N}} — 0 = unlimited, and a
missing client uses `default`. The file is re-read on every request; edits
apply without touching this process.

Only loopback traffic reaches this listener (nginx forwards), so the
X-Forwarded-For header nginx sets is trusted for client identity.
"""
import asyncio
import json
import time
from pathlib import Path

from aiohttp import ClientConnectionError, ClientSession, ClientTimeout, web

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 6962
UPSTREAM = "http://127.0.0.1:6969"
STATE_FILE = Path.home() / ".config/llama-server/llm-limits.json"

LANE_WAIT_CAP_S = 900       # max time a request may wait for one of its client's lanes
ENGINE_UP_CAP_S = 600       # max time to hold a request while the engine is down/reloading
CONNECT_RETRY_S = 2         # reconnect cadence while the engine is down

# Paths that bypass queueing entirely (dashboards, model lists, health).
BYPASS_PREFIXES = ("/health", "/metrics", "/v1/models", "/models", "/props", "/v1/props", "/slots")
HOP_BY_HOP = {"connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "proxy-authenticate", "proxy-authorization"}

_config = {"mtime": 0.0, "default": 0, "clients": {}}
_lanes = {}  # ip -> asyncio.Semaphore (value = lane count)


def load_config() -> tuple[int, dict]:
    try:
        mtime = STATE_FILE.stat().st_mtime
    except OSError:
        mtime = 0.0
    if mtime != _config["mtime"]:
        try:
            raw = json.loads(STATE_FILE.read_text())
            _config["default"] = int(raw.get("default") or 0)
            _config["clients"] = {k: int(v) for k, v in (raw.get("clients") or {}).items()}
            _config["mtime"] = mtime
        except (OSError, ValueError, json.JSONDecodeError) as e:
            print(f"llm-queue: bad state file, keeping previous lanes: {e}", flush=True)
    return _config["default"], _config["clients"]


def lane_for(ip: str) -> int:
    """0 = unlimited. Loopback is the box itself (local Hermes, probes)."""
    if ip in ("127.0.0.1", "::1"):
        return 0
    default, clients = load_config()
    return clients.get(ip, default)


def client_ip(request: web.Request) -> str:
    xff = request.headers.get("X-Forwarded-For", "").split(",")[0].strip()
    if xff:
        return xff
    peer = request.transport.get_extra_info("peername") if request.transport else None
    return peer[0] if peer and peer[0] else "unknown"


async def get_lane_sem(ip: str, lanes: int) -> asyncio.Semaphore:
    sem = _lanes.get(ip)
    if sem is None or getattr(sem, "lanes", None) != lanes:
        sem = asyncio.Semaphore(lanes)
        sem.lanes = lanes
        _lanes[ip] = sem
    return sem


def client_headers(request: web.Request) -> dict:
    out = {}
    for k, v in request.headers.items():
        if k.lower() in HOP_BY_HOP or k.lower() in ("x-forwarded-for", "host"):
            continue
        out[k] = v
    return out


def upstream_headers(resp_status_headers) -> dict:
    out = {}
    for k, v in resp_status_headers.items():
        if k.lower() in HOP_BY_HOP:
            continue
        out[k] = v
    return out


async def forward(request: web.Request, session: ClientSession) -> web.StreamResponse:
    body = await request.read()
    path = request.rel_url.path_qs
    timeout = ClientTimeout(total=None, sock_connect=10, sock_read=None)

    deadline = time.monotonic() + ENGINE_UP_CAP_S
    while True:
        try:
            upstream = await session.request(
                request.method, UPSTREAM + path,
                data=body if body else None,
                headers=client_headers(request),
                timeout=timeout,
            )
            break
        except (OSError, ConnectionError, asyncio.TimeoutError) as e:
            if time.monotonic() >= deadline:
                print(f"llm-queue: {request.remote} {path}: engine still down after {ENGINE_UP_CAP_S}s", flush=True)
                return web.json_response(
                    {"error": {"message": "model reloading — the turn will resume on retry"}},
                    status=503, headers={"Retry-After": "15"})
            if time.monotonic() % 10 < CONNECT_RETRY_S:  # log ~every 5th retry
                print(f"llm-queue: holding {request.remote} {path} (engine down: {type(e).__name__})", flush=True)
            await asyncio.sleep(CONNECT_RETRY_S)

    resp = web.StreamResponse(status=upstream.status, headers=upstream_headers(upstream.headers))
    await resp.prepare(request)
    try:
        async for chunk in upstream.content.iter_any():
            await resp.write(chunk)
        await resp.write_eof()
    except (ConnectionResetError, ClientConnectionError) as e:
        print(f"llm-queue: {request.remote} {path}: stream ended: {type(e).__name__}", flush=True)
        if not resp.prepared:  # nothing sent yet — a short error is better than silence
            return web.json_response({"error": {"message": f"upstream stream failed: {e}"}}, status=502)
    finally:
        upstream.release()
    return resp


async def handle(request: web.Request) -> web.StreamResponse:
    ip = client_ip(request)
    path = request.rel_url.path

    if any(path == p or path.startswith(p + "/") or path.startswith(p + "?") for p in BYPASS_PREFIXES):
        async with ClientSession() as session:
            return await forward(request, session)

    lanes = lane_for(ip)
    started = time.monotonic()
    if lanes > 0:
        sem = await get_lane_sem(ip, lanes)
        waited = None
        try:
            async with asyncio.timeout(LANE_WAIT_CAP_S):
                await sem.acquire()
        except TimeoutError:
            print(f"llm-queue: {ip} {path}: lane wait exceeded {LANE_WAIT_CAP_S}s", flush=True)
            return web.json_response(
                {"error": {"message": "queue wait exceeded — retrying is safe"}},
                status=503, headers={"Retry-After": "30"})
        waited = time.monotonic() - started
        if waited > 0.05:
            print(f"llm-queue: {ip} {path}: queued {waited:.1f}s for a lane", flush=True)
        try:
            async with ClientSession() as session:
                return await forward(request, session)
        finally:
            sem.release()
    else:
        async with ClientSession() as session:
            return await forward(request, session)


def main() -> None:
    app = web.Application(client_max_size=1024 ** 3)
    app.router.add_route("*", "/{tail:.*}", handle)
    print(f"llm-queue: listening on {LISTEN_HOST}:{LISTEN_PORT} -> {UPSTREAM}", flush=True)
    web.run_app(app, host=LISTEN_HOST, port=LISTEN_PORT, print=None, access_log=None)


if __name__ == "__main__":
    main()
