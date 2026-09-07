// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Perception

/// The editor for one bar, in which the editor *is* the bar.
///
/// Ported from the Android `ExtraBarEditorScreen`. The real ``ExtraKeyBar`` is
/// rendered at the top with `editing` on: a tap selects a key instead of
/// sending it, and the toolbar under it acts on the selection.
///
/// **Why not drag and drop**, which is the obvious idea on a touch screen: a
/// tap-to-select toolbar is one code path, it needs no reordering library, and
/// the preview shows the true result at true size rather than an approximation
/// of it. Android chose it so its D-pad and its touch input could share one
/// model; here the reason is narrower, but the result is the same screen, which
/// keeps the two builds explainable with one set of words.
///
/// **Presented as a sheet, where Android pushes a screen.** Edits are buffered
/// and Android asks before dropping them on Back. A pushed screen on iOS cannot
/// ask: the back swipe pops it with no way to intervene, so the question would
/// appear for the chevron and not for the gesture — worse than not asking at
/// all. A sheet has `interactiveDismissDisabled`, which is a real answer rather
/// than a half of one, and Cancel/Save in the bar is the iOS shape for a form
/// that buffers. The host editor in this app is already a sheet for the same
/// reason.
struct ExtraBarEditorScreen: View {

    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss

    /// The bar as it was when the screen opened. Copied into a draft below;
    /// nothing is written until Save.
    let bar: ExtraBar

    @State private var draft: ExtraBarDraft?
    @State private var picker: PickerMode?
    @State private var isConfirmingDiscard = false

    /// Whether the catalogue is about to add a key or change the selected one.
    private enum PickerMode: Int, Identifiable {
        case insert, replace
        var id: Int { rawValue }
    }

    private var isDirty: Bool { draft?.isDirty ?? false }

    var body: some View {
        WithPerceptionTracking {
            Group {
                if draft != nil {
                    content
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(Text(isNew ? .extraBarEditorNewTitle : .extraBarEditorTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: .actionCancel)) {
                        if isDirty { isConfirmingDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: .actionSave)) { save() }
                        .disabled(!(draft?.canSave ?? false))
                }
            }
            // The swipe down would otherwise drop the draft without a word.
            .interactiveDismissDisabled(isDirty)
            .onAppear { draft = draft ?? ExtraBarDraft(bar: bar) }
            .confirmationDialog(
                Text(.extraBarDiscardTitle),
                isPresented: $isConfirmingDiscard,
                titleVisibility: .visible
            ) {
                Button(String(localized: .actionDiscard), role: .destructive) { dismiss() }
                Button(String(localized: .actionCancel), role: .cancel) {}
            }
            .sheet(item: $picker) { mode in
                NavigationStack {
                    KeyPickerSheet(
                        initial: mode == .replace ? draft?.selectedKey : nil,
                        onPick: { key in
                            if mode == .replace {
                                draft?.replaceSelection(with: key)
                            } else {
                                draft?.insert(key)
                            }
                            picker = nil
                        },
                        onCancel: { picker = nil }
                    )
                }
            }
        }
    }

    /// A bar the list has just made is not stored yet, which is what "new"
    /// means here. Only the title depends on it.
    private var isNew: Bool {
        !environment.preferences.customExtraBars.contains { $0.id == bar.id }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        // One binding, so the preview, the toolbar and the form below all act
        // on the same draft rather than on copies of it.
        let draft = Binding<ExtraBarDraft>(
            get: { self.draft ?? ExtraBarDraft(bar: bar) },
            set: { self.draft = $0 }
        )

        VStack(spacing: 0) {
            preview(draft)
            Divider()
            selectionToolbar(draft)
            Divider()
            form(draft)
        }
    }

    private func preview(_ draft: Binding<ExtraBarDraft>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ExtraKeyBar(
                bar: draft.wrappedValue.bar,
                state: .preview,
                editing: true,
                selected: draft.wrappedValue.selection,
                onSelectKey: { draft.wrappedValue.select($0) }
            )

            Text(.extraBarHintSelect)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
    }

