import AppKit
import SwiftUI

enum CountdownStyle: String, Codable, CaseIterable, Identifiable, Hashable {
    case figure
    case units
    case dial

    var id: String { rawValue }

    var label: String {
        switch self {
        case .figure: "Number"
        case .units: "Units"
        case .dial: "Dial"
        }
    }
}

enum CountdownTypeface: String, Codable, CaseIterable, Identifiable, Hashable {
    case normal
    case mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: "Sans serif"
        case .mono: "Mono"
        }
    }

    var design: Font.Design {
        switch self {
        case .normal: .default
        case .mono: .monospaced
        }
    }
}

enum CountdownWeight: String, Codable, CaseIterable, Identifiable, Hashable {
    case light
    case medium
    case bold

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: "Light"
        case .medium: "Medium"
        case .bold: "Bold"
        }
    }

    var fontWeight: Font.Weight {
        switch self {
        case .light: .light
        case .medium: .medium
        case .bold: .bold
        }
    }

    var nsWeight: NSFont.Weight {
        switch self {
        case .light: .light
        case .medium: .medium
        case .bold: .bold
        }
    }
}

struct CountdownWidgetSettings: Codable, Equatable, Hashable {
    var title: String
    var target: Date
    var start: Date
    var style: CountdownStyle
    var typeface: CountdownTypeface
    var weight: CountdownWeight
    var textHex: String
    var dialHex: String
    var gradient: WidgetGradient

    static let `default` = CountdownWidgetSettings(
        title: "",
        target: Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now,
        start: .now,
        style: .figure,
        typeface: .normal,
        weight: .medium,
        textHex: "F4F0E8",
        dialHex: "E4DDD0",
        gradient: .default
    )

    init(
        title: String,
        target: Date,
        start: Date,
        style: CountdownStyle,
        typeface: CountdownTypeface,
        weight: CountdownWeight,
        textHex: String,
        dialHex: String,
        gradient: WidgetGradient = .default
    ) {
        self.title = title
        self.target = target
        self.start = start
        self.style = style
        self.typeface = typeface
        self.weight = weight
        self.textHex = textHex
        self.dialHex = dialHex
        self.gradient = gradient
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? Self.default.title
        target = try container.decodeIfPresent(Date.self, forKey: .target) ?? Self.default.target
        start = try container.decodeIfPresent(Date.self, forKey: .start) ?? Self.default.start
        style = try container.decodeIfPresent(CountdownStyle.self, forKey: .style) ?? .figure
        typeface = try container.decodeIfPresent(CountdownTypeface.self, forKey: .typeface) ?? .normal
        weight = try container.decodeIfPresent(CountdownWeight.self, forKey: .weight) ?? .medium
        textHex = try container.decodeIfPresent(String.self, forKey: .textHex) ?? Self.default.textHex
        dialHex = try container.decodeIfPresent(String.self, forKey: .dialHex) ?? Self.default.dialHex
        gradient = try container.decodeIfPresent(WidgetGradient.self, forKey: .gradient) ?? .default
    }

    static func decode(_ raw: String) -> CountdownWidgetSettings {
        guard let data = raw.data(using: .utf8),
              let settings = try? JSONDecoder().decode(CountdownWidgetSettings.self, from: data)
        else { return .default }
        return settings
    }

