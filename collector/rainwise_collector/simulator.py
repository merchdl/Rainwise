"""A fake IP-100 for developing the app without the real hardware.

    python -m rainwise_collector.simulator --port 8101
    IP100_URL=http://localhost:8101/status.xml DB_PATH=./dev.db python -m rainwise_collector

``--backfill DB`` also writes a week of synthetic minute history into a DB so
the graphs have something to show straight away.
"""

from __future__ import annotations

import argparse
import math
import random
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .ip100 import Sample
from .service import _row_from_sample
from .store import Store


def synthetic(ts: float, seed: int = 0) -> Sample:
    rnd = random.Random(int(ts // 5) + seed)
    lt = datetime.fromtimestamp(ts)
    hour = lt.hour + lt.minute / 60
    day = ts / 86400
    diurnal = math.sin((hour - 9) / 24 * 2 * math.pi)
    out_temp = 8 + 10 * diurnal + 6 * math.sin(day / 3) + rnd.uniform(-0.3, 0.3)
    humidity = max(15, min(100, 70 - 20 * diurnal + rnd.uniform(-2, 2)))
    wind = max(0.0, 6 + 5 * math.sin(day * 2.1) + rnd.uniform(-2, 3))
    direction = (270 + 40 * math.sin(day * 1.3) + rnd.uniform(-20, 20)) % 360
    rain_rate = max(0.0, math.sin(day * 0.9) - 0.85) * 0.2  # occasional showers, in/h
    rain_day = round(rain_rate * hour, 2)
    return Sample(
        out_temp=round(out_temp, 1),
        in_temp=round(69 + rnd.uniform(-0.3, 0.3), 1),
        humidity=round(humidity),
        pressure=round(29.9 + 0.25 * math.sin(day * 0.7), 2),
        wind_speed=round(wind),
        wind_dir=round(direction),
        gust_speed=round(wind + rnd.uniform(0, 6)),
        gust_dir=round(direction + rnd.uniform(-15, 15)) % 360,
        rain_day=rain_day,
        battery=6.3,
        rssi=-78,
        signal_quality=100,
    )


def to_xml(s: Sample) -> str:
    def block(tag, v):
        return f"<{tag}><current>{v}</current><high>{v}</high><low>{v}</low><average>{v}</average></{tag}>"

    return (
        "<?xml version='1.0'?><status>"
        "<hardware><base_units>English</base_units><firmware>sim</firmware>"
        f"<rssi>{s.rssi}</rssi><signal_quality>{s.signal_quality}</signal_quality>"
        f"<station_volts>{s.battery}</station_volts></hardware>"
        "<weather>"
        + block("temperature_outside", s.out_temp)
        + block("temperature_inside", s.in_temp)
        + block("humidity", s.humidity)
        + block("pressure", s.pressure)
        + f"<wind><speed>{s.wind_speed}</speed><direction>{s.wind_dir}</direction>"
        f"<gust_speed>{s.gust_speed}</gust_speed><gust_direction>{s.gust_dir}</gust_direction></wind>"
        + block("precipitation", s.rain_day)
        + "</weather></status>"
    )


def backfill(db_path: str, days: int = 7) -> None:
    store = Store(db_path)
    now = int(time.time() // 60 * 60)
    for ts in range(now - days * 86400, now, 60):
        s = synthetic(ts)
        store.insert(ts, _row_from_sample(s))
        store.set_daily_rain(datetime.fromtimestamp(ts).date().isoformat(), s.rain_day or 0)
    store.close()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path.split("?")[0] != "/status.xml":
            self.send_error(404)
            return
        body = to_xml(synthetic(time.time())).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/xml")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", type=int, default=8101)
    p.add_argument("--backfill", metavar="DB", help="write a week of synthetic history into DB and exit")
    a = p.parse_args()
    if a.backfill:
        backfill(a.backfill)
        print(f"backfilled {a.backfill}")
        return
    print(f"fake IP-100 at http://localhost:{a.port}/status.xml")
    ThreadingHTTPServer(("0.0.0.0", a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
