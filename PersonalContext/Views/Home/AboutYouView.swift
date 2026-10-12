import SwiftData
import SwiftUI

/// What Membrae knows about the user. Kept off You; opened from it.
struct AboutYouView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PersonalFact.createdAt) private var facts: [PersonalFact]
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                PageBody {
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("About you")
                                .font(.system(size: 28, weight: .semibold))
                            Text("What Membrae remembers. Tell it something new below.")
                                .font(CraftFont.body)
                                .foregroundStyle(.secondary)
                        }
                        list
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)

            composer
                .frame(maxWidth: 560)
                .padding(.horizontal, 48)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
        }
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var list: some View {
        if facts.isEmpty {
            EmptyLine(text: "Nothing yet.")
        } else {
            VStack(spacing: 0) {
                Hairline()
                ForEach(facts) { fact in
                    HStack(spacing: 16) {
                        if !fact.category.isEmpty {
                            Text(fact.category)
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .frame(width: 92, alignment: .leading)
                        }
                        Text(fact.text)
                            .font(CraftFont.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if fact.source == .agent {
                            Text(fact.origin.isEmpty ? "from a chat" : "from \(fact.origin)")
                                .font(CraftFont.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button(role: .destructive) {
                            try? FactStore.delete(fact, in: context)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    Hairline()
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Tell Membrae something about you", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit(add)
            Button(action: add) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CraftColor.canvas)
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(canAdd ? 1 : 0.25), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .help("Add")
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(height: 48)
        .background(CraftColor.elevated, in: Capsule())
        .overlay(Capsule().strokeBorder(CraftColor.hairline))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var canAdd: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func add() {
        guard canAdd else { return }
        try? FactStore.add(draft, in: context)
        draft = ""
        focused = true
    }
}
