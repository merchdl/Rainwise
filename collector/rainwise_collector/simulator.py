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
        wind_dir=round(direction) or 360,
        gust_speed=round(wind + rnd.uniform(0, 6)),
        gust_dir=(round(direction + rnd.uniform(-15, 15)) % 360) or 360,
        rain_day=rain_day,
        battery=6.6,
    )


def to_xml(s: Sample) -> str:
    """Same layout as a real IP-100 on firmware 1083."""

    def block(tag, v):
        return f"\t<{tag}>\n\t\t<current>{v}</current>\n\t\t<max>{v}</max>\n\t\t<min>{v}</min>\n\t</{tag}>\n"

    clock = datetime.now().strftime("%Y/%m/%d %H:%M:%S")
    return (
        '<?xml version="1.0" encoding="ISO-8859-1"?>\n'
        "<!-- Weather and hardware paramters for the IP-100, min's, max's and accumulations are for the current day -->\n"
        "<status>\n <hardware>\n"
        "   <serial_number></serial_number>\n   <firmware_version>sim</firmware_version>\n"
        f"   <clock>{clock}</clock>\n   <station_volts>{s.battery}</station_volts>\n"
        "   <network><IP_address>127.0.0.1</IP_address></network>\n"
        "   <interval>1</interval>\n   <base_units>English</base_units>\n   <speed_units>mph</speed_units>\n"
        " </hardware>\n <weather>\n"
        + block("temperature_outside", s.out_temp)
        + block("humidity", s.humidity)
        + block("pressure", s.pressure)
        + f"\t<precipitation>\n\t\t<current>{s.rain_day:.2f}</current>\n\t</precipitation>\n"
        + f"\t<wind>\n\t\t<speed>{s.wind_speed}</speed>\n\t\t<direction>{s.wind_dir}</direction>\n"
        f"\t\t<gust_speed>{s.gust_speed}</gust_speed>\n\t\t<gust_direction>{s.gust_dir}</gust_direction>\n\t</wind>\n"
        + block("temperature_inside", s.in_temp)
        + " </weather>\n</status>"
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
