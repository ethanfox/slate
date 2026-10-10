import AppKit
import SwiftUI

struct OrbPalette: Equatable, Codable, Sendable {
    var sky: String
    var horizon: String
    var ember: String
    var ink: String

    static let membrae = OrbPalette(
        sky: "08050B",
        horizon: "2F516A",
        ember: "46688C",
        ink: "08050B"
    )

    static let legacy = OrbPalette(
        sky: "8188A0",
        horizon: "3F4352",
        ember: "C4843C",
        ink: "0A0806"
    )

    static let error = OrbPalette(
        sky: "F9A8D4",
        horizon: "EC4899",
        ember: "F472B6",
        ink: "831843"
    )

    var skyColor: Color { Color(hex: sky) }
    var horizonColor: Color { Color(hex: horizon) }
    var emberColor: Color { Color(hex: ember) }
    var inkColor: Color { Color(hex: ink) }

    var metalColors: (sky: SIMD4<Float>, horizon: SIMD4<Float>, ember: SIMD4<Float>, ink: SIMD4<Float>) {
        (Self.rgba(sky), Self.rgba(horizon), Self.rgba(ember), Self.rgba(ink))
    }

    private static func rgba(_ hex: String) -> SIMD4<Float> {
        let color = NSColor(Color(hex: hex)).usingColorSpace(.sRGB)
        return SIMD4(
            Float(color?.redComponent ?? 0),
            Float(color?.greenComponent ?? 0),
            Float(color?.blueComponent ?? 0),
            1
        )
    }
}
