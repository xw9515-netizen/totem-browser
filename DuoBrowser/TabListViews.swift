import SwiftUI

/// Full list of open tabs, opened from the capsule's "…" menu. Lists give native selection,
/// drag to reorder, swipe to close and search.
struct AllTabsView: View {
    @Environment(TabStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var onNewTab: () -> Void

    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(selection: tabSelection(in: store, then: { dismiss() })) {
                section("Pinned", tabs: store.pinnedTabs)
                section("Today", tabs: store.unpinnedTabs)
            }
            .searchable(text: $query, prompt: "Search tabs")
            .navigationTitle("Tabs")
            .navigationSubtitle("\(store.tabs.count) open")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("New Tab", systemImage: "plus") {
                        dismiss()
                        onNewTab()
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, tabs: [BrowserTab]) -> some View {
        let matching = tabs.filter { $0.matches(query) }
        if !matching.isEmpty {
            Section(title) {
                ForEach(matching) { tab in
                    TabRow(tab: tab)
                }
                // Reordering a filtered list would be ambiguous, so it's only on without a search.
                .onMove(perform: query.isEmpty ? { store.move(in: tabs, fromOffsets: $0, toOffset: $1) } : nil)
            }
        }
    }
}

/// Titled tab column for landscape, beside the page: search, pinned tiles, then the other tabs,
/// with the current tab raised as a card.
struct TabColumn: View {
    @Environment(TabStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onNewTab: () -> Void
    /// The address lives at the foot of the column so it never covers the page.
    @Binding var isEditingAddress: Bool
    /// Distance from the window's top to the search field, lining it up with the status bar.
    var topInset: CGFloat = 15
    /// Distance from the window's bottom to the address bubble, lining it up with New Tab.
    /// Nil until New Tab has been found; the bubble then sits on the safe area's edge.
    var bottomInset: CGFloat?

    @State private var query = ""
    @State private var isKeyboardUp = false
    /// Lets the selection card slide from the old row to the new one.
    @Namespace private var selection

    var body: some View {
        let pinned = store.pinnedTabs.filter { $0.matches(query) }
        let today = store.unpinnedTabs.filter { $0.matches(query) }

        // The list ignores the keyboard and only the bubble rides up on it. When the list shrank
        // with the keyboard too, it jumped a couple of rows as the keyboard went away.
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    SearchField(text: $query)

                    if !pinned.isEmpty {
                        // Arc-style: tiles share each row's width, up to four per row, three rows at most.
                        let rows = stride(from: 0, to: min(pinned.count, TabStore.maxPinned), by: 4).map {
                            Array(pinned[$0 ..< min($0 + 4, pinned.count)])
                        }
                        VStack(spacing: 6) {
                            ForEach(rows, id: \.first?.id) { row in
                                HStack(spacing: 6) {
                                    ForEach(row) { tab in
                                        Button { store.select(tab) } label: {
                                            PinnedTile(tab: tab, isCurrent: tab.id == store.currentID)
                                        }
                                        .buttonStyle(.plain)
                                        .tabContextMenu(tab)
                                    }
                                }
                            }
                        }
                    }

                    if !today.isEmpty {
                        Text("Today")
                            .textCase(.uppercase)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 2)

                        VStack(spacing: 1) {
                            ForEach(today) { tab in
                                Button { store.select(tab) } label: {
                                    ColumnTabRow(tab: tab, isCurrent: tab.id == store.currentID,
                                                 selection: selection)
                                }
                                .buttonStyle(.plain)
                                .tabContextMenu(tab)
                                .draggable(tab.id.uuidString) { ColumnTabRow(tab: tab, isCurrent: false, selection: nil) }
                                .dropDestination(for: String.self) { ids, _ in
                                    guard let id = ids.first.flatMap(UUID.init(uuidString:)),
                                          let dragged = store.tab(withID: id) else { return false }
                                    withAnimation(reduceMotion ? nil : .snappy) { store.move(dragged, to: tab) }
                                    return true
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, topInset)
                // Room to scroll the last tab clear of the bubble and the bottom safe area.
                .padding(.bottom, (bottomInset ?? 30) + 56)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(.container, edges: .vertical)
            .ignoresSafeArea(.keyboard)

            AddressField(tab: store.current, isEditing: $isEditingAddress)
                .tint(.primary)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                // The whole capsule starts editing, not just the domain text inside it.
                .contentShape(.capsule)
                .onTapGesture {
                    guard !isEditingAddress else { return }
                    withAnimation(reduceMotion ? nil : .addressMorph) { isEditingAddress = true }
                }
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.horizontal, 8)
                // Level with New Tab's bottom edge; just above the keyboard while typing.
                .padding(.bottom, isKeyboardUp ? 8 : (bottomInset ?? 0))
                .ignoresSafeArea(.container, edges: isKeyboardUp || bottomInset == nil ? [] : .bottom)
        }
        .onGeometryChange(for: Bool.self) { $0.safeAreaInsets.bottom > 100 } action: { isKeyboardUp = $0 }
        .animation(reduceMotion ? nil : .snappy, value: store.tabs.map(\.id))
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search tabs", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.fill.tertiary, in: .rect(cornerRadius: 10))
    }
}

/// A pinned tab: its favicon on a tile. The current one gets an outline.
private struct PinnedTile: View {
    let tab: BrowserTab
    let isCurrent: Bool

