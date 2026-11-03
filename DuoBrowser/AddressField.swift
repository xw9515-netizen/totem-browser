import SwiftUI

/// The address bar. Shows the current host; tapping it (or New Tab) turns it into a text field in
/// place, so entering an address never opens a sheet.
struct AddressField: View {
    @Environment(TabStore.self) private var store
    let tab: BrowserTab?
    @Binding var isEditing: Bool
    /// Scrolled-down state: a small host label that restores the controls when tapped.
    var isMinimized = false
    var onTapMinimized: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = ""
    @State private var selection: TextSelection?
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("Search or enter website", text: $text, selection: $selection)
                    .keyboardType(.webSearch)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($isFocused)
                    .onSubmit(submit)
                    .frame(maxWidth: .infinity)
                    .transition(.blurReplace)
            } else {
                // A tappable label rather than a Button: toolbars give buttons a minimum height,
                // which would make the bubble taller than it needs to be.
                label
                    .contentShape(.rect)
                    .onTapGesture(perform: activate)
                    .transition(.blurReplace)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityHint(isMinimized ? "Shows the browser controls" : "Enter a website or search")
                    .accessibilityAction { activate() }
            }
        }
        .onChange(of: isEditing, initial: true) {
            guard isEditing else { return }
            text = tab?.url?.absoluteString ?? ""
            isFocused = true
        }
        .onChange(of: isFocused) {
            if isFocused {
                // Select the whole address, as Safari does, so typing replaces it. The field only
                // takes a selection once it's first responder, hence the hop to the next run loop.
                Task { selection = TextSelection(range: text.startIndex ..< text.endIndex) }
            } else {
                // Tapping away ends editing without loading anything.
                setEditing(false)
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        let host = tab?.displayHost ?? ""
        if isMinimized {
            Text(host.isEmpty ? "Address" : host)
                .font(.caption)
                .lineLimit(1)
        } else {
            // HStack rather than Label: toolbars render Labels icon-only, which would hide the domain.
            HStack(spacing: 5) {
                if tab?.hasOnlySecureContent == true {
                    // Small beside the domain, as in Safari, so the address leads.
                    Image(systemName: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(host.isEmpty ? "Search or enter website" : host)
                    .lineLimit(1)
            }
            .font(.body)
        }
    }

    private var accessibilityLabel: String {
        guard let host = tab?.displayHost, !host.isEmpty else { return "Address" }
        return "Address, \(host)"
    }

    private func submit() {
        guard let url = TabStore.url(forInput: text) else { return }
        if let tab { tab.load(url) } else { store.newTab(url: url) }
        setEditing(false)
    }

    private func activate() {
        if isMinimized { onTapMinimized() } else { setEditing(true) }
    }

    private func setEditing(_ editing: Bool) {
        guard editing != isEditing else { return }
        withAnimation(reduceMotion ? nil : .addressMorph) { isEditing = editing }
    }
}

extension Animation {
    /// The address bubble growing into the text field and back: a quick spring with a little
    /// give, close to Safari's.
    static let addressMorph = Animation.spring(duration: 0.45, bounce: 0.18)
}
