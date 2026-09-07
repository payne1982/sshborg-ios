// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The catalogue of keys a bar can hold: grouped chips, plus a section for
/// text of your own.
///
/// Ported from the Android `KeyPickerDialog`. A tap on a chip picks that key and
/// closes; the text section needs its button, because there is no single tap
/// that means "I have finished typing".
///
/// Text keys are what make the bar extensible without new code: `/`, `-`, `|`,
/// `~` are the characters a phone keyboard hides behind a layer, and text with
/// `\n` in it is a command macro — `ls -la\n` is a key that runs the command.
struct KeyPickerSheet: View {

    /// The key being changed, when the editor is replacing one. Only a text key
    /// carries anything worth pre-filling.
    let initial: ExtraKeyDef?

    let onPick: (ExtraKeyDef) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var label = ""
    @State private var hasLoaded = false

    private static let navigation: [SpecialKey] = [.left, .up, .down, .right, .home, .end, .pgup, .pgdn]
    private static let editing: [SpecialKey] = [.esc, .tab, .enter, .bksp, .del, .ins]
    private static let functionKeys: [SpecialKey] = SpecialKey.allCases.filter(\.isFunctionKey)

    /// Chips size themselves to their label; the grid wraps them. `.adaptive`
    /// rather than a fixed count because "PgDn" and "F1" are very different
    /// widths and a fixed grid would size every column for the widest.
    private let columns = [GridItem(.adaptive(minimum: 68), spacing: 8, alignment: .leading)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                group(.extraKeyGroupNavigation) {
                    ForEach(Self.navigation, id: \.self) { key in
                        chip(key.label) { onPick(.special(key)) }
                    }
                }
                group(.extraKeyGroupEditing) {
                    ForEach(Self.editing, id: \.self) { key in
                        chip(key.label) { onPick(.special(key)) }
                    }
                }
                group(.extraKeyGroupModifiers) {
                    ForEach(ModKey.allCases, id: \.self) { mod in
                        chip(mod.label) { onPick(.modifier(mod)) }
                    }
                }
                group(.extraKeyGroupFunction) {
                    ForEach(Self.functionKeys, id: \.self) { key in
                        chip(key.label) { onPick(.special(key)) }
                    }
                }
                group(.extraKeyGroupActions) {
                    ForEach(BarAction.allCases, id: \.self) { action in
                        chip(action.localizedName) { onPick(.action(action)) }
                    }
                }

                customText
            }
            .padding(16)
        }
        .navigationTitle(Text(.extraKeyPickerTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(String(localized: .actionCancel), action: onCancel)
            }
        }
        .onAppear {
            // Once: re-running this on every appearance would throw away what
            // the user has typed the moment anything else redraws the sheet.
            guard !hasLoaded else { return }
            hasLoaded = true
            if case .text(let value, let existingLabel) = initial {
                text = value
                label = existingLabel ?? ""
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func group<Content: View>(
        _ title: LocalizedStringResource,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                content()
            }
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var customText: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(.extraKeyGroupCustom)
                .font(.caption)
                .foregroundStyle(Color.accentColor)

            TextField(String(localized: .extraKeyText), text: $text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            TextField(String(localized: .extraKeyLabel), text: $label)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

            // Written `\\n` in strings.xml, so the backslashes survive to the
            // screen. They did not until 07/09/2026: the string had single
            // backslashes there and the resource compiler turned them into a
            // real newline and tab, dissolving the sentence into the whitespace
            // it describes. Fixed on the Android side, so there is one string
            // again rather than an iOS copy of it.
            Text(.extraKeyTextHint)
                .font(.caption)
                .foregroundStyle(Color.secondary)

            Button(String(localized: .extraKeyUseText)) {
                onPick(.text(text, label: label.trimmed.isEmpty ? nil : label.trimmed))
            }
            .buttonStyle(.borderedProminent)
            .disabled(text.isEmpty)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
