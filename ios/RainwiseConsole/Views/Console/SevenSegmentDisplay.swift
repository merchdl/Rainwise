import SwiftUI

/// Draws text as slanted seven-segment LED digits, right-aligned in `cells`
/// digit positions, with faint unlit segments and a soft glow.
///
/// Supports 0-9, space, '-', a few letters, '.' (attached to the previous
/// digit), ':' (narrow colon) and ';' (unlit colon, for blinking).
struct SevenSegmentDisplay: View {
    var text: String
    var cells: Int
    var color: Color = ConsoleTheme.led
    @Environment(\.ledBrightness) private var brightness

    var body: some View {
        Canvas { context, size in
            let glyphs = SevenSegment.glyphs(for: text, cells: cells)
            let lit = SevenSegment.path(for: glyphs, in: size, lit: true)
            let ghost = SevenSegment.path(for: glyphs, in: size, lit: false)
            context.fill(ghost, with: .color(color.opacity(0.07)))
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: color.opacity(0.55 * brightness), radius: size.height * 0.05))
                layer.fill(lit, with: .color(color.opacity(brightness)))
            }
        }
        .accessibilityLabel(text.trimmingCharacters(in: .whitespaces))
    }
}

enum SevenSegment {
    enum Glyph: Equatable {
        case digit(mask: UInt8, dot: Bool)
        case colon(on: Bool)
    }

    // Segment bits: a=top, b=top right, c=bottom right, d=bottom, e=bottom left, f=top left, g=middle
    static let masks: [Character: UInt8] = [
        "0": 0b0111111, "1": 0b0000110, "2": 0b1011011, "3": 0b1001111, "4": 0b1100110,
        "5": 0b1101101, "6": 0b1111101, "7": 0b0000111, "8": 0b1111111, "9": 0b1101111,
        "-": 0b1000000, " ": 0, "_": 0b0001000,
        "A": 0b1110111, "C": 0b0111001, "E": 0b1111001, "F": 0b1110001, "H": 0b1110110,
        "L": 0b0111000, "P": 0b1110011, "U": 0b0111110, "d": 0b1011110, "n": 0b1010100,
        "o": 0b1011100, "r": 0b1010000, "t": 0b1111000, "u": 0b0011100,
    ]

    static func glyphs(for text: String, cells: Int) -> [Glyph] {
        var out: [Glyph] = []
        for ch in text {
            if ch == "." {
                if case .digit(let m, false)? = out.last {
                    out[out.count - 1] = .digit(mask: m, dot: true)
                } else {
                    out.append(.digit(mask: 0, dot: true))
                }
            } else if ch == ":" || ch == ";" {
                out.append(.colon(on: ch == ":"))
            } else {
                out.append(.digit(mask: masks[ch] ?? 0, dot: false))
            }
        }
        let digits = out.filter { if case .digit = $0 { return true } else { return false } }.count
        if digits < cells {
            out.insert(contentsOf: Array(repeating: Glyph.digit(mask: 0, dot: false), count: cells - digits), at: 0)
        }
        return out
    }

    /// One path holding either the lit segments or all segments (for the ghost layer).
    static func path(for glyphs: [Glyph], in size: CGSize, lit: Bool) -> Path {
        let digitCount = CGFloat(glyphs.filter { if case .digit = $0 { return true } else { return false } }.count)
        let colonCount = CGFloat(glyphs.count) - digitCount
        let skew: CGFloat = 0.09
        let h = size.height
        // width = n*w + (n-1)*gap + colons*colonW + skew*h, with gap = 0.34w, colonW = 0.4w
        let usable = size.width - skew * h
        let w = min(h * 0.54, usable / (digitCount + max(digitCount - 1, 0) * 0.34 + colonCount * 0.4))
        let gap = w * 0.34
        let colonW = w * 0.4
        let totalW = digitCount * w + max(digitCount - 1, 0) * gap + colonCount * colonW + skew * h
        var x = size.width - totalW  // right-aligned

        var path = Path()
        let shear = CGAffineTransform(a: 1, b: 0, c: -skew, d: 1, tx: skew * h, ty: 0)
        for g in glyphs {
            switch g {
            case .digit(let mask, let dot):
                let m = lit ? mask : 0b1111111
                path.addPath(digitPath(mask: m, w: w, h: h).applying(shear.concatenating(.init(translationX: x, y: 0))))
                if dot {
                    let t = w * 0.2
                    let d = t * 1.1
                    path.addEllipse(in: CGRect(x: x + w + gap * 0.5 - d / 2, y: h - d, width: d, height: d))
                }
                x += w + gap
            case .colon(let on):
                let t = w * 0.2
                let cx = x - gap * 0.5 + colonW * 0.5
                for cy in [h * 0.32, h * 0.68] where on || !lit {
                    let r = CGRect(x: cx - t * 0.55, y: cy - t * 0.55, width: t * 1.1, height: t * 1.1)
                    let shifted = r.offsetBy(dx: skew * (h - cy), dy: 0)
                    path.addEllipse(in: shifted)
                }
                x += colonW
            }
        }
        return path
    }

    static func digitPath(mask: UInt8, w: CGFloat, h: CGFloat) -> Path {
        let t = w * 0.2
        let g = t * 0.14
        let l = t / 2, r = w - t / 2, top = t / 2, mid = h / 2, bot = h - t / 2
        var p = Path()

        func hseg(_ x1: CGFloat, _ x2: CGFloat, _ y: CGFloat) {
            let a = x1 + g, b = x2 - g
            p.move(to: CGPoint(x: a, y: y))
            p.addLine(to: CGPoint(x: a + t / 2, y: y - t / 2))
            p.addLine(to: CGPoint(x: b - t / 2, y: y - t / 2))
            p.addLine(to: CGPoint(x: b, y: y))
            p.addLine(to: CGPoint(x: b - t / 2, y: y + t / 2))
            p.addLine(to: CGPoint(x: a + t / 2, y: y + t / 2))
            p.closeSubpath()
        }

        func vseg(_ x: CGFloat, _ y1: CGFloat, _ y2: CGFloat) {
            let a = y1 + g, b = y2 - g
            p.move(to: CGPoint(x: x, y: a))
            p.addLine(to: CGPoint(x: x + t / 2, y: a + t / 2))
            p.addLine(to: CGPoint(x: x + t / 2, y: b - t / 2))
            p.addLine(to: CGPoint(x: x, y: b))
            p.addLine(to: CGPoint(x: x - t / 2, y: b - t / 2))
            p.addLine(to: CGPoint(x: x - t / 2, y: a + t / 2))
            p.closeSubpath()
        }

        if mask & 0b0000001 != 0 { hseg(l, r, top) }  // a
        if mask & 0b0000010 != 0 { vseg(r, top, mid) }  // b
        if mask & 0b0000100 != 0 { vseg(r, mid, bot) }  // c
        if mask & 0b0001000 != 0 { hseg(l, r, bot) }  // d
        if mask & 0b0010000 != 0 { vseg(l, mid, bot) }  // e
        if mask & 0b0100000 != 0 { vseg(l, top, mid) }  // f
        if mask & 0b1000000 != 0 { hseg(l, r, mid) }  // g
        return p
    }
}

#Preview {
    VStack(spacing: 12) {
        DisplayWindow(text: "29.57", cells: 4, width: 190, height: 72)
        DisplayWindow(text: "-16", cells: 3, width: 190, height: 72)
        DisplayWindow(text: "07:10", cells: 4, width: 190, height: 72)
    }
    .padding()
    .background(ConsoleTheme.background)
}
