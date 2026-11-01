"""SQLite history store. One row per minute; daily rain totals in their own table."""

from __future__ import annotations

import sqlite3
import threading
from pathlib import Path

COLUMNS = [
    "out_temp",
    "in_temp",
    "humidity",
    "pressure",
    "wind_speed",
    "wind_dir",
    "gust_speed",
    "gust_dir",
    "rain_day",
    "solar",
    "battery",
    "wind_chill",
    "dew_point",
    "thi",
]

# API metric name -> column. These are the graph buttons in the app.
METRICS = {
    "temperature": "out_temp",
    "inside_temperature": "in_temp",
    "humidity": "humidity",
    "pressure": "pressure",
    "rain": "rain_day",
    "wind_speed": "wind_speed",
    "gust": "gust_speed",
    "wind_chill": "wind_chill",
    "dew_point": "dew_point",
    "thi": "thi",
    "solar": "solar",
}


class Store:
    def __init__(self, path: str | Path):
        self.path = str(path)
        if self.path != ":memory:":
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(self.path, check_same_thread=False)
        self._lock = threading.Lock()
        cols = ", ".join(f"{c} REAL" for c in COLUMNS)
        with self._lock, self._db:
            self._db.execute("PRAGMA journal_mode=WAL")
            self._db.execute(f"CREATE TABLE IF NOT EXISTS readings (ts INTEGER PRIMARY KEY, {cols})")
            self._db.execute(
                "CREATE TABLE IF NOT EXISTS daily_rain (day TEXT PRIMARY KEY, rain REAL NOT NULL)"
            )

    def close(self) -> None:
        self._db.close()

    # ---- writes -------------------------------------------------------------

    def insert(self, ts: int, row: dict[str, float | None]) -> None:
        names = ["ts"] + [c for c in COLUMNS if c in row]
        values = [ts] + [row[c] for c in names[1:]]
        marks = ", ".join("?" for _ in names)
        with self._lock, self._db:
            self._db.execute(
                f"INSERT OR REPLACE INTO readings ({', '.join(names)}) VALUES ({marks})", values
            )

    def set_daily_rain(self, day: str, rain: float) -> None:
        """Record the day's rain total (keeps the largest value seen)."""
        with self._lock, self._db:
            self._db.execute(
                "INSERT INTO daily_rain (day, rain) VALUES (?, ?) "
                "ON CONFLICT(day) DO UPDATE SET rain = MAX(rain, excluded.rain)",
                (day, rain),
            )

    # ---- reads --------------------------------------------------------------

    def _q(self, sql: str, args=()):
        with self._lock:
            return self._db.execute(sql, args).fetchall()

    def latest_ts(self) -> int | None:
        row = self._q("SELECT MAX(ts) FROM readings")[0]
        return row[0]

    def value_at_or_before(self, column: str, ts: int, max_age: int = 900) -> float | None:
        """Most recent non-null value of ``column`` at or before ``ts`` (within max_age s)."""
        _check(column)
        rows = self._q(
            f"SELECT {column} FROM readings WHERE ts <= ? AND ts >= ? AND {column} IS NOT NULL "
            "ORDER BY ts DESC LIMIT 1",
            (ts, ts - max_age),
        )
        return rows[0][0] if rows else None

    def extremes(self, column: str, start: int, end: int):
        """((min_value, min_ts), (max_value, max_ts)) or (None, None)."""
        _check(column)
        lo = self._q(
            f"SELECT {column}, ts FROM readings WHERE ts >= ? AND ts < ? AND {column} IS NOT NULL "
            f"ORDER BY {column} ASC, ts ASC LIMIT 1",
            (start, end),
        )
        hi = self._q(
            f"SELECT {column}, ts FROM readings WHERE ts >= ? AND ts < ? AND {column} IS NOT NULL "
            f"ORDER BY {column} DESC, ts ASC LIMIT 1",
            (start, end),
        )
        return (tuple(lo[0]) if lo else None, tuple(hi[0]) if hi else None)

    def series(self, column: str, start: int, end: int, bucket: int):
        """Bucketed averages: list of (bucket_start_ts, value).

        Rain is a running daily total, so it uses MAX per bucket rather than AVG.
        """
        _check(column)
        agg = "MAX" if column in ("rain_day", "gust_speed") else "AVG"
        rows = self._q(
            f"SELECT (ts / ?) * ? AS b, {agg}({column}) FROM readings "
            f"WHERE ts >= ? AND ts < ? AND {column} IS NOT NULL GROUP BY b ORDER BY b",
            (bucket, bucket, start, end),
        )
        return [(int(b), v) for b, v in rows]

    def rain_between_days(self, first_day: str, last_day: str) -> float:
        """Sum of daily totals for first_day..last_day inclusive (ISO dates)."""
        row = self._q(
            "SELECT COALESCE(SUM(rain), 0) FROM daily_rain WHERE day >= ? AND day <= ?",
            (first_day, last_day),
        )[0]
        return float(row[0])


def _check(column: str) -> None:
    if column not in COLUMNS:
        raise ValueError(f"unknown column {column!r}")
