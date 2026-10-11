import SwiftData
import SwiftUI

struct UniversalComposerOverlay: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            CraftColor.scrim
                .ignoresSafeArea()
                .opacity(app.composer.isOpen ? 1 : 0)
                .onTapGesture { app.composer.close() }

            ComposerPanel()
                .scaleEffect(app.composer.isOpen ? 1 : 0.92)
                .opacity(app.composer.isOpen ? 1 : 0)
        }
        .allowsHitTesting(app.composer.isOpen)
        .accessibilityHidden(!app.composer.isOpen)
        .animation(reduceMotion ? nil : Motion.pop, value: app.composer.isOpen)
    }
}

struct ComposerPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @FocusState private var fieldFocused: Bool

    private var session: ComposerSession { app.composer }

    var body: some View {
        VStack(spacing: 0) {
            if session.hasExchange {
                ComposerChatPane()
                if session.parsed.token == .mention {
                    mentionTabs
                }
            } else {
                queryBar
                if session.parsed.token == .mention {
                    mentionTabs
                }
            }
            if showsResults {
                resultList
            }
            if case .save(let kind) = session.popup {
                ComposerSaveForm(kind: kind)
            }
            footer
        }
        .frame(width: 640)
        .background(CraftColor.elevated, in: panelShape)
        .overlay(panelShape.strokeBorder(CraftColor.hairline))
        .clipShape(panelShape)
        .shadow(color: .black.opacity(0.20), radius: 30, y: 12)
        .overlay(alignment: .topTrailing) {
            if session.popup == .help {
                ComposerHelpPopup()
                    .padding(.top, 52)
                    .padding(.trailing, 16)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if session.popup == .actions {
                ComposerActionsPopup(title: session.hasExchange ? "This exchange" : (session.highlighted?.title ?? "Actions"))
                    .padding(.trailing, 12)
                    .padding(.bottom, 48)
            }
        }
        .onChange(of: session.focusNonce) { _, _ in
            claimField()
        }
        .onChange(of: session.focusNonceChat) { _, _ in
            claimField()
        }
        .onChange(of: session.isOpen) { _, open in
            fieldFocused = open
        }
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    private var showsResults: Bool {
        if case .save = session.popup { return false }
        if session.hasExchange { return session.parsed.token != .search }
        return true
    }

    private var queryBar: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            chips
            TextField("Search or ask…", text: fieldBinding, axis: .horizontal)
                .textFieldStyle(.plain)
                .font(CraftFont.chatBody)
                .focused($fieldFocused)
                .onSubmit {
                    session.confirm(app: app, context: context)
                }
            Button(action: session.toggleHelp) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.tertiary)
                    ComposerKeycap("tab")
                }
            }
            .buttonStyle(.plain)
            .help("Composer help")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var mentionTabs: some View {
        HStack(spacing: 16) {
            tabButton("Membrae", tab: .membrae)
            if session.hasRepos {
                tabButton("Repos", tab: .repos)
            }
            Spacer()
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 8)
    }

    private func tabButton(_ title: String, tab: ComposerMentionTab) -> some View {
        Button(title) {
            session.setMentionTab(tab, context: context)
        }
        .buttonStyle(.plain)
        .font(CraftFont.body)
        .foregroundStyle(session.mentionTab == tab ? .primary : .tertiary)
        .overlay(alignment: .bottom) {
            if session.mentionTab == tab {
                Rectangle()
                    .fill(Color.primary)
                    .frame(height: 1)
                    .offset(y: 6)
            }
        }
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(session.tagFilters) { tag in
            ComposerFilterChip(title: "#\(tag.name)") {
                session.removeTag(tag.id)
                session.refresh(in: context)
            }
        }
        ForEach(session.mentions) { hit in
            ComposerFilterChip(title: "@\(hit.title)") {
                session.removeMention(hit)
                session.refresh(in: context)
            }
        }
    }

    private var resultList: some View {
        ComposerResultList(
            results: session.results,
            highlightIndex: session.highlightIndex,
            onSelect: { index in
                session.highlightIndex = index
                session.performDefault(app: app, context: context)
            },
            onHighlight: { index in
                session.highlightIndex = index
            }
        )
        .equatable()
    }

    private var footer: some View {
        HStack(spacing: 10) {
            ComposerScopeControl()
            Spacer()
            HStack(spacing: 6) {
                Text(session.defaultAction.title)
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                ComposerKeycap("↩")
            }
            HStack(spacing: 6) {
                Text("Actions")
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                ComposerKeycap("⌘K")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(CraftColor.elevated)
        .overlay(Hairline(), alignment: .top)
        .contentShape(Rectangle())
        .zIndex(1)
    }

    private var fieldBinding: Binding<String> {
        Binding(
            get: { session.hasExchange ? session.draft : session.query },
            set: { session.setField($0, context: context) }
        )
    }

    private func claimField() {
        guard session.isOpen else {
            fieldFocused = false
            return
        }
        fieldFocused = false
        Task { @MainActor in
            fieldFocused = true
        }
    }
}

struct ComposerFilterChip: View {
    var title: String
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(CraftFont.caption)
                .lineLimit(1)
            Button("Remove \(title)", systemImage: "xmark", action: onRemove)
                .labelStyle(.iconOnly)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(CraftColor.selection, in: Capsule())
    }
}

struct ComposerKeycap: View {
    var label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium).monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(CraftColor.wash, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(CraftColor.hairline)
            )
    }
}
