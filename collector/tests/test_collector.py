from datetime import datetime
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from rainwise_collector import derived
from rainwise_collector.api import create_app
from rainwise_collector.ip100 import Sample, parse_status_xml
from rainwise_collector.service import Collector, Config, aggregate_minute
from rainwise_collector.simulator import synthetic, to_xml
from rainwise_collector.store import Store

# Captured from the user's IP-100 (firmware 1083), 2026-11-01.
XML = b"""<?xml version="1.0" encoding="ISO-8859-1"?>
<!-- Weather and hardware paramters for the IP-100, min's, max's and accumulations are for the current day -->
<status>
 <hardware>
   <serial_number></serial_number>
   <firmware_version>1083</firmware_version>
   <clock>2026/11/01 09:44:29</clock>
   <station_volts>6.6</station_volts>
   <network>
   \t\t<MAC_address>0090C2E905D7</MAC_address>
   \t\t<IP_address>192.168.11.61</IP_address>
\t\t<subnet>255.255.254.0</subnet>
\t\t<gateway>192.168.10.1</gateway>
   </network>
   <interval>1</interval>
   <base_units>English</base_units>
   <speed_units>mph</speed_units>
 </hardware>

 <weather>
\t<temperature_outside>
\t\t<current>43.6</current>
\t\t<max>43.6</max>
\t\t<min>43.6</min>
\t</temperature_outside>

\t<humidity>
\t\t<current>0</current>
\t\t<max>0</max>
\t\t<min>0</min>
\t</humidity>

\t<pressure>
\t\t<current>29.73</current>
\t\t<max>29.73</max>
\t\t<min>29.73</min>
\t</pressure>

\t<precipitation>
\t\t<current>0.00</current>
\t</precipitation>

\t<wind>
\t\t<speed>3.0</speed>
\t\t<direction>225</direction>
\t\t<gust_speed>3.0</gust_speed>
\t\t<gust_direction>0</gust_direction>
\t</wind>

\t<temperature_inside>
\t\t<current>70.0</current>
\t\t<max>70.0</max>
\t\t<min>70.0</min>
\t</temperature_inside>
 </weather>
</status>"""

TZ = "America/New_York"


def test_parse_real_ip100_xml():
    s = parse_status_xml(XML)
    assert s.out_temp == 43.6 and s.in_temp == 70.0
    assert s.pressure == 29.73 and s.rain_day == 0.0
    assert (s.wind_speed, s.wind_dir, s.gust_speed) == (3.0, 225, 3.0)
    assert s.battery == 6.6
    assert s.firmware == "1083" and s.clock == "2026/11/01 09:44:29"
    assert s.rssi is None and s.signal_quality is None
    assert s.raw["temperature_outside"]["max"] == "43.6"
    # Firmware quirks: 0 % humidity = failed sensor, gust_direction 0 = none
    assert s.humidity is None and any("Humidity" in w for w in s.warnings)
    assert s.gust_dir is None


def test_speed_units():
    s = parse_status_xml(XML.replace(b"<speed_units>mph", b"<speed_units>kph"))
    assert s.wind_speed == pytest.approx(1.864, abs=1e-3)


def test_parse_rejects_garbage():
    with pytest.raises(ValueError):
        parse_status_xml(b"<html></html>")
    with pytest.raises(ValueError):
        parse_status_xml(b"not xml")


def test_metric_conversion():
    s = parse_status_xml(XML.replace(b"English", b"Metric"))
    assert s.out_temp == pytest.approx(110.48)
    assert s.pressure == pytest.approx(0.878, abs=1e-3)


def test_simulator_xml_roundtrip():
    s = synthetic(1_700_000_000)
    p = parse_status_xml(to_xml(s))
    assert p.out_temp == s.out_temp and p.wind_dir == s.wind_dir and p.humidity == s.humidity


def test_derived_values():
    # NWS table: 0 °F, 15 mph -> -19 °F
    assert derived.wind_chill_f(0, 15) == pytest.approx(-19, abs=0.5)
    assert derived.wind_chill_f(60, 15) == 60
    assert derived.wind_chill_f(20, 2) == 20
    # 90 °F, 60 % -> heat index 100 °F
    assert derived.heat_index_f(90, 60) == pytest.approx(100, abs=1)
    assert derived.heat_index_f(4, 90) == 4
    assert derived.dew_point_f(68, 50) == pytest.approx(48.6, abs=0.5)
    assert derived.pressure_trend(29.80, 29.70) == "rise"
    assert derived.pressure_trend(29.70, 29.80) == "fall"
    assert derived.pressure_trend(29.70, 29.71) == "steady"
    assert [derived.compass_sector(d) for d in (0, 359, 90, 180, 270, 11.2, 11.3)] == [0, 0, 4, 8, 12, 0, 1]


