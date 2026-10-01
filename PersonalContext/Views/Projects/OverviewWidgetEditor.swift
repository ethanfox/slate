import SwiftData
import SwiftUI

struct OverviewWidgetEditor: View {
    var project: Project
    var plateID: UUID
    var onScreen: CGSize
    @Environment(\.modalDismiss) private var modalDismiss
    @Environment(\.modalInnerSize) private var inner
    @State private var size: OverviewWidgetSize
    @State private var focusSettings: FocusWidgetSettings
    @State private var notesSettings: NotesWidgetSettings
    private let sourceSize: OverviewWidgetSize

    init(project: Project, plateID: UUID, onScreen: CGSize) {
        self.project = project
        self.plateID = plateID
        self.onScreen = onScreen
        let plate = project.overviewPlates.first(where: { $0.id == plateID })
        let opened = plate?.size ?? .medium
        let json = plate?.settingsJSON ?? ""
        sourceSize = opened
        _size = State(initialValue: opened)
        _focusSettings = State(initialValue: FocusWidgetSettings.decode(json))
        _notesSettings = State(initialValue: NotesWidgetSettings.decode(json))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit \(kind.label)")
                .font(CraftFont.title)

            ModalScroll {
                if sideBySide {
                    HStack(alignment: .top, spacing: 16) {
                        preview
                        fields
                            .frame(minWidth: Self.fieldsMinWidth, maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        preview
                            .frame(maxWidth: .infinity, alignment: .center)
                        fields
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            ModalFooter(actionTitle: "Save", action: save)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let fieldsMinWidth: CGFloat = 180

    private var kind: OverviewWidgetKind {
        project.overviewPlates.first(where: { $0.id == plateID })?.kind ?? .focus
    }

    private var cell: CGFloat {
        let columns = max(1, sourceSize.columns)
        let width = onScreen.width
        guard width > 1 else { return OverviewGridMetrics.minCell }
        return max(1, (width - CGFloat(columns - 1) * OverviewGridMetrics.gap) / CGFloat(columns))
    }

    private var naturalPreview: CGSize {
        let gap = OverviewGridMetrics.gap
        let width = CGFloat(size.columns) * cell + CGFloat(max(0, size.columns - 1)) * gap
        let height = CGFloat(size.rows) * cell + CGFloat(max(0, size.rows - 1)) * gap
        return CGSize(width: width, height: height)
    }

    private var previewSlot: CGSize {
        let gap = OverviewGridMetrics.gap
        return CGSize(width: 2 * cell + gap, height: 2 * cell + gap)
    }

    private var sideBySide: Bool {
        let needed = previewSlot.width + 16 + Self.fieldsMinWidth
        return inner.width <= 0 || needed <= inner.width
    }

    private var previewScale: CGFloat {
        let maxWidth: CGFloat = {
            if inner.width <= 0 { return previewSlot.width }
            if sideBySide { return max(inner.width - 16 - Self.fieldsMinWidth, 80) }
            return inner.width
        }()
        guard previewSlot.width > 0 else { return 1 }
        return min(1, maxWidth / previewSlot.width)
    }

    private var preview: some View {
        let natural = naturalPreview
        let scale = previewScale
        let slot = previewSlot
        return OverviewWidgetFace(
            project: project,
            plate: OverviewPlate(id: plateID, size: size, kind: kind, settingsJSON: draftJSON),
            editing: false,
            interactive: false
        )
        .frame(width: natural.width, height: natural.height)
        .scaleEffect(scale, anchor: .center)
        .frame(width: natural.width * scale, height: natural.height * scale)
        .frame(width: slot.width * scale, height: slot.height * scale, alignment: .center)
    }

    @ViewBuilder
    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            ModalControlRow("Size") {
                GlassCapsuleSwitcher(
                    items: OverviewWidgetSize.allCases,
                    selection: $size,
                    symbol: \.symbol,
                    label: \.label,
                    accessibilityLabel: "Size"
                )
            }

            switch kind {
            case .focus:
                FocusWidgetFields(settings: $focusSettings)
            case .notes:
                NotesWidgetFields(settings: $notesSettings)
            default:
                Text("This widget has no settings yet.")
                    .font(CraftFont.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var draftJSON: String {
        switch kind {
        case .focus: focusSettings.encoded
        case .notes: notesSettings.encoded
        default: ""
        }
    }

    private func save() {
        project.updateOverviewPlate(plateID, size: size, settingsJSON: draftJSON)
        modalDismiss()
    }
}
