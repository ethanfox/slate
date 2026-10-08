import SwiftData
import SwiftUI

struct DeletionChrome<Content: View>: View {
    var mark: DeletionMark?
    var deleteTitle: String
    var deleteMessage: String?
    var onKeep: () -> Void
    var onConfirmDelete: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            if let mark {
                DeletionBanner(mark: mark, onKeep: onKeep, onDelete: { confirmDelete = true })
            }
            content()
        }
        .alert(deleteTitle, isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: onConfirmDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            if let deleteMessage {
                Text(deleteMessage)
            }
        }
    }
}

struct DeletionBanner: View {
    var mark: DeletionMark
    var onKeep: () -> Void
    var onDelete: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: toggle) {
                    HStack(spacing: 10) {
                        Image(systemName: "xmark.octagon")
                            .font(CraftFont.titleIcon)
                            .foregroundStyle(.red)
                            .frame(width: 18, height: 18)
                        Text("Marked for deletion")
                            .font(CraftFont.section)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Marked for deletion")
                .accessibilityHint(expanded ? "Hides the reason" : "Shows the reason")
                Spacer(minLength: 8)
                Button("Keep", action: onKeep)
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
                    .foregroundStyle(.primary)
                    .frame(minHeight: 28)
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
                    .foregroundStyle(.red)
                    .frame(minHeight: 28)
                Button(action: toggle) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Hide reason" : "Show reason")
            }
            .padding(.horizontal, 32)
            .frame(height: 52)

            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    Text(mark.reason)
                        .font(CraftFont.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let source = replacementSource {
                        ObjectLinkCard(source: source) {
                            source.open(app: app, context: context)
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CraftColor.canvas)
        .overlay(alignment: .bottom) {
            Hairline()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    private var replacementSource: ChatSource? {
        guard let kind = mark.replacementKind, let id = mark.replacementID else { return nil }
        let chatKind: ChatSource.Kind = switch kind {
        case .note: .note
        case .thread: .thread
        case .decision: .decision
        case .conversation: .conversation
        }
        return ChatSource(id: id.uuidString, title: "", url: nil, kind: chatKind, pin: false)
    }

    private func toggle() {
        if reduceMotion {
            expanded.toggle()
        } else {
            withAnimation(Motion.quick) { expanded.toggle() }
        }
    }
}