def test_aggregate_minute_wind_direction_wraps():
    rows = [
        {"out_temp": 10, "wind_speed": 5, "wind_dir": 350, "gust_speed": 8, "gust_dir": 350, "rain_day": 0.1},
        {"out_temp": 12, "wind_speed": 5, "wind_dir": 10, "gust_speed": 9, "gust_dir": 15, "rain_day": 0.2},
    ]
    agg = aggregate_minute(rows)
    assert agg["out_temp"] == 11
    assert agg["wind_dir"] == pytest.approx(0, abs=0.01) or agg["wind_dir"] == pytest.approx(360, abs=0.01)
    assert agg["gust_speed"] == 9 and agg["gust_dir"] == 15
    assert agg["rain_day"] == 0.2


class FakeClient:
    async def close(self):
        pass


def make_collector():
    return Collector(Config(ip100_url="http://x/status.xml", tz=TZ), store=Store(":memory:"), client=FakeClient())


def ts_of(y, mo, d, h=0, mi=0):
    return datetime(y, mo, d, h, mi, tzinfo=ZoneInfo(TZ)).timestamp()


def test_ingest_extremes_rain_and_trail():
    c = make_collector()
    base = ts_of(2026, 11, 1, 6)
    for i, (t, rain) in enumerate([(10, 0.0), (5, 0.05), (8, 0.10)]):
        c.ingest(Sample(out_temp=t, humidity=60, pressure=29.7, wind_speed=4, wind_dir=270, rain_day=rain), base + i * 60)
    c.ingest(Sample(out_temp=7, rain_day=0.10), base + 3 * 60 + 61 * 60)
    ex = c._extremes["temperature"]
    assert ex["min"] == 5 and ex["max"] == 10
    totals = c.rain_totals(base + 64 * 60)
    assert totals["day"] == 0.10
    assert totals["hour"] == pytest.approx(0.0)  # no change in the last hour
    assert c.store.rain_between_days("2026-11-01", "2026-11-01") == 0.10


def test_signal_loss_not_recorded():
    c = make_collector()
    c.ingest(Sample(out_temp=36.7, humidity=50, rssi=-120, signal_quality=0), ts_of(2026, 11, 1, 0, 1))
    assert not c.signal_ok()
    assert c._extremes == {} and c._minute_rows == []


def test_frozen_readings_detected():
    c = make_collector()
    t0 = ts_of(2026, 11, 1, 3)
    frozen = Sample(out_temp=40.0, pressure=29.7, wind_speed=0, wind_dir=360, gust_speed=0, rain_day=0)
    for i in range(0, 29 * 60, 60):
        c.ingest(frozen, t0 + i)
    assert c.signal_ok()  # 28 minutes unchanged: still plausible (calm night)
    rows_before = len(c._minute_rows)
    c.ingest(frozen, t0 + 31 * 60)
    assert not c.signal_ok()
    assert len(c._minute_rows) == rows_before  # not recorded
    assert c.payload()["station"]["frozen_minutes"] == 31
    c.ingest(Sample(out_temp=40.1, pressure=29.7, wind_speed=0, wind_dir=360, gust_speed=0, rain_day=0), t0 + 32 * 60)
    assert c.signal_ok()


def test_month_and_year_rain():
    c = make_collector()
    c.store.set_daily_rain("2026-10-31", 0.5)
    c.store.set_daily_rain("2026-11-01", 0.25)
    c.store.set_daily_rain("2026-01-03", 1.0)
    c.ingest(Sample(rain_day=0.1), ts_of(2026, 11, 2, 9))
    t = c.rain_totals(ts_of(2026, 11, 2, 9))
    assert t["month"] == pytest.approx(0.35)
    assert t["year"] == pytest.approx(1.85)


def test_api_endpoints():
    c = make_collector()
    now = datetime.now(ZoneInfo(TZ)).timestamp()
    for i in range(5):
        c.ingest(Sample(out_temp=20 + i, humidity=50, pressure=29.9, wind_speed=3, wind_dir=90, rain_day=0), now - 300 + i * 61)
    app = create_app(collector=c, token="secret", autostart=False)
    with TestClient(app) as client:
        assert client.get("/api/current").status_code == 401
        h = {"Authorization": "Bearer secret"}
        cur = client.get("/api/current", headers=h).json()
        assert cur["outside"]["temperature"] == 24
        assert cur["wind"]["sector"] == 4
        hist = client.get("/api/history?metric=temperature&range=today", headers=h).json()
        assert hist["points"] and hist["min"]["v"] <= hist["max"]["v"]
        assert client.get("/api/history?metric=bogus", headers=h).status_code == 400
        assert client.get("/api/health").json()["ok"] is True
