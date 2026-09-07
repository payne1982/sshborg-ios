// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Perception

/// The list of extra-key bars: the user's own first, then the presets.
///
/// Ported from the Android `ExtraBarsScreen`. Tapping a row makes that bar the
/// active one; the row's context menu edits, duplicates and deletes. Presets
/// cannot be edited or deleted, only duplicated — which is the intended way to
/// start a bar of your own, and why every preset offers it.
///
/// The choice is global and permanent, unlike the pin: people switch layout to
/// stay there, not for one session.
struct ExtraBarsScreen: View {

    @Environment(\.appEnvironment) private var environment

    /// The bar the editor is open on. A sheet rather than a push, so leaving
    /// with unsaved work can be intercepted — see ``ExtraBarEditorScreen``.
    @State private var editing: ExtraBar?

    @State private var deleting: ExtraBar?

    private var preferences: AppPreferences { environment.preferences }

    var body: some View {
        WithPerceptionTracking {
            let custom = preferences.customExtraBars
            let selectedID = preferences.extraBarSelectedID

            List {
                if !custom.isEmpty {
                    Section(String(localized: .extraBarsSectionCustom)) {
                        ForEach(custom) { bar in
                            row(bar, isSelected: bar.id == selectedID)
                        }
                    }
                }

                Section(String(localized: .extraBarsSectionPresets)) {
                    ForEach(ExtraBarPresets.all) { bar in
                        row(bar, isSelected: bar.id == selectedID)
                    }
                }
            }
            .navigationTitle(Text(.extraBarsTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        edit(ExtraBar(
                            id: ExtraBar.newCustomID(),
                            name: String(localized: .extraBarsNew),
                            rows: [ExtraBarRow(keys: [], fit: true)],
                            fontScale: .medium
                        ))
                    } label: {
                        Label(String(localized: .extraBarsNew), systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { bar in
                NavigationStack {
                    ExtraBarEditorScreen(bar: bar)
                }
            }
            .alert(
                deleteTitle,
                isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                presenting: deleting
            ) { bar in
                Button(String(localized: .actionCancel), role: .cancel) { deleting = nil }
                Button(String(localized: .actionDelete), role: .destructive) {
                    delete(bar)
                    deleting = nil
                }
            }
        }
    }

    /// The alert's title carries the bar's name, so it says which one is about
    /// to go. Built here because the format argument has to be substituted
    /// before the alert is given its title.
    private var deleteTitle: String {
        String(localized: .extraBarsDeleteTitle)
            .replacingOccurrences(of: "%1$@", with: deleting?.name ?? "")
    }

    // MARK: - Rows

    private func row(_ bar: ExtraBar, isSelected: Bool) -> some View {
        Button {
            preferences.extraBarSelectedID = bar.id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bar.localizedName)
                        .foregroundStyle(Color.primary)
                    // What the bar actually holds, so the names mean something
                    // before you have tried them. Rows separated the way the
                    // Android list does it.
                    Text(summary(of: bar))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .contextMenu {
            if !bar.isPreset {
                Button(String(localized: .actionEdit), systemImage: "pencil") { edit(bar) }
            }
            Button(String(localized: .actionDuplicate), systemImage: "plus.square.on.square") {
                duplicate(bar)
            }
            if !bar.isPreset {
                Button(String(localized: .actionDelete), systemImage: "trash", role: .destructive) {
                    deleting = bar
                }
            }
        }
    }

    /// An icon key has no label of its own, so it shows as a dot rather than as
    /// a gap — the same stand-in the Android list uses.
    private func summary(of bar: ExtraBar) -> String {
        bar.rows
            .map { row in
                row.keys
                    .map { $0.displayLabel.isEmpty ? "•" : $0.displayLabel }
                    .joined(separator: " ")
            }
            .joined(separator: "  /  ")
    }

    // MARK: - Actions

    private func edit(_ bar: ExtraBar) {
        editing = bar
    }

    /// Copies a bar — preset or custom — into a new one of the user's own and
    /// opens it. A copy carries a new id, so the original is untouched.
    private func duplicate(_ bar: ExtraBar) {
        var copy = bar
        copy.id = ExtraBar.newCustomID()
        copy.name = String(localized: .extraBarsCopyName)
            .replacingOccurrences(of: "%1$@", with: bar.localizedName)

        preferences.customExtraBars.append(copy)
        edit(copy)
    }

    /// Deleting the bar in use falls back to the standard preset explicitly,
    /// rather than leaving a selected id pointing at nothing: the list and the
    /// terminal should agree on what is active without either having to guess.
    private func delete(_ bar: ExtraBar) {
        preferences.customExtraBars.removeAll { $0.id == bar.id }
        if preferences.extraBarSelectedID == bar.id {
            preferences.extraBarSelectedID = ExtraBarPresets.standardID
        }
    }
}

#Preview {
    NavigationStack {
        ExtraBarsScreen()
    }
    .environment(\.appEnvironment, .inMemory())
}
