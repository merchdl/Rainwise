"""Polling loop, minute aggregation, today's extremes and the live payload."""

from __future__ import annotations

import asyncio
import logging
import math
import time
from collections import deque
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from statistics import fmean
from zoneinfo import ZoneInfo

from . import derived
from .ip100 import IP100Client, Sample
from .store import METRICS, Store

log = logging.getLogger(__name__)

# Metrics whose daily min/max the console's MAX/MIN buttons show.
EXTREME_METRICS = [
    "temperature",
    "inside_temperature",
    "humidity",
    "pressure",
    "wind_speed",
    "gust",
    "wind_chill",
    "dew_point",
    "thi",
    "rain",
]

WIND_TRAIL_SECONDS = 600  # recent wind directions shown as dim LEDs


@dataclass
class Config:
    ip100_url: str
    db_path: str = "/data/rainwise.db"
    poll_seconds: float = 5.0
    tz: str | None = None
    # Below this RSSI (dBm), or at signal quality 0, the IP-100 is not hearing
    # the station. (Firmware 1083 doesn't report signal in status.xml, so this
    # only applies to firmware that does.)
    min_rssi: float = -115.0
    # If outside temperature, pressure, wind and rain all stay exactly the
    # same for this long, assume the IP-100 has stopped hearing the station
    # and is repeating its last values. Those readings are not stored.
    stale_minutes: float = 30.0


def _row_from_sample(s: Sample) -> dict[str, float | None]:
    return {
        "out_temp": s.out_temp,
        "in_temp": s.in_temp,
        "humidity": s.humidity,
        "pressure": s.pressure,
        "wind_speed": s.wind_speed,
        "wind_dir": s.wind_dir,
        "gust_speed": s.gust_speed if s.gust_speed is not None else s.wind_speed,
        "gust_dir": s.gust_dir if s.gust_dir is not None else s.wind_dir,
        "rain_day": s.rain_day,
        "solar": s.solar,
        "battery": s.battery,
        "wind_chill": derived.wind_chill_f(s.out_temp, s.wind_speed),
        "dew_point": derived.dew_point_f(s.out_temp, s.humidity),
        "thi": derived.heat_index_f(s.out_temp, s.humidity),
    }


def _vector_mean_dir(rows: list[dict]) -> float | None:
    """Speed-weighted vector average of wind direction."""
    x = y = 0.0
    n = 0
    for r in rows:
        d, sp = r.get("wind_dir"), r.get("wind_speed")
        if d is None:
            continue
        w = sp if sp else 0.01
        x += w * math.sin(math.radians(d))
        y += w * math.cos(math.radians(d))
        n += 1
    if n == 0:
        return None
    return math.degrees(math.atan2(x, y)) % 360


def aggregate_minute(rows: list[dict]) -> dict[str, float | None]:
    """Collapse a minute of samples into one stored row."""
    out: dict[str, float | None] = {}
    if not rows:
        return out
    keys = rows[0].keys()
    for k in keys:
        vals = [r[k] for r in rows if r.get(k) is not None]
        if not vals:
            out[k] = None
        elif k in ("rain_day", "battery"):
            out[k] = vals[-1]
        elif k == "gust_speed":
            out[k] = max(vals)
        elif k in ("wind_dir", "gust_dir"):
            continue
        else:
            out[k] = fmean(vals)
    out["wind_dir"] = _vector_mean_dir(rows)
    gusts = [r for r in rows if r.get("gust_speed") is not None]
    out["gust_dir"] = max(gusts, key=lambda r: r["gust_speed"])["gust_dir"] if gusts else None
    return out


