// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Picks one of the ten shared swatches, or none.
///
/// The palette is the same ARGB list the Android app uses, so a colour survives
/// a backup restored on the other platform. Shared by the host editor and the
/// group editor.
struct ColorSwatchPicker: View {

    /// `nil` means "no colour of its own": a host then inherits its group's.
    @Binding var selection: Int?

    /// Whether the "none" option is offered. Groups must always have a colour.
    var allowsNone: Bool = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if allowsNone {
                    swatch(color: nil, isSelected: selection == nil) { selection = nil }
                }

                ForEach(HostGroup.swatches, id: \.self) { value in
                    swatch(color: value, isSelected: selection == value) { selection = value }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func swatch(color: Int?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color.map { Color(argb: $0) } ?? Color(.systemGray4))
                    .frame(width: 28, height: 28)

                if color == nil {
                    // A slash reads as "none" without needing a caption.
                    Image(systemName: "line.diagonal")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.secondary)
                }

                if isSelected {
                    Circle()
                        .strokeBorder(Color.primary, lineWidth: 2)
                        .frame(width: 36, height: 36)
                }
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color == nil ? "No colour" : "Colour")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
