import SwiftData
import SwiftUI

struct ComposerResultList: View, Equatable {
    var results: [ComposerHit]
    var highlightIndex: Int
    var onSelect: (Int) -> Void
    var onHighlight: (Int) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.results == rhs.results && lhs.highlightIndex == rhs.highlightIndex
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, hit in
                    ComposerResultRow(hit: hit, highlighted: index == highlightIndex)
                        .onTapGesture { onSelect(index) }
                        .onHover { hovering in
                            if hovering { onHighlight(index) }
                        }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, results.isEmpty ? 0 : 8)
        }
        .frame(maxHeight: 360)
        .scrollBounceBehavior(.basedOnSize)
        .clipped()
    }
}

struct ComposerResultRow: View {
    var hit: ComposerHit
    var highlighted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: hit.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title)
                    .font(CraftFont.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(highlighted ? CraftColor.selection : .clear, in: RoundedRectangle(cornerRadius: CraftRadius.row, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
        .accessibilityLabel("\(hit.title), \(hit.kind.label), \(hit.ownerLabel)")
    }

    private var subtitle: String {
        if hit.excerpt.isEmpty { return hit.ownerLabel }
        if hit.kind == .tag { return hit.ownerLabel }
        return "\(hit.ownerLabel) · \(hit.excerpt)"
    }
}

struct ComposerActionsPopup: View {
    var title: String
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @FocusState private var searchFocused: Bool

    private var session: ComposerSession { app.composer }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
            ForEach(Array(session.actions.enumerated()), id: \.element.id) { index, action in
                Button {
                    session.actionIndex = index
                    session.performHighlightedAction(app: app, context: context)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: action.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 16)
                        Text(action.title)
                            .font(CraftFont.body)
                        Spacer()
                        if let shortcut = action.shortcut {
                            ComposerKeycap(shortcut)
                        }
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        index == session.actionIndex ? CraftColor.selection : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Hairline()
                .padding(.top, 2)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Search for actions…", text: actionQuery)
                    .textFieldStyle(.plain)
                    .font(CraftFont.caption)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .frame(width: 240)
        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: CraftRadius.plate, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CraftRadius.plate, style: .continuous)
                .strokeBorder(CraftColor.hairline)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .onAppear { searchFocused = true }
    }

    private var actionQuery: Binding<String> {
        Binding(
            get: { session.actionQuery },
            set: {
                session.actionQuery = $0
                session.actionIndex = 0
            }
        )
    }
}

struct ComposerHelpPopup: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Composer cheat sheet")
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)
            helpRow("Aa", "Search titles and bodies")
            helpRow("@", "Add a reference")
            helpRow("#", "Filter by a tag")
            helpRow("↩", "Open, or add")
            helpRow("⌘K", "More actions")
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: CraftRadius.plate, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CraftRadius.plate, style: .continuous)
                .strokeBorder(CraftColor.hairline)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }

    private func helpRow(_ key: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 12, weight: .medium).monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            Text(title)
                .font(CraftFont.body)
        }
    }
}

struct ComposerScopeControl: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Project.name) private var projects: [Project]

    private var session: ComposerSession { app.composer }

    var body: some View {
        Menu {
            Button("All workspace") {
                session.setScope(.workspace, context: context)
            }
            if !projects.isEmpty {
                Divider()
                ForEach(projects) { project in
                    Button(project.displayName) {
                        session.setScope(.project(project.id), context: context)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: currentSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(currentTitle)
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Scope, \(currentTitle)")
    }

    private var currentTitle: String {
        switch session.scope {
        case .workspace:
            return "All workspace"
        case .project(let id):
            return projects.first { $0.id == id }?.displayName ?? "Project"
        }
    }

    private var currentSymbol: String {
        switch session.scope {
        case .workspace:
            return "circle.dotted"
        case .project(let id):
            return projects.first { $0.id == id }?.symbol ?? "folder"
        }
    }
}
