# Rainwise Weather Console

A replacement for the discontinued RainWise iPhone/iPad app, for an MK-III
station with an IP-100 network interface.

```
MK-III ──RF──▶ IP-100 (192.168.11.61) ──HTTP /status.xml──▶ collector (Proxmox container)
                                                              │  SQLite history, REST + live stream
                                                              ▼
                                          iOS app: LED console + history graphs (iPhone & iPad)
```

* **`collector/`**: a small Python service. It polls the IP-100 every 5 s,
  stores one row a minute in SQLite, and works out the values the IP-100
  doesn't report: wind chill, dew point, THI, the pressure trend, rain for
  the hour, month and year, today's highs and lows, and the recent wind
  directions. It serves all of this to the app.
* **`ios/`**: a SwiftUI app.
  * **iPad:** the console layout with the graph beneath it.
  * **iPhone portrait:** a compact console with the graph below, so live data and history are on screen together.
  * **iPhone landscape:** a full-screen graph.

## 1. Run the collector on Proxmox

The collector reads the IP-100's XML feed (tested against firmware 1083).
First check that the feed is reachable from the network the container will be on:

```sh
curl http://192.168.11.61/status.xml
```

### Option A: Docker (in an LXC or VM that runs Docker)

```sh
git clone <this repo> && cd Rainwise/collector
# edit docker-compose.yml: IP100_HOST and TZ
docker compose up -d --build
curl http://localhost:8100/api/health
```

History is kept in `collector/data/rainwise.db`.

### Option B: plain Debian/Ubuntu LXC with systemd

```sh
apt install -y python3 python3-venv git
useradd --system --home /var/lib/rainwise --create-home rainwise
git clone <this repo> /opt/rainwise-src
python3 -m venv /opt/rainwise-collector/venv
/opt/rainwise-collector/venv/bin/pip install /opt/rainwise-src/collector
cp /opt/rainwise-src/collector/deploy/rainwise-collector.env /etc/rainwise-collector.env   # edit TZ etc.
cp /opt/rainwise-src/collector/deploy/rainwise-collector.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now rainwise-collector
journalctl -u rainwise-collector -f
```

### Settings (environment variables)

| Variable | Default | |
|---|---|---|
| `IP100_HOST` | `192.168.11.61` | or `IP100_URL` for a full URL |
| `POLL_SECONDS` | `5` | |
| `TZ` | container's zone | **Set this.** It decides when "today" starts for highs/lows and rain totals |
| `DB_PATH` | `/data/rainwise.db` | |
| `PORT` | `8100` | |
| `API_TOKEN` | *(none)* | If set, the app must send the same token |
| `STALE_MINUTES` | `30` | If temperature, pressure, wind and rain don't change for this long, the IP-100 is assumed to have lost the station and readings aren't stored |

### Away from home

Install [Tailscale](https://tailscale.com) in the collector container and on
your iPhone/iPad, then use the container's Tailscale address in the app.
You don't need to forward any ports.

### API

| Endpoint | |
|---|---|
| `GET /api/current` | Live conditions, derived values, today's extremes |
| `GET /api/stream` | The same payload as Server-Sent Events, one per poll |
| `GET /api/history?metric=temperature&range=today` | `range`: `today`, `48h`, `week`. `metric`: `temperature`, `humidity`, `pressure`, `rain`, `wind_speed`, `gust`, `wind_chill`, `dew_point`, `thi`, `inside_temperature`, `solar` |
| `GET /api/raw` | The IP-100's `status.xml`, unmodified (for troubleshooting) |
| `GET /api/health` | |

### Develop without the hardware

```sh
cd collector
pip install -e '.[test]' && pytest
python -m rainwise_collector.simulator --backfill ./dev.db        # a week of fake history
python -m rainwise_collector.simulator --port 8101 &               # fake IP-100
IP100_URL=http://localhost:8101/status.xml DB_PATH=./dev.db python -m rainwise_collector
```

## 2. Build the iOS app (on your Mac)

You need Xcode 15 or newer (the app targets iOS 17) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cd ios
xcodegen
open RainwiseConsole.xcodeproj
```

1. In Xcode, select the **RainwiseConsole** target, then **Signing &
   Capabilities**, and choose your team. Change the bundle ID if Xcode asks.
2. Plug in your iPhone or iPad and press **Run**.
   * With a free Apple ID, the install has to be re-signed every 7 days.
   * With the $99/yr developer program, it lasts a year, and you can use
     TestFlight for your other devices.

The app starts on **demo data**. Tap **ⓘ** (bottom right), turn off demo data,
enter the collector address (e.g. `192.168.11.20:8100`), use **Test
connection**, then **Save**.

### Using the console

| Control | Action |
|---|---|
| Humidity panel / THI | Switch between humidity and temperature-humidity index |
| Rainfall panel | Cycle hour → day → month → year (or tap an LED) |
| Clock panel | Switch between time and date |
| Temperature LEDs / **SELECT** | Outside → inside → wind chill → dew point |
| **MAX** / **MIN** | Show today's highs/lows on every display. The clock shows when the selected temperature extreme happened, and wind shows the peak gust. Returns to live after 15 s |
| **BRIGHTNESS** | Three LED brightness levels |
| Graph | Drag across it to read values. Range and metric buttons sit below it |

The wind ring lights the current direction. Directions seen in the last 10
minutes glow dimly.

## Notes on the IP-100 data

* `status.xml` carries no radio-signal level, so a lost station is detected
  by readings freezing (see `STALE_MINUTES`).
* A humidity of exactly 0% means the station's humidity sensor has failed or
  is disconnected. The collector records it as missing, so dew point and
  THI above 70 °F are blank, and the app shows a warning.
* `gust_direction` of 0 means "no gust direction". The wind direction is
  used instead. North is reported as 360.