    /// The toolbar acts on the selection. "Add" is the one button that works
    /// with nothing selected: it appends to the last row.
    private func selectionToolbar(_ draft: Binding<ExtraBarDraft>) -> some View {
        let value = draft.wrappedValue

        return HStack(spacing: 0) {
            toolButton("chevron.left", .extraBarMoveLeft, enabled: value.canMoveLeft) {
                draft.wrappedValue.moveSelection(by: -1)
            }
            toolButton("chevron.right", .extraBarMoveRight, enabled: value.canMoveRight) {
                draft.wrappedValue.moveSelection(by: 1)
            }
            toolButton("chevron.up", .extraBarMoveUp, enabled: value.canMoveToRowAbove) {
                draft.wrappedValue.moveSelectionToRow(by: -1)
            }
            toolButton("chevron.down", .extraBarMoveDown, enabled: value.canMoveToRowBelow) {
                draft.wrappedValue.moveSelectionToRow(by: 1)
            }
            toolButton("pencil", .extraBarEditKey, enabled: value.hasSelection) { picker = .replace }
            toolButton("plus", .extraBarAddKey, enabled: true) { picker = .insert }
            toolButton("trash", .extraBarRemoveKey, enabled: value.hasSelection) {
                draft.wrappedValue.removeSelection()
            }
        }
        .padding(.vertical, 6)
    }

    private func toolButton(
        _ systemImage: String,
        _ label: LocalizedStringResource,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.5))
        .accessibilityLabel(Text(label))
    }

    // MARK: - Form

    private func form(_ draft: Binding<ExtraBarDraft>) -> some View {
        Form {
            Section {
                ForEach(Array(draft.wrappedValue.bar.rows.enumerated()), id: \.offset) { index, row in
                    rowEntry(draft, index: index, keys: row.keys.count)
                }

                if draft.wrappedValue.bar.rows.count < ExtraBar.maxRows {
                    Button {
                        draft.wrappedValue.addRow()
                    } label: {
                        Label(String(localized: .extraBarAddRow), systemImage: "plus")
                    }
                }
            }

            Section {
                LabeledContent(String(localized: .extraBarName)) {
                    TextField(
                        String(localized: .extraBarName),
                        text: Binding(
                            get: { draft.wrappedValue.bar.name },
                            set: { draft.wrappedValue.setName($0) }
                        )
                    )
                    .multilineTextAlignment(.trailing)
                }

                Picker(
                    String(localized: .extraBarFontSize),
                    selection: Binding(
                        get: { draft.wrappedValue.bar.fontScale },
                        set: { draft.wrappedValue.setFontScale($0) }
                    )
                ) {
                    ForEach(BarFontScale.allCases, id: \.self) { scale in
                        Text(scale.localizedName).tag(scale)
                    }
                }
            }
        }
    }

    private func rowEntry(_ draft: Binding<ExtraBarDraft>, index: Int, keys: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(rowTitle(index: index, keys: keys))
                Spacer()
                if draft.wrappedValue.bar.rows.count > 1 {
                    Button {
                        draft.wrappedValue.removeRow(index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(.extraBarRemoveRowCd))
                }
            }

            // Two named alternatives beat a switch plus a sentence explaining
            // it, which is what this was on Android before it became a pair.
            Picker(
                rowTitle(index: index, keys: keys),
                selection: Binding(
                    get: { draft.wrappedValue.bar.rows[safe: index]?.fit ?? false },
                    set: { draft.wrappedValue.setRowFit($0, row: index) }
                )
            ) {
                Text(.extraBarRowScroll).tag(false)
                Text(.extraBarRowFill).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func rowTitle(index: Int, keys: Int) -> String {
        String(localized: .extraBarRowN)
            .replacingOccurrences(of: "%1$d", with: "\(index + 1)")
            .replacingOccurrences(of: "%2$d", with: "\(keys)")
    }

    // MARK: - Saving

    /// Writes the draft back, keeping an existing bar where it was in the list
    /// so saving does not shuffle the order under the user.
    private func save() {
        guard let draft, draft.canSave else { return }

        var bars = environment.preferences.customExtraBars
        if let index = bars.firstIndex(where: { $0.id == draft.bar.id }) {
            bars[index] = draft.bar
        } else {
            bars.append(draft.bar)
        }
        environment.preferences.customExtraBars = bars
        dismiss()
    }
}
