import SwiftData
import SwiftUI

enum NotesWidgetStyle: String, Codable, CaseIterable, Identifiable, Hashable {
    case list
    case cards

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: "List"
        case .cards: "Cards"
        }
    }
}

struct NotesWidgetSettings: Codable, Equatable, Hashable {
    var start: Date
    var end: Date
    var style: NotesWidgetStyle
    var gradient: WidgetGradient

    static let `default` = NotesWidgetSettings(
        start: Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .now,
        end: .now,
        style: .cards,
        gradient: .default
    )

    init(start: Date, end: Date, style: NotesWidgetStyle, gradient: WidgetGradient = .default) {
        self.start = start
        self.end = end
        self.style = style
        self.gradient = gradient
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decodeIfPresent(Date.self, forKey: .start) ?? Self.default.start
        end = try container.decodeIfPresent(Date.self, forKey: .end) ?? Self.default.end
        style = try container.decodeIfPresent(NotesWidgetStyle.self, forKey: .style) ?? .cards
        gradient = try container.decodeIfPresent(WidgetGradient.self, forKey: .gradient) ?? .default
    }

    static func decode(_ raw: String) -> NotesWidgetSettings {
        guard let data = raw.data(using: .utf8),
              let settings = try? JSONDecoder().decode(NotesWidgetSettings.self, from: data)
        else { return .default }
        return settings
    }

    var encoded: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct NotesWidgetView: View {
    var notes: [Note]
    var settings: NotesWidgetSettings
    var size: OverviewWidgetSize
    var interactive: Bool
    @Environment(AppModel.self) private var app
    @State private var hoveredID: UUID?

    var body: some View {
        Group {
            switch settings.style {
            case .list:
                listFace
            case .cards:
                cardsFace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetSurface(settings.gradient)
    }

    private var matching: [Note] {
        notes
            .filter { range.contains($0.updatedAt) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var visible: [Note] {
        Array(matching.prefix(limit))
    }

    private var limit: Int {
        switch settings.style {
        case .list:
            switch size {
            case .small, .medium: 2
            case .large: 4
            }
        case .cards:
            switch size {
            case .small: 3
            case .medium: 4
            case .large: 6
            }
        }
    }

    private var compact: Bool { size == .small }

    private var range: ClosedRange<Date> {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: min(settings.start, settings.end))
        let endDay = calendar.startOfDay(for: max(settings.start, settings.end))
        let end = calendar.date(byAdding: .day, value: 1, to: endDay)?.addingTimeInterval(-1) ?? settings.end
        return start...end
    }

    private var listFace: some View {
        VStack(spacing: compact ? 6 : 8) {
            if visible.isEmpty {
                WidgetRowPill(title: "No notes", meta: "", compact: compact, interactive: false, action: {})
            } else {
                ForEach(visible) { note in
                    WidgetRowPill(
                        title: note.displayTitle,
                        meta: snippet(for: note),
                        compact: compact,
                        interactive: interactive
                    ) {
                        app.open(note)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 14 : 16)
        .frame(maxWidth: .infinity)
    }

    private var cardsFace: some View {
        let inset: CGFloat = 12
        let concentric = max(8, OverviewWidgetMetrics.cornerRadius - inset)
        return VStack(spacing: compact ? -14 : -16) {
            if visible.isEmpty {
                NotesCascadeCard(
                    title: "No notes",
                    meta: "",
                    compact: compact,
                    isBottom: true,
                    concentric: concentric,
                    interactive: false,
                    action: {}
                )
            } else {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, note in
                    NotesCascadeCard(
                        title: note.displayTitle,
                        meta: snippet(for: note),
                        compact: compact,
                        isBottom: index == visible.count - 1,
                        concentric: concentric,
                        interactive: interactive,
                        hovering: hoveredID == note.id,
                        onHover: { hovering in
                            hoveredID = hovering ? note.id : (hoveredID == note.id ? nil : hoveredID)
                        }
                    ) {
                        app.open(note)
                    }
                    .zIndex(Double(index))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, inset)
        .padding(.top, inset)
        .padding(.bottom, compact ? 28 : 32)
    }

    private func snippet(for note: Note) -> String {
        let line = note.content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line
    }
}

private struct NotesCascadeCard: View {
    var title: String
    var meta: String
    var compact: Bool
    var isBottom: Bool
    var concentric: CGFloat
    var interactive: Bool
    var hovering: Bool = false
    var onHover: (Bool) -> Void = { _ in }
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 10,
            bottomLeadingRadius: isBottom ? concentric : 10,
            bottomTrailingRadius: isBottom ? concentric : 10,
            topTrailingRadius: 10,
            style: .continuous
        )
        let card = VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: compact ? 14 : 16, weight: .regular))
                .foregroundStyle(Color.black.opacity(0.82))
                .lineLimit(1)
            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.black.opacity(0.42))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, compact ? 14 : 16)
        .padding(.vertical, compact ? 12 : 14)
        .frame(maxWidth: .infinity, minHeight: compact ? 52 : 58, alignment: .leading)
        .background(Color.white, in: shape)
        .shadow(color: .black.opacity(hovering ? 0.22 : 0.14), radius: hovering ? 12 : 8, y: hovering ? 6 : 3)
        .contentShape(shape)
        .offset(y: hovering && !reduceMotion ? -10 : 0)
        .onHover(perform: onHover)
        .animation(Motion.hover, value: hovering)
        .accessibilityLabel(meta.isEmpty ? title : "\(title), \(meta)")

        if interactive {
            Button(action: action) { card }
                .buttonStyle(.plain)
        } else {
            card
        }
    }
}

struct NotesWidgetFields: View {
    @Binding var settings: NotesWidgetSettings
    @State private var pickingStart = false
    @State private var pickingEnd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Range")
                    .font(CraftFont.section)
                ModalControlRow("From") {
                    ModalDateField(date: $settings.start, includesTime: false, isPresented: $pickingStart)
                }
                ModalControlRow("To") {
                    ModalDateField(date: $settings.end, includesTime: false, isPresented: $pickingEnd)
                }
            }

            InspectorChoiceGroup(
                "Style",
                items: NotesWidgetStyle.allCases,
                selection: $settings.style,
                label: \.label
            )

            WidgetGradientFields(gradient: $settings.gradient)
        }
    }
}
