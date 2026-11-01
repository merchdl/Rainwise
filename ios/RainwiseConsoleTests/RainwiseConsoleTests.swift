import XCTest
@testable import RainwiseConsole

final class RainwiseConsoleTests: XCTestCase {

    /// Matches the collector's /api/current payload (trimmed from a real response).
    let currentJSON = """
    {"time": 1793506003, "updated": 1793506001, "online": true, "error": null,
     "station": {"signal_ok": true, "rssi": -78.0, "signal_quality": 100.0, "battery": 6.3},
     "outside": {"temperature": 4.2, "humidity": 90.0, "dew_point": 1.9, "wind_chill": -2.1, "thi": 4.2, "solar": null},
     "inside": {"temperature": 68.8},
     "pressure": {"value": 29.71, "trend": "rise"},
     "wind": {"speed": 3.0, "direction": 248.0, "sector": 11, "gust": 5.0, "gust_direction": 240.0,
              "recent": [{"sector": 10, "weight": 1.0}, {"sector": 11, "weight": 0.5}]},
     "rain": {"hour": 0.0, "day": 0.0, "month": 0.0, "year": 0.91},
     "today": {"temperature": {"min": 4.1, "min_time": 1793505600, "max": 4.3, "max_time": 1793505999}},
     "timezone": "America/New_York",
     "warnings": ["Humidity sensor reads 0% (sensor failed or disconnected)"]}
    """

    func testDecodeCurrent() throws {
        let c = try JSONDecoder.collector.decode(CurrentConditions.self, from: Data(currentJSON.utf8))
        XCTAssertTrue(c.isLive)
        XCTAssertEqual(c.outside.dewPoint, 1.9)
        XCTAssertEqual(c.wind.gustDirection, 240)
        XCTAssertEqual(c.wind.recent.count, 2)
        XCTAssertEqual(c.today["temperature"]?.maxTime, 1793505999)
        XCTAssertNil(c.outside.solar)
        XCTAssertEqual(c.warnings?.count, 1)
        XCTAssertNil(c.station.frozenMinutes)
    }

    func testDecodeHistory() throws {
        let json = """
        {"metric": "temperature", "range": "today", "start": 1793505600, "end": 1793592000, "bucket": 300,
         "points": [{"t": 1793505600, "v": 4.1}, {"t": 1793505900, "v": 4.3}],
         "min": {"t": 1793505600, "v": 4.1}, "max": {"t": 1793505900, "v": 4.3}}
        """
        let h = try JSONDecoder.collector.decode(HistorySeries.self, from: Data(json.utf8))
        XCTAssertEqual(h.points.count, 2)
        XCTAssertEqual(h.max?.v, 4.3)
    }

    func testUnits() {
        XCTAssertEqual(Quantity.temperature.convert(32.0, .metric), 0, accuracy: 1e-9)
        XCTAssertEqual(Quantity.pressure.convert(29.92, .metric), 1013.2, accuracy: 0.1)
        XCTAssertEqual((-0.2).formatted(decimals: 0), "0")
        XCTAssertEqual((-9.4).formatted(decimals: 0), "-9")
    }

    func testSevenSegmentGlyphs() {
        let g = SevenSegment.glyphs(for: "29.57", cells: 4)
        XCTAssertEqual(g.count, 4)
        XCTAssertEqual(g[1], .digit(mask: SevenSegment.masks["9"]!, dot: true))
        // Right-aligned with blank padding
        XCTAssertEqual(SevenSegment.glyphs(for: "-9", cells: 3).first, .digit(mask: 0, dot: false))
        XCTAssertEqual(SevenSegment.glyphs(for: "07:10", cells: 4)[2], .colon(on: true))
    }
}
