// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The empty and failed states — no hosts, no keys, no sessions, an empty
/// directory, a connection that did not come up.
///
/// This is `ContentUnavailableView`, which is iOS 17, rewritten for the 16.0
/// deployment target. `if #available` was available and deliberately not used:
/// it would give the one phone this app is actually tested on — an A11 device,
/// capped at 16.7.x — a different appearance from the one most users would see,
/// and appearance is the single thing that cannot be settled by reading code.
/// One implementation, one look, on every version.
///
/// The call shapes match Apple's on purpose, so the call sites did not have to
/// change and could go back if the floor ever rises.
struct EmptyStateView<Label: View, Description: View, Actions: View>: View {

    private let label: Label
    private let description: Description
    private let actions: Actions

    init(
        @ViewBuilder label: () -> Label,
        @ViewBuilder description: () -> Description,
        @ViewBuilder actions: () -> Actions
    ) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 12) {
            label.labelStyle(EmptyStateLabelStyle())

            description
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // EmptyView still occupies a slot in a VStack's spacing, which
            // would leave a gap under the description where there is nothing.
            if Actions.self != EmptyView.self {
                VStack(spacing: 8) { actions }
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(
        @ViewBuilder label: () -> Label,
        @ViewBuilder description: () -> Description
    ) {
        self.init(label: label, description: description, actions: { EmptyView() })
    }
}

extension EmptyStateView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    /// The short form: a title, a glyph, and optionally a line under it.
    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.init(
            label: { SwiftUI.Label(title, systemImage: systemImage) },
            description: { description }
        )
    }
}

/// Apple's arrangement: the glyph above the title, both centred, the glyph in a
/// lighter weight than the text it sits over.
private struct EmptyStateLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 12) {
            configuration.icon
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            configuration.title
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
        }
    }
}
