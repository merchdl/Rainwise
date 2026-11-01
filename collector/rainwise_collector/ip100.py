"""Read and parse the Rainwise IP-100's ``/status.xml`` endpoint.

The IP-100 serves a small XML document shaped roughly like::

    <status>
      <hardware>
        <base_units>English</base_units>
        ...signal / firmware / battery fields...
      </hardware>
      <weather>
        <temperature_outside><current>36.7</current>...</temperature_outside>
        <humidity><current>64</current>...</humidity>
        <wind>
          <speed>2</speed><direction>270</direction>
          <gust_speed>5</gust_speed><gust_direction>280</gust_direction>
        </wind>
        <precipitation><current>0.00</current>...</precipitation>
        ...
      </weather>
    </status>

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
    return s


def _metric_to_us(s: Sample) -> None:
    """Convert a metric IP-100 reading to US units.

    The collector stores everything in US units and the app converts for
    display. Units set to "Metric" on the IP-100 are assumed to be °C, hPa,
    km/h and mm. If your unit disagrees, set it back to US (English).
    """

    def c_to_f(v):
        return None if v is None else v * 9 / 5 + 32

    s.out_temp = c_to_f(s.out_temp)
    s.in_temp = c_to_f(s.in_temp)
    if s.pressure is not None:
        s.pressure = s.pressure * 0.0295299830714
    for attr in ("wind_speed", "gust_speed"):
        v = getattr(s, attr)
        if v is not None:
            setattr(s, attr, v * 0.621371)
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
