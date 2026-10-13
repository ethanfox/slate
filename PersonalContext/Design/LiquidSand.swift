import SwiftUI

/// Membrae's "liquid sand": grainy bands of color dragged across at a slant. A placeholder where
/// there is no picture. It is drawn from a few colors, so it can match whatever it sits in.
struct LiquidSand: View {
    /// Hex colors, dark to light. Two or more.
    var colors: [String]
    /// 0 keeps the bands straight. 1 marbles them.
    var swirl: Double = 0.45
    /// Changes the pattern without changing the colors, so neighbors do not match.
    var seed: UInt64 = 0

    @State private var image: CGImage?

    private var spec: LiquidSandSpec {
        LiquidSandSpec(colors: colors, swirl: swirl, seed: seed)
    }

    var body: some View {
        LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: spec) {
                if let hit = LiquidSandCache.image(for: spec) {
                    image = hit
                    return
                }
                let spec = spec
                let drawn = await Task.detached(priority: .utility) { LiquidSandRenderer.draw(spec) }.value
                guard !Task.isCancelled, let drawn else { return }
                LiquidSandCache.store(drawn, for: spec)
                withAnimation(.easeOut(duration: 0.2)) { image = drawn }
            }
            .accessibilityHidden(true)
    }
}

extension LiquidSand {
    /// A seed that stays the same for one thing, so its pattern does not change between launches.
    static func seed(for id: UUID) -> UInt64 {
        withUnsafeBytes(of: id.uuid) { $0.loadUnaligned(as: UInt64.self) }
    }
}

struct LiquidSandSpec: Hashable, Sendable {
    var colors: [String]
    var swirl: Double
    var seed: UInt64
}

@MainActor
enum LiquidSandCache {
    private static var images: [LiquidSandSpec: CGImage] = [:]
    private static var order: [LiquidSandSpec] = []
    private static let limit = 120

    static func image(for spec: LiquidSandSpec) -> CGImage? {
        images[spec]
    }

    static func store(_ image: CGImage, for spec: LiquidSandSpec) {
        if images[spec] == nil { order.append(spec) }
        images[spec] = image
        while order.count > limit {
            images[order.removeFirst()] = nil
        }
    }
}

enum LiquidSandRenderer {
    static let width = 480
    static let height = 300

    static func draw(_ spec: LiquidSandSpec) -> CGImage? {
        let palette = palette(spec.colors)
        guard palette.count >= 2 else { return nil }
        let seed = spec.seed
        let swirl = min(max(spec.swirl, 0), 1)
        // Each pattern leans a little differently and starts somewhere else in the noise.
        let angle = -0.62 + (unit(seed, 11) - 0.5) * 0.5
        let (sinA, cosA) = (sin(angle), cos(angle))
        let offsetU = unit(seed, 23) * 400
        let offsetV = unit(seed, 37) * 400

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let scale = 1 / Double(height)
        for y in 0..<height {
            for x in 0..<width {
                let px = Double(x) * scale
                let py = Double(y) * scale
                // u runs along the bands, v across them.
                var u = px * cosA - py * sinA + offsetU
                var v = px * sinA + py * cosA + offsetV
                if swirl > 0 {
                    let bendV = fbm(u * 0.9, v * 1.3, seed &+ 1, octaves: 2) - 0.5
                    let bendU = fbm(u * 1.1 + 40, v * 0.9 + 17, seed &+ 2, octaves: 2) - 0.5
                    v += bendV * swirl * 1.1
                    u += bendU * swirl * 0.9
                }
                // Stretched along the band, so color changes fast across and slowly along.
                let band = fbm(u * 0.45, v * 5.4, seed &+ 3, octaves: 3)
                let shade = fbm(u * 0.3 + 9, v * 6.5 + 4, seed &+ 4, octaves: 2)
                let position = min(max((band - 0.22) * 1.8, 0), 1)
                var color = sample(palette, at: position)
                // Dark seams between bands, and sand: every grain a little lighter or darker.
                let depth = 0.55 + 0.6 * smooth(shade)
                let grain = (hash(UInt64(x), UInt64(y), seed &+ 5) - 0.5) * 0.26
                let light = depth + grain * (0.6 + 0.8 * shade)
                color.r *= light
                color.g *= light
                color.b *= light
                let index = (y * width + x) * 4
                pixels[index] = byte(color.r)
                pixels[index + 1] = byte(color.g)
                pixels[index + 2] = byte(color.b)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    // MARK: Color

    private struct RGB {
        var r: Double
        var g: Double
        var b: Double
    }

    /// The given colors, with a deeper one in front so the bands have somewhere dark to fall to.
    private static func palette(_ hexes: [String]) -> [RGB] {
        let colors = hexes.compactMap(rgb)
        guard let first = colors.first else { return [] }
        return [RGB(r: first.r * 0.45, g: first.g * 0.45, b: first.b * 0.5)] + colors
    }

    private static func rgb(_ hex: String) -> RGB? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        return RGB(
            r: Double(value >> 16 & 0xFF) / 255,
            g: Double(value >> 8 & 0xFF) / 255,
            b: Double(value & 0xFF) / 255
        )
    }

    private static func sample(_ palette: [RGB], at position: Double) -> RGB {
        let scaled = position * Double(palette.count - 1)
        let lower = min(Int(scaled), palette.count - 2)
        let t = smooth(scaled - Double(lower))
        let (a, b) = (palette[lower], palette[lower + 1])
        return RGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
    }

    private static func byte(_ value: Double) -> UInt8 {
        UInt8(min(max(value, 0), 1) * 255)
    }

    // MARK: Noise

    private static func smooth(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 0 to 1, the same for the same inputs.
    private static func hash(_ x: UInt64, _ y: UInt64, _ seed: UInt64) -> Double {
        var h = x &* 0x9E37_79B9_7F4A_7C15 ^ y &* 0xC2B2_AE3D_27D4_EB4F ^ seed &* 0x1656_67B1_9E37_79F9
        h ^= h >> 31
        h &*= 0xBF58_476D_1CE4_E5B9
        h ^= h >> 29
        return Double(h >> 11) / Double(1 << 53)
    }

    private static func unit(_ seed: UInt64, _ salt: UInt64) -> Double {
        hash(salt, salt &* 7, seed)
    }

    private static func noise(_ x: Double, _ y: Double, _ seed: UInt64) -> Double {
        let (fx, fy) = (x.rounded(.down), y.rounded(.down))
        let (ix, iy) = (UInt64(bitPattern: Int64(fx)), UInt64(bitPattern: Int64(fy)))
        let (tx, ty) = (smooth(x - fx), smooth(y - fy))
        let top = hash(ix, iy, seed) * (1 - tx) + hash(ix &+ 1, iy, seed) * tx
        let bottom = hash(ix, iy &+ 1, seed) * (1 - tx) + hash(ix &+ 1, iy &+ 1, seed) * tx
        return top * (1 - ty) + bottom * ty
    }

    private static func fbm(_ x: Double, _ y: Double, _ seed: UInt64, octaves: Int) -> Double {
        var (total, weight, amplitude, frequency) = (0.0, 0.0, 1.0, 1.0)
        for octave in 0..<octaves {
            total += noise(x * frequency, y * frequency, seed &+ UInt64(octave) &* 101) * amplitude
            weight += amplitude
            amplitude *= 0.5
            frequency *= 2.1
        }
        return total / weight
    }
}
