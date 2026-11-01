"""Read and parse the Rainwise IP-100's ``/status.xml`` endpoint.

Firmware 1083 serves (min/max are for the current day)::

    <status>
      <hardware>
        <firmware_version>1083</firmware_version>
        <clock>2026/11/01 09:44:29</clock>
        <station_volts>6.6</station_volts>
        <network>...</network>
        <interval>1</interval>
        <base_units>English</base_units>
        <speed_units>mph</speed_units>
      </hardware>
      <weather>
        <temperature_outside><current>43.6</current><max>43.6</max><min>43.6</min></temperature_outside>
        <humidity>...</humidity>
        <pressure>...</pressure>
        <precipitation><current>0.00</current></precipitation>
        <wind>
          <speed>3.0</speed><direction>225</direction>
          <gust_speed>3.0</gust_speed><gust_direction>0</gust_direction>
        </wind>
        <temperature_inside>...</temperature_inside>
      </weather>
    </status>

It has no radio-signal fields (the web page's "Rx Signal" isn't in the XML);
the collector detects a lost station by readings that stop changing instead.

Firmware versions differ in the exact child elements, so parsing is tolerant:
we read what we recognise and keep everything else in ``raw`` so it can be
inspected through the API (``/api/raw``).
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from xml.etree import ElementTree

import httpx

log = logging.getLogger(__name__)


@dataclass
class Sample:
    """One reading from the IP-100, normalised to US units."""

    out_temp: float | None = None  # °F
    in_temp: float | None = None  # °F
    humidity: float | None = None  # %
    pressure: float | None = None  # inHg
    wind_speed: float | None = None  # mph
    wind_dir: float | None = None  # degrees
    gust_speed: float | None = None  # mph
    gust_dir: float | None = None  # degrees
    rain_day: float | None = None  # inches since local midnight
    solar: float | None = None  # W/m²
    battery: float | None = None  # station volts
    rssi: float | None = None  # dBm, if the firmware reports it
    signal_quality: float | None = None
    base_units: str = "English"
    speed_units: str = "mph"
    clock: str | None = None  # IP-100's own clock, as reported
    firmware: str | None = None
    warnings: list[str] = field(default_factory=list)
    hardware: dict[str, str] = field(default_factory=dict)
    raw: dict[str, dict[str, str]] = field(default_factory=dict)


# IP-100 element name -> Sample attribute
_WEATHER_MAP = {
    "temperature_outside": "out_temp",
    "temperature_inside": "in_temp",
    "humidity": "humidity",
    "pressure": "pressure",
    "precipitation": "rain_day",
    "solar_radiation": "solar",
}


def _num(text: str | None) -> float | None:
    if text is None:
        return None
    text = text.strip().rstrip('"°%').strip()
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def _flatten(el: ElementTree.Element, prefix: str = "") -> dict[str, str]:
    out: dict[str, str] = {}
    for child in el:
        key = f"{prefix}{child.tag}"
        if len(child):
            out.update(_flatten(child, prefix=f"{key}."))
        else:
            out[key] = (child.text or "").strip()
    return out


def parse_status_xml(data: bytes | str) -> Sample:
    """Parse a status.xml document. Raises ``ValueError`` if it isn't one."""
    try:
        root = ElementTree.fromstring(data)
    except ElementTree.ParseError as e:
        raise ValueError(f"status.xml is not valid XML: {e}") from e
    if root.tag != "status":
        raise ValueError(f"unexpected root element <{root.tag}>")

    s = Sample()

    hw = root.find("hardware")
    if hw is not None:
        s.hardware = _flatten(hw)
        s.base_units = s.hardware.get("base_units", "English") or "English"
        s.speed_units = s.hardware.get("speed_units", "mph") or "mph"
        s.clock = s.hardware.get("clock") or None
        s.firmware = s.hardware.get("firmware_version") or None
        for key, value in s.hardware.items():
            leaf = key.rsplit(".", 1)[-1].lower()
            if leaf in ("station_volts", "battery", "station_battery"):
                s.battery = _num(value)
            elif leaf in ("rssi", "rx_signal", "signal", "signal_level"):
                s.rssi = _num(value)
            elif leaf in ("signal_quality", "signal_q", "quality", "lqi"):
                s.signal_quality = _num(value)

    weather = root.find("weather")
    if weather is not None:
        for child in weather:
            s.raw[child.tag] = _flatten(child)
            if child.tag == "wind":
                s.wind_speed = _num(child.findtext("speed"))
                s.wind_dir = _num(child.findtext("direction"))
                s.gust_speed = _num(child.findtext("gust_speed"))
                s.gust_dir = _num(child.findtext("gust_direction"))
            elif child.tag == "station_volts":
                s.battery = _num(child.findtext("current") or child.text)
            elif child.tag in _WEATHER_MAP:
                value = child.findtext("current")
                if value is None:
                    value = child.text
                setattr(s, _WEATHER_MAP[child.tag], _num(value))
            else:
                log.debug("ignoring weather element <%s>", child.tag)

    if s.base_units.lower() != "english":
        _metric_to_us(s)
    _speed_to_mph(s)
    _sanity(s)
    return s


_SPEED_TO_MPH = {"mph": 1.0, "kph": 0.621371, "km/h": 0.621371, "kmh": 0.621371,
                 "knots": 1.150779, "kts": 1.150779, "m/s": 2.236936, "mps": 2.236936}


def _speed_to_mph(s: Sample) -> None:
    factor = _SPEED_TO_MPH.get(s.speed_units.strip().lower())
    if factor is None:
        log.warning("unknown speed_units %r; assuming mph", s.speed_units)
        return
    if factor != 1.0:
        s.wind_speed = None if s.wind_speed is None else s.wind_speed * factor
        s.gust_speed = None if s.gust_speed is None else s.gust_speed * factor


def _sanity(s: Sample) -> None:
    """Drop values the hardware reports that can't be real."""
    # Outdoor RH is never 0 %; the MK-III reports 0 when its humidity sensor
    # has failed or is disconnected. Treat it as missing, not as data.
    if s.humidity is not None and s.humidity <= 0:
        s.humidity = None
        s.warnings.append("Humidity sensor reads 0% (sensor failed or disconnected)")
    elif s.humidity is not None and s.humidity > 100:
        s.humidity = 100.0
    # North is reported as 360; 0 means "no direction" (e.g. gust_direction
    # when there has been no gust above the average).
    if s.gust_dir == 0:
        s.gust_dir = None


def _metric_to_us(s: Sample) -> None:
    """Convert a metric IP-100 reading to US units.

    The collector stores everything in US units and the app converts for
    display. Units set to "Metric" on the IP-100 are assumed to be °C, hPa,
    and mm (wind uses the separate speed_units field). If your unit disagrees,
    set it back to US (English).
    """

    def c_to_f(v):
        return None if v is None else v * 9 / 5 + 32

    s.out_temp = c_to_f(s.out_temp)
    s.in_temp = c_to_f(s.in_temp)
    if s.pressure is not None:
        s.pressure = s.pressure * 0.0295299830714
    if s.rain_day is not None:
        s.rain_day = s.rain_day / 25.4


class IP100Client:
    def __init__(self, url: str, timeout: float = 5.0):
        self.url = url
        self._client = httpx.AsyncClient(timeout=timeout)

    async def fetch(self) -> Sample:
        r = await self._client.get(self.url)
        r.raise_for_status()
        return parse_status_xml(r.content)

    async def fetch_raw(self) -> str:
        r = await self._client.get(self.url)
        r.raise_for_status()
        return r.text

    async def close(self) -> None:
        await self._client.aclose()
