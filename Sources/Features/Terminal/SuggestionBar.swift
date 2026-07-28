// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Commands from the server's shell history that match what is being typed.
///
/// It sits in the terminal's bottom inset, directly above the extra key row.
/// The session tab strip lives at the *top* of the screen, so the two cannot
/// compete for the same space — the Android build has a bug where opening a
/// second session makes the tab strip appear and this bar disappear, and the
/// layout here is arranged so that cannot happen.
struct SuggestionBar: View {

    let suggestions: [String]

    /// When on, the bar keeps its height even with nothing to show, so the
    /// terminal does not resize under the user's eyes every time a suggestion
    /// appears. Off by default, matching Android.
    let isSticky: Bool

    let onSelect: (String) -> Void

    private var isVisible: Bool {
        isSticky || !suggestions.isEmpty
    }

    var body: some View {
        if isVisible {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(suggestions, id: \.self) { command in
                        Button {
                            onSelect(command)
                        } label: {
                            Text(command)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 220)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .overlay(
                                    Capsule().stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            .frame(height: 34)
            .background(Color(.secondarySystemBackground))
            .transition(.opacity)
        }
    }
}
