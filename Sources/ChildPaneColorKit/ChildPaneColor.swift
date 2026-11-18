import SwiftUI

public enum ChildPaneTabColor: Int, CaseIterable, Codable, Equatable, Sendable {
    case rose = 0
    case gray = 1
    case cyan = 2
    case gold = 3
    case sage = 4
    case lavender = 5

    public static let paletteOrder: [ChildPaneTabColor] = [.rose, .gray, .cyan, .gold, .sage, .lavender]

    public var hex: UInt32 {
        switch self {
        case .rose: 0xEB83BA
        case .gray: 0x858785
        case .cyan: 0xA5DFEB
        case .gold: 0xC9A257
        case .sage: 0xA4B49B
        case .lavender: 0xB6A6CA
        }
    }

    public var fillColor: Color { Color(hex: hex) }

    public func fill(hovering: Bool) -> Color {
        let base = NSColor(hex: hex)
        if hovering, let lit = base.blended(withFraction: 0.12, of: .white) {
            return Color(nsColor: lit)
        }
        return fillColor
    }

    public func earTabTitleColor(colorScheme: ColorScheme) -> Color {
        let fill = earTabTitleRGB
        let darkFG = (red: 0.12, green: 0.12, blue: 0.13)
        let lightFG = (red: 0.96, green: 0.96, blue: 0.97)
        let darkRatio = Self.wcagContrastRatio(foreground: darkFG, background: fill)
        let lightRatio = Self.wcagContrastRatio(foreground: lightFG, background: fill)
        let useDark: Bool
        if darkRatio >= 4.5 && lightRatio >= 4.5 {
            useDark = colorScheme == .light
        } else if darkRatio >= lightRatio {
            useDark = true
        } else {
            useDark = false
        }
        let rgb = useDark ? darkFG : lightFG
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    public var earTabTitleRGB: (red: Double, green: Double, blue: Double) {
        let hex = self.hex
        return (
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255
        )
    }

    public static func wcagContrastRatio(foreground: (red: Double, green: Double, blue: Double),
                                         background: (red: Double, green: Double, blue: Double)) -> Double {
        let l1 = relativeLuminance(foreground)
        let l2 = relativeLuminance(background)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ rgb: (red: Double, green: Double, blue: Double)) -> Double {
        func chan(_ c: Double) -> Double {
            if c <= 0.03928 { return c / 12.92 }
            return pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * chan(rgb.red) + 0.7152 * chan(rgb.green) + 0.0722 * chan(rgb.blue)
    }

    public static func stored(_ raw: Int) -> ChildPaneTabColor? {
        ChildPaneTabColor(rawValue: raw)
    }
}

public enum ChildPaneColorAllocator {
    public static func pickNewColor(existingSiblingColors: [ChildPaneTabColor]) -> ChildPaneTabColor {
        let palette = ChildPaneTabColor.paletteOrder
        var counts: [ChildPaneTabColor: Int] = Dictionary(uniqueKeysWithValues: palette.map { ($0, 0) })
        for c in existingSiblingColors { counts[c, default: 0] += 1 }
        let minUsed = counts.values.min() ?? 0
        var candidates = palette.filter { counts[$0, default: 0] == minUsed }
        if candidates.count == 1 { return candidates[0] }

        let neighborColors = Set(existingSiblingColors.suffix(1))
        let withoutNeighbors = candidates.filter { !neighborColors.contains($0) }
        if !withoutNeighbors.isEmpty { candidates = withoutNeighbors }
        return candidates.min(by: { palette.firstIndex(of: $0)! < palette.firstIndex(of: $1)! })!
    }

    public static func restoredColor(saved: ChildPaneTabColor?, existingSiblingColors: [ChildPaneTabColor]) -> ChildPaneTabColor {
        if let saved { return saved }
        return pickNewColor(existingSiblingColors: existingSiblingColors)
    }
}

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