    var encoded: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    var textColor: Color { Color(hex: textHex) }
    var dialColor: Color { Color(hex: dialHex) }

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CountdownReading {
    var remaining: TimeInterval
    var days: Int
    var hours: Int
    var minutes: Int
    var progress: Double
    var isPast: Bool

    init(now: Date, target: Date, start: Date) {
        remaining = target.timeIntervalSince(now)
        isPast = remaining <= 0
        let clamped = max(0, remaining)
        days = Int(clamped) / 86_400
        hours = (Int(clamped) % 86_400) / 3_600
        minutes = (Int(clamped) % 3_600) / 60
        let span = target.timeIntervalSince(min(start, target))
        if span <= 0 {
            progress = isPast ? 0 : 1
        } else {
            progress = min(1, max(0, remaining / span))
        }
    }

    var heroValue: Int {
        if isPast { return 0 }
        if days >= 1 { return days }
        if remaining >= 3_600 { return hours }
        return minutes
    }

    var heroUnit: String {
        if isPast { return "now" }
        if days >= 1 { return days == 1 ? "day" : "days" }
        if remaining >= 3_600 { return hours == 1 ? "hour" : "hours" }
        return minutes == 1 ? "minute" : "minutes"
    }

    var spoken: String {
        if isPast { return "ended" }
        if days >= 1 { return "\(days) \(days == 1 ? "day" : "days") remaining" }
        if remaining >= 3_600 { return "\(hours) \(hours == 1 ? "hour" : "hours") remaining" }
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes") remaining"
    }
}

struct CountdownWidgetView: View {
    var settings: CountdownWidgetSettings
    var size: OverviewWidgetSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let reading = CountdownReading(now: timeline.date, target: settings.target, start: settings.start)
            face(reading)
                .padding(settings.style == .dial ? 0 : inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .widgetSurface(settings.gradient)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText(reading))
        }
    }

    @ViewBuilder
    private func face(_ reading: CountdownReading) -> some View {
        switch settings.style {
        case .figure:
            CountdownFigureFace(settings: settings, size: size, reading: reading, reduceMotion: reduceMotion)
        case .units:
            CountdownUnitsFace(settings: settings, size: size, reading: reading, reduceMotion: reduceMotion)
        case .dial:
            CountdownDialFace(settings: settings, size: size, reading: reading, reduceMotion: reduceMotion)
        }
    }

    private var inset: CGFloat {
        switch size {
        case .small: 14
        case .medium, .large: 16
        }
    }

    private func accessibilityText(_ reading: CountdownReading) -> String {
        let title = settings.displayTitle
        if title.isEmpty { return reading.spoken }
        return "\(title), \(reading.spoken)"
    }
}

private enum OpticalCenter {
    static func nudge(for string: String, font: NSFont, tracking: CGFloat) -> OpticalNudge {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: [
                .font: font,
                .kern: tracking,
                .foregroundColor: NSColor.white
            ])
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let height = ascent + descent
        guard width > 1, height > 1 else { return OpticalNudge(x: 0, y: 0, width: width) }

        let scale: CGFloat = 3
        let pixelWidth = max(1, Int(ceil(width * scale)))
        let pixelHeight = max(1, Int(ceil(height * scale)))
        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        return pixels.withUnsafeMutableBufferPointer { buffer in
            guard let data = buffer.baseAddress,
                  let context = CGContext(
                    data: data,
                    width: pixelWidth,
                    height: pixelHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: pixelWidth,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return OpticalNudge(x: 0, y: 0, width: width) }

            context.scaleBy(x: scale, y: scale)
            context.textPosition = CGPoint(x: 0, y: descent)
            CTLineDraw(line, context)

            var mass = 0.0
            var momentX = 0.0
            var momentY = 0.0
            for y in 0..<pixelHeight {
                let row = y * pixelWidth
                for x in 0..<pixelWidth {
                    let coverage = Double(buffer[row + x])
                    guard coverage > 12 else { continue }
                    mass += coverage
                    momentX += coverage * Double(x)
                    momentY += coverage * Double(y)
                }
            }
            guard mass > 0 else { return OpticalNudge(x: 0, y: 0, width: width) }

            let inkX = CGFloat(momentX / mass) / scale
            let inkY = CGFloat(momentY / mass) / scale
            return OpticalNudge(x: width / 2 - inkX, y: inkY - height / 2, width: width)
        }
    }
}

private struct OpticalNudge {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var offset: CGSize { CGSize(width: x, height: y) }
}

private enum HangPlacement {
    case centered
    case numberLeading
}

private struct CountdownOpticalNumber<Hang: View>: View {
    var value: Int
    var fontSize: CGFloat
    var settings: CountdownWidgetSettings
    var reduceMotion: Bool
    var hangPlacement: HangPlacement = .centered
    var clusterAlignment: Alignment = .center
    @ViewBuilder var hang: () -> Hang

    var body: some View {
        let text = "\(value)"
        let nsFont = settings.displayFont(size: fontSize)
        let tracking = settings.tracking(for: fontSize)
        let nudge = OpticalCenter.nudge(for: text, font: nsFont, tracking: tracking)
        ZStack {
            Text(text)
                .font(settings.font(size: fontSize))
                .tracking(tracking)
                .foregroundStyle(settings.textColor)
                .lineLimit(1)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(reduceMotion ? Motion.quick : Motion.snappy, value: value)
                .offset(nudge.offset)
            hangLabel(nudge: nudge, font: nsFont)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: clusterAlignment)
    }

