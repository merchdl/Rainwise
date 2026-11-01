"""HTTP API served to the iOS app."""

from __future__ import annotations

import asyncio
import json
import logging
import os
from contextlib import asynccontextmanager
from datetime import datetime, timedelta

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import PlainTextResponse, StreamingResponse

from .service import Collector, Config
from .store import METRICS

log = logging.getLogger(__name__)

# range -> (days before today to start, bucket seconds)
RANGES = {
    "today": (0, 300),
    "48h": (1, 600),
    "week": (6, 1800),
}


def config_from_env() -> Config:
    url = os.environ.get("IP100_URL")
    if not url:
        host = os.environ.get("IP100_HOST", "192.168.11.61")
        url = f"http://{host}/status.xml"
    return Config(
        ip100_url=url,
        db_path=os.environ.get("DB_PATH", "/data/rainwise.db"),
        poll_seconds=float(os.environ.get("POLL_SECONDS", "5")),
        tz=os.environ.get("TZ") or None,
        min_rssi=float(os.environ.get("MIN_RSSI", "-115")),
    )


def create_app(collector: Collector | None = None, token: str | None = None, autostart: bool = True) -> FastAPI:
    token = token if token is not None else os.environ.get("API_TOKEN") or None

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        c = collector or Collector(config_from_env())
        app.state.collector = c
        if autostart:
            log.info("polling %s every %ss", c.cfg.ip100_url, c.cfg.poll_seconds)
            c.start()
        yield
        await c.stop()

    app = FastAPI(title="Rainwise collector", lifespan=lifespan)

    def auth(request: Request) -> None:
        if not token:
            return
        header = request.headers.get("authorization", "")
        supplied = header.removeprefix("Bearer ").strip() or request.query_params.get("token")
        if supplied != token:
            raise HTTPException(status_code=401, detail="bad or missing token")

    def col(request: Request) -> Collector:
        return request.app.state.collector

    @app.get("/api/health")
    def health(request: Request):
        c = col(request)
        p = c.payload()
        return {"ok": p["online"], "signal_ok": p["station"]["signal_ok"], "error": p["error"],
                "updated": p["updated"], "source": c.cfg.ip100_url}

    @app.get("/api/current", dependencies=[Depends(auth)])
    def current(request: Request):
        return col(request).payload()

    @app.get("/api/stream", dependencies=[Depends(auth)])
    async def stream(request: Request):
        c = col(request)
        q = c.subscribe()

        async def events():
            try:
                yield f"data: {json.dumps(c.payload())}\n\n"
                while True:
                    if await request.is_disconnected():
                        break
                    try:
                        data = await asyncio.wait_for(q.get(), timeout=15)
                        yield f"data: {json.dumps(data)}\n\n"
                    except asyncio.TimeoutError:
                        yield ": keepalive\n\n"
            finally:
                c.unsubscribe(q)

        return StreamingResponse(
            events(),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    @app.get("/api/history", dependencies=[Depends(auth)])
    def history(
        request: Request,
        metric: str = Query("temperature", description=", ".join(METRICS)),
        range: str = Query("today", description="today | 48h | week"),
    ):
        if metric not in METRICS:
            raise HTTPException(400, f"metric must be one of {', '.join(METRICS)}")
        if range not in RANGES:
            raise HTTPException(400, f"range must be one of {', '.join(RANGES)}")
        c = col(request)
        days_back, bucket = RANGES[range]
        today = datetime.now(c.tz).date()
        start_dt = datetime.combine(today - timedelta(days=days_back), datetime.min.time(), c.tz)
        end_dt = datetime.combine(today + timedelta(days=1), datetime.min.time(), c.tz)
        start, end = int(start_dt.timestamp()), int(end_dt.timestamp())
        column = METRICS[metric]
        points = c.store.series(column, start, end, bucket)
        lo, hi = c.store.extremes(column, start, end)
        return {
            "metric": metric,
            "range": range,
            "start": start,
            "end": end,
            "bucket": bucket,
            "points": [{"t": t, "v": v} for t, v in points],
            "min": {"t": lo[1], "v": lo[0]} if lo else None,
            "max": {"t": hi[1], "v": hi[0]} if hi else None,
        }

    @app.get("/api/raw", dependencies=[Depends(auth)], response_class=PlainTextResponse)
    async def raw(request: Request):
        """The IP-100's status.xml as-is, for checking field names."""
        try:
            return await col(request).client.fetch_raw()
        except Exception as e:  # noqa: BLE001
            raise HTTPException(502, f"IP-100 unreachable: {e}") from e

    return app