class Collector:
    def __init__(self, config: Config, store: Store | None = None, client: IP100Client | None = None):
        self.cfg = config
        self.tz = ZoneInfo(config.tz) if config.tz else datetime.now().astimezone().tzinfo
        self.store = store or Store(config.db_path)
        self.client = client or IP100Client(config.ip100_url)

        self.sample: Sample | None = None
        self.row: dict[str, float | None] | None = None
        self.sample_ts: float | None = None
        self.last_error: str | None = None
        self.consecutive_failures = 0

        self._minute: int | None = None
        self._minute_rows: list[dict] = []
        self._wind_trail: deque[tuple[float, int]] = deque()
        self._today: date | None = None
        self._extremes: dict[str, dict] = {}
        self._rain_at_midnight: float | None = None
        self._fingerprint: tuple | None = None
        self._last_change_ts: float | None = None
        self._subscribers: set[asyncio.Queue] = set()
        self._task: asyncio.Task | None = None

    # ---- lifecycle ----------------------------------------------------------

    def start(self) -> None:
        self._task = asyncio.create_task(self._run())

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        self._flush_minute()
        await self.client.close()
        self.store.close()

    async def _run(self) -> None:
        while True:
            started = time.monotonic()
            try:
                sample = await self.client.fetch()
                self.ingest(sample, time.time())
                self.last_error = None
                self.consecutive_failures = 0
            except Exception as e:  # noqa: BLE001 - keep polling whatever happens
                self.consecutive_failures += 1
                self.last_error = f"{type(e).__name__}: {e}"
                if self.consecutive_failures in (1, 10) or self.consecutive_failures % 100 == 0:
                    log.warning("IP-100 poll failed (%d in a row): %s", self.consecutive_failures, e)
            self._publish()
            delay = self.cfg.poll_seconds * min(2 ** max(self.consecutive_failures - 3, 0), 12)
            await asyncio.sleep(max(0.5, delay - (time.monotonic() - started)))

    # ---- ingestion ----------------------------------------------------------

    def stale_seconds(self, now: float | None = None) -> float:
        """How long the station's readings have been frozen (0 if changing)."""
        if self._last_change_ts is None or self.sample_ts is None:
            return 0.0
        return (now or self.sample_ts) - self._last_change_ts

    def readings_frozen(self) -> bool:
        return self.stale_seconds() >= self.cfg.stale_minutes * 60

    def signal_ok(self, s: Sample | None = None) -> bool:
        s = s or self.sample
        if s is None:
            return False
        if self.readings_frozen():
            return False
        if s.rssi is not None and s.rssi <= self.cfg.min_rssi:
            return False
        if s.signal_quality is not None and s.signal_quality <= 0:
            return False
        return True

    def local(self, ts: float) -> datetime:
        return datetime.fromtimestamp(ts, self.tz)

    def ingest(self, s: Sample, ts: float) -> None:
        now = self.local(ts)
        if self._today != now.date():
            self._roll_day(now.date(), ts)

        self.sample, self.sample_ts = s, ts
        self.row = _row_from_sample(s)

        fp = (s.out_temp, s.pressure, s.wind_speed, s.wind_dir, s.gust_speed, s.rain_day)
        if fp != self._fingerprint or self._last_change_ts is None:
            self._fingerprint = fp
            self._last_change_ts = ts

        if not self.signal_ok(s):
            # Don't record stale readings; the payload flags the problem.
            return

        sector = derived.compass_sector(s.wind_dir)
        if sector is not None:
            self._wind_trail.append((ts, sector))
        while self._wind_trail and self._wind_trail[0][0] < ts - WIND_TRAIL_SECONDS:
            self._wind_trail.popleft()

        self._update_extremes(self.row, ts)
        self._record_rain(s.rain_day, now, ts)

        minute = int(ts // 60)
        if self._minute is not None and minute != self._minute:
            self._flush_minute()
        self._minute = minute
        self._minute_rows.append(self.row)

    def _flush_minute(self) -> None:
        if self._minute is None or not self._minute_rows:
            return
        self.store.insert(self._minute * 60, aggregate_minute(self._minute_rows))
        self._minute_rows = []

    def _record_rain(self, rain_day: float | None, now: datetime, ts: float) -> None:
        if rain_day is None:
            return
        # Right after midnight the IP-100 may still report yesterday's total
        # if its clock differs from ours; don't credit that to today.
        midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
        if (
            self._rain_at_midnight
            and ts - midnight.timestamp() < 600
            and abs(rain_day - self._rain_at_midnight) < 1e-6
        ):
            return
        self._rain_at_midnight = None
        self.store.set_daily_rain(now.date().isoformat(), rain_day)

    def _roll_day(self, today: date, ts: float) -> None:
        first_run = self._today is None
        self._today = today
        if not first_run and self.row is not None:
            self._rain_at_midnight = self.row.get("rain_day")
        self._extremes = {}
        # Seed from history so a restart mid-day keeps today's highs/lows.
        start = int(datetime.combine(today, datetime.min.time(), self.tz).timestamp())
        for metric in EXTREME_METRICS:
            lo, hi = self.store.extremes(METRICS[metric], start, int(ts) + 1)
            if lo and hi:
                self._extremes[metric] = {"min": lo[0], "min_time": lo[1], "max": hi[0], "max_time": hi[1]}

    def _update_extremes(self, row: dict, ts: float) -> None:
        for metric in EXTREME_METRICS:
            v = row.get(METRICS[metric])
            if v is None:
                continue
            e = self._extremes.get(metric)
            if e is None:
                self._extremes[metric] = {"min": v, "min_time": int(ts), "max": v, "max_time": int(ts)}
                continue
            if v < e["min"]:
                e["min"], e["min_time"] = v, int(ts)
            if v > e["max"]:
                e["max"], e["max_time"] = v, int(ts)

    # ---- payload ------------------------------------------------------------

    def rain_totals(self, ts: float) -> dict[str, float | None]:
        day = self.row.get("rain_day") if self.row else None
        if day is None:
            return {"hour": None, "day": None, "month": None, "year": None}
        earlier = self.store.value_at_or_before("rain_day", int(ts) - 3600, max_age=900)
        if earlier is None:
            hour = None
        elif earlier > day:  # daily counter reset at midnight
            hour = day
        else:
            hour = day - earlier
        today = self.local(ts).date()
        yesterday = today - timedelta(days=1)
        month = year = day
        if today.day > 1:
            month += self.store.rain_between_days(today.replace(day=1).isoformat(), yesterday.isoformat())
        if today.timetuple().tm_yday > 1:
            year += self.store.rain_between_days(today.replace(month=1, day=1).isoformat(), yesterday.isoformat())
        return {"hour": hour, "day": day, "month": month, "year": year}

    def wind_trail(self, ts: float) -> list[dict]:
        recent = [sec for t, sec in self._wind_trail if t >= ts - WIND_TRAIL_SECONDS]
        if not recent:
            return []
        counts: dict[int, int] = {}
        for sec in recent:
            counts[sec] = counts.get(sec, 0) + 1
        top = max(counts.values())
        return [{"sector": k, "weight": round(v / top, 3)} for k, v in sorted(counts.items())]

    def payload(self) -> dict:
        now = time.time()
        s, r = self.sample, self.row or {}
        age = None if self.sample_ts is None else now - self.sample_ts
        online = s is not None and age is not None and age < max(60, self.cfg.poll_seconds * 6)
        p_now = r.get("pressure")
        p_then = self.store.value_at_or_before("pressure", int(now) - 3 * 3600, max_age=1800)
        if p_then is None:  # not enough history yet; use 1 hour
            p_then = self.store.value_at_or_before("pressure", int(now) - 3600, max_age=900)
        return {
            "time": int(now),
            "updated": None if self.sample_ts is None else int(self.sample_ts),
            "online": online,
            "error": self.last_error,
            "station": {
                "signal_ok": self.signal_ok(),
                "rssi": s.rssi if s else None,
                "signal_quality": s.signal_quality if s else None,
                "battery": r.get("battery"),
                "frozen_minutes": round(self.stale_seconds() / 60) if self.readings_frozen() else None,
                "clock": s.clock if s else None,
                "firmware": s.firmware if s else None,
            },
            "warnings": list(s.warnings) if s else [],
            "outside": {
                "temperature": r.get("out_temp"),
                "humidity": r.get("humidity"),
                "dew_point": r.get("dew_point"),
                "wind_chill": r.get("wind_chill"),
                "thi": r.get("thi"),
                "solar": r.get("solar"),
            },
            "inside": {"temperature": r.get("in_temp")},
            "pressure": {"value": p_now, "trend": derived.pressure_trend(p_now, p_then)},
            "wind": {
                "speed": r.get("wind_speed"),
                "direction": r.get("wind_dir"),
                "sector": derived.compass_sector(r.get("wind_dir")),
                "gust": r.get("gust_speed"),
                "gust_direction": r.get("gust_dir"),
                "recent": self.wind_trail(now),
            },
            "rain": self.rain_totals(now),
            "today": self._extremes,
            "timezone": str(self.tz),
        }

    # ---- live subscribers ---------------------------------------------------

    def subscribe(self) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue(maxsize=4)
        self._subscribers.add(q)
        return q

    def unsubscribe(self, q: asyncio.Queue) -> None:
        self._subscribers.discard(q)

    def _publish(self) -> None:
        if not self._subscribers:
            return
        data = self.payload()
        for q in list(self._subscribers):
            if q.full():
                try:
                    q.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            q.put_nowait(data)