    var body: some View {
        FaviconView(tab: tab)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.6), lineWidth: 1.5)
                }
            }
            .accessibilityLabel(tab.title.isEmpty ? tab.displayHost : tab.title)
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// A tab in the column: favicon and title. The current one is raised on a card.
private struct ColumnTabRow: View {
    let tab: BrowserTab
    let isCurrent: Bool
    /// Shared by every row so there's one card that moves; nil for drag previews.
    let selection: Namespace.ID?

    var body: some View {
        HStack(spacing: 4) {
            FaviconView(tab: tab)
            Text(tab.title.isEmpty ? tab.displayHost : tab.title)
                .font(.subheadline.weight(isCurrent ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: 44)
        .background {
            if isCurrent {
                let card = RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
                if let selection {
                    card.matchedGeometryEffect(id: "selection", in: selection)
                } else {
                    card
                }
            }
        }
        .contentShape(.rect)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// One tab in a list: favicon, title, host, and a close button.
struct TabRow: View {
    @Environment(TabStore.self) private var store
    let tab: BrowserTab

    var body: some View {
        HStack(spacing: 10) {
            FaviconView(tab: tab)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title.isEmpty ? tab.displayHost : tab.title)
                    .lineLimit(1)
                if !tab.displayHost.isEmpty {
                    Text(tab.displayHost)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button("Close Tab", systemImage: "xmark") { store.close(tab) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .tag(tab.id)
        .tabContextMenu(tab)
        .swipeActions {
            Button("Close", systemImage: "xmark", role: .destructive) { store.close(tab) }
        }
    }
}

extension View {
    /// Long-press (or right-click) menu shared by every tab list: pin or unpin, and close.
    func tabContextMenu(_ tab: BrowserTab) -> some View {
        modifier(TabContextMenu(tab: tab))
    }
}

private struct TabContextMenu: ViewModifier {
    @Environment(TabStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tab: BrowserTab

    func body(content: Content) -> some View {
        content.contextMenu {
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab", systemImage: tab.isPinned ? "pin.slash" : "pin") {
                withAnimation(reduceMotion ? nil : .snappy) { store.setPinned(tab, !tab.isPinned) }
            }
            .disabled(!tab.isPinned && !store.canPinMore)
            Button("Close Tab", systemImage: "xmark", role: .destructive) { store.close(tab) }
        }
    }
}

extension BrowserTab {
    func matches(_ query: String) -> Bool {
        query.isEmpty || title.localizedStandardContains(query) || displayHost.localizedStandardContains(query)
    }
}

/// List selection bound to the current tab. Tapping a row selects it, then runs `then`.
@MainActor
private func tabSelection(in store: TabStore, then: @escaping () -> Void = {}) -> Binding<BrowserTab.ID?> {
    Binding(
        get: { store.currentID },
        set: { id in
            guard let id else { return }
            store.select(id: id)
            then()
        }
    )
}
