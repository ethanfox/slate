import SwiftData
import SwiftUI

/// First pass: a plain list of what a Space holds.
struct SpaceView: View {
    var id: UUID

    @Query private var spaces: [Space]
    @Query(sort: \SpaceType.createdAt) private var types: [SpaceType]
    @Query(sort: \SpaceRecord.updatedAt, order: .reverse) private var records: [SpaceRecord]

    private var space: Space? {
        spaces.first { $0.id == id }
    }

    var body: some View {
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 24) {
                    if let space {
                        header(space)
                        content(space)
                    } else {
                        EmptyLine(text: "This Space no longer exists.")
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func header(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(space.displayName)
                .font(.system(size: 28, weight: .semibold))
            if !space.summary.isEmpty {
                Text(space.summary)
                    .font(CraftFont.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func content(_ space: Space) -> some View {
        let key = SpaceJSON.key(space.id)
        let owned = types.filter { $0.spaceIDString == key && $0.role == .object }
        if owned.isEmpty {
            EmptyLine(text: "Nothing in this Space yet.")
        } else {
            ForEach(owned) { type in
                let typeKey = SpaceJSON.key(type.id)
                let rows = records.filter { $0.typeIDString == typeKey }
                VStack(alignment: .leading, spacing: 6) {
                    Text(type.name)
                        .font(CraftFont.section)
                        .foregroundStyle(.secondary)
                    if rows.isEmpty {
                        EmptyLine(text: "No records.")
                    } else {
                        ForEach(rows) { record in
                            HStack(spacing: 10) {
                                Text(record.displayTitle)
                                    .font(CraftFont.body)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(record.updatedAt.relativeLabel)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(height: 40)
                            if record.id != rows.last?.id {
                                Hairline()
                            }
                        }
                    }
                }
            }
        }
    }
}

struct NewSpaceSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.modalDismiss) private var modalDismiss
    @Query private var spaces: [Space]
    @FocusState private var focusName: Bool

    @State private var name = ""
    @State private var symbol = "leaf"
    @State private var gradient: SpaceGradient?

    private var chosen: SpaceGradient {
        gradient ?? SpaceGradient.next(after: spaces.map(\.gradientRaw))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Space")
                .font(CraftFont.title)

            ModalField("Name") {
                TextField("Kitchen", text: $name)
                    .textFieldStyle(.plain)
                    .focused($focusName)
            }

            ModalField("Icon", boxed: false) {
                SymbolPicker(selection: $symbol)
            }

            ModalField("Color", boxed: false) {
                HStack(spacing: 8) {
                    ForEach(SpaceGradient.allCases) { option in
                        Button {
                            gradient = option
                        } label: {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(option.fill)
                                .frame(width: 36, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.primary, lineWidth: chosen == option ? 2 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(option.label)
                        .accessibilityLabel(option.label)
                    }
                }
            }

            ModalFooter(actionTitle: "Create", actionEnabled: canCreate, action: create)
        }
        .onAppear { focusName = true }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? SpaceStore.create(named: trimmed, symbol: symbol, gradient: chosen.rawValue, in: context)
        modalDismiss()
    }
}
