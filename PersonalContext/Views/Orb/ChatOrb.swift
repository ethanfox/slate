import SwiftUI

struct ChatOrb: View {
    var state: OrbState
    var palette: OrbPalette = .slate
    var status: String?
    var size: CGFloat = 168
    var showsStatus = true

    var body: some View {
        ZStack {
            LiquidOrbView(
                state: state == .idle ? .idle : .thinking,
                colorTint: colorTint
            )
            .frame(width: renderSize, height: renderSize)
            .scaleEffect(size / renderSize)
            .frame(width: size, height: size)
            .allowsHitTesting(false)

            if showsStatus {
                VStack(spacing: size * 0.045) {
                    Text(resolvedStatus)
                        .font(.system(size: max(11, size * 0.055), weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, size * 0.14)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(resolvedStatus)
        .accessibilityAddTraits(state.isBusy ? .updatesFrequently : [])
    }

    private var renderSize: CGFloat {
        size < 80 ? max(size * 4, 128) : size
    }

    private var resolvedStatus: String {
        let text = status ?? state.status
        return text.isEmpty ? state.title : text
    }

    private var colorTint: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)? {
        let colors = (state == .error ? OrbPalette.error : palette).metalColors
        if state != .error, palette == .slate || palette == .legacySlate {
            return nil
        }
        return (colors.sky, colors.horizon, colors.ember, colors.ink)
    }
}

#Preview {
    ChatOrb(state: .thinking, size: 220, showsStatus: false)
        .padding(40)
        .background(.black)
}