    @ViewBuilder
    private func hangLabel(nudge: OpticalNudge, font: NSFont) -> some View {
        let captions = VStack(alignment: hangPlacement == .centered ? .center : .leading, spacing: 6) {
            hang()
        }
        .multilineTextAlignment(hangPlacement == .centered ? .center : .leading)
        let below = font.capHeight / 2 + (hangPlacement == .centered ? 16 : 6)
        switch hangPlacement {
        case .centered:
            captions.offset(y: below)
        case .numberLeading:
            Color.clear
                .frame(width: nudge.width, height: 0)
                .offset(x: nudge.x)
                .overlay(alignment: .topLeading) {
                    captions.offset(y: below)
                }
        }
    }
}

private struct CountdownFigureFace: View {
    var settings: CountdownWidgetSettings
    var size: OverviewWidgetSize
    var reading: CountdownReading
    var reduceMotion: Bool

    var body: some View {
        let wide = size == .medium
        ZStack(alignment: wide ? .topLeading : .top) {
            CountdownOpticalNumber(
                value: reading.heroValue,
                fontSize: figureSize,
                settings: settings,
                reduceMotion: reduceMotion,
                clusterAlignment: wide ? .leading : .center
            ) {
                Text(reading.heroUnit)
                    .font(settings.font(size: size == .large ? 13 : 12))
                    .foregroundStyle(settings.textColor.opacity(0.55))
                if size != .small {
                    dateCaption
                }
            }
            if !settings.displayTitle.isEmpty {
                Text(settings.displayTitle)
                    .font(settings.font(size: size == .small ? 13 : 15, weight: .medium))
                    .foregroundStyle(settings.textColor.opacity(0.72))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
            }
        }
    }

    private var dateCaption: some View {
        Text(settings.target.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
            .font(settings.font(size: 12))
            .foregroundStyle(settings.textColor.opacity(0.48))
    }

    private var figureSize: CGFloat {
        switch size {
        case .small: 52
        case .medium: 56
        case .large: 72
        }
    }
}

private struct CountdownUnitsFace: View {
    var settings: CountdownWidgetSettings
    var size: OverviewWidgetSize
    var reading: CountdownReading
    var reduceMotion: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                unitColumn(reading.days, label: size == .small ? "d" : (reading.days == 1 ? "day" : "days"))
                unitColumn(reading.hours, label: size == .small ? "h" : (reading.hours == 1 ? "hour" : "hours"))
                unitColumn(reading.minutes, label: size == .small ? "m" : "min")
            }
            if !settings.displayTitle.isEmpty {
                Text(settings.displayTitle)
                    .font(settings.font(size: size == .small ? 13 : 15, weight: .medium))
                    .foregroundStyle(settings.textColor.opacity(0.72))
                    .lineLimit(1)
            }
        }
    }

    private func unitColumn(_ value: Int, label: String) -> some View {
        CountdownOpticalNumber(
            value: value,
            fontSize: valueSize,
            settings: settings,
            reduceMotion: reduceMotion,
            hangPlacement: .numberLeading
        ) {
            Text(label)
                .font(settings.font(size: 11))
                .foregroundStyle(settings.textColor.opacity(0.5))
        }
    }

    private var valueSize: CGFloat {
        switch size {
        case .small: 26
        case .medium: 32
        case .large: 40
        }
    }
}

private struct CountdownDialFace: View {
    var settings: CountdownWidgetSettings
    var size: OverviewWidgetSize
    var reading: CountdownReading
    var reduceMotion: Bool

    var body: some View {
        GeometryReader { geo in
            let diameter = geo.size.width * 1.5
            let radius = diameter / 2
            let cap = geo.size.height * 0.26
            ZStack {
                TimelineView(.animation(minimumInterval: reduceMotion ? 60 : 1 / 30)) { timeline in
                    let turn = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60) / 60
                    SwissCountdownDial(color: settings.dialColor)
                        .frame(width: diameter, height: diameter)
                        .rotationEffect(.degrees(reduceMotion ? 0 : turn * 360))
                        .position(x: geo.size.width / 2, y: geo.size.height + radius - cap)
                }

                CountdownOpticalNumber(
                    value: reading.heroValue,
                    fontSize: figureSize,
                    settings: settings,
                    reduceMotion: reduceMotion
                ) {
                    Text(reading.heroUnit)
                        .font(settings.font(size: 12))
                        .foregroundStyle(settings.textColor.opacity(0.55))
                }
                .padding(.horizontal, size == .small ? 14 : 16)
                .offset(y: size == .large ? 0 : -8)

                if !settings.displayTitle.isEmpty {
                    Text(settings.displayTitle)
                        .font(settings.font(size: size == .small ? 13 : 15, weight: .medium))
                        .foregroundStyle(settings.textColor.opacity(0.72))
                        .lineLimit(1)
                        .padding(.top, size == .medium ? 16 : 22)
                        .padding(.horizontal, size == .small ? 14 : 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .clipped()
    }

    private var figureSize: CGFloat {
        switch size {
        case .small: 60
        case .medium: 72
        case .large: 84
        }
    }
}

private struct SwissCountdownDial: View {
    var color: Color

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            let outer = radius * 0.98
            let inner = radius * 0.8425
            let line = max(2.8, radius * 0.028)
            for index in 0..<60 {
                let angle = Angle.degrees(Double(index) * 6 - 90)
                var tick = Path()
                tick.move(to: point(center: center, radius: inner, angle: angle))
                tick.addLine(to: point(center: center, radius: outer, angle: angle))
                context.stroke(tick, with: .color(color), style: StrokeStyle(lineWidth: line, lineCap: .butt))
            }
        }
        .accessibilityHidden(true)
    }

    private func point(center: CGPoint, radius: CGFloat, angle: Angle) -> CGPoint {
        CGPoint(
            x: center.x + CGFloat(cos(angle.radians)) * radius,
            y: center.y + CGFloat(sin(angle.radians)) * radius
        )
    }
}

struct CountdownWidgetFields: View {
    @Binding var settings: CountdownWidgetSettings
    @State private var pickingTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ModalField("Title") {
                TextField("Launch", text: $settings.title)
                    .textFieldStyle(.plain)
            }

            ModalControlRow("Target") {
                ModalDateField(date: $settings.target, includesTime: true, isPresented: $pickingTarget)
            }

            InspectorChoiceGroup(
                "Style",
                items: CountdownStyle.allCases,
                selection: $settings.style,
                label: \.label
            )

            InspectorChoiceGroup(
                "Typeface",
                items: CountdownTypeface.allCases,
                selection: $settings.typeface,
                label: \.label,
                font: { Font.system(size: 13, design: $0.design) }
            )

            InspectorChoiceGroup(
                "Weight",
                items: CountdownWeight.allCases,
                selection: $settings.weight,
                label: \.label,
                font: { Font.system(size: 13, weight: $0.fontWeight) }
            )

            ModalControlRow("Text") {
                ColorPicker("Text", selection: hexBinding(\.textHex), supportsOpacity: false)
                    .labelsHidden()
            }

            if settings.style == .dial {
                ModalControlRow("Dial") {
                    ColorPicker("Dial", selection: hexBinding(\.dialHex), supportsOpacity: false)
                        .labelsHidden()
                }
            }

            WidgetGradientFields(gradient: $settings.gradient)
        }
    }

    private func hexBinding(_ keyPath: WritableKeyPath<CountdownWidgetSettings, String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: settings[keyPath: keyPath]) },
            set: { settings[keyPath: keyPath] = $0.hexString }
        )
    }
}

private extension CountdownWidgetSettings {
    func font(size: CGFloat, weight: Font.Weight? = nil) -> Font {
        let resolved = weight ?? self.weight.fontWeight
        let base = Font.system(size: size, weight: resolved, design: typeface.design).leading(.tight)
        return typeface == .mono ? base : base.monospacedDigit()
    }

    func tracking(for fontSize: CGFloat) -> CGFloat {
        fontSize >= 40 ? -0.6 : 0
    }

    func displayFont(size: CGFloat) -> NSFont {
        let base = typeface == .mono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight.nsWeight)
            : NSFont.systemFont(ofSize: size, weight: weight.nsWeight)
        guard typeface != .mono else { return base }
        let descriptor = base.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
            ]]
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}
