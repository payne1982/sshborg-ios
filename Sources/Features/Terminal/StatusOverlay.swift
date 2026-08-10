// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// What the terminal shows over itself while it is not usable.
///
/// Ported from the Android `ErrorOverlay` rework, which changed two things that
/// look small and are not.
///
/// **It sits high rather than centred.** A card in the middle of the screen
/// covers the last output — which is exactly what the user needs to read to
/// understand why the connection dropped. Placing it under the toolbar leaves
/// the scrollback visible behind it.
///
/// **The detail is available but not shouting.** A connection failure has a
/// technical cause worth keeping (`libssh2` messages, host key fingerprints,
/// server text), and stuffing it into the headline makes every failure look
/// alarming. It goes behind a disclosure, and it can be copied — because the
/// realistic next step for a user facing "algorithm negotiation failed" is to
/// paste it somewhere and ask.
struct StatusOverlay: View {

    enum Kind {
        case working
        case failure
        case ended
    }

    let kind: Kind
    let message: String

    /// The technical text, if there is any worth keeping.
    var detail: String?

    /// Buttons under the message. `AnyView` rather than a generic parameter
    /// because the three cases hand back different shapes and the type would
    /// have to be spelled at every call site for no benefit.
    var actions: AnyView

    @State private var isShowingDetail = false
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                icon
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            if let detail, !detail.isEmpty {
                DisclosureGroup(isExpanded: $isShowingDetail) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            UIPasteboard.general.string = detail
                            didCopy = true
                        } label: {
                            Label(
                                String(localized: didCopy ? .actionCopied : .terminalCopyError),
                                systemImage: didCopy ? "checkmark" : "doc.on.doc"
                            )
                            .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                } label: {
                    Text(.terminalErrorDetails)
                        .font(.caption.weight(.medium))
                }
            }

            actions
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .shadow(radius: 8)
        // High, not centred: the output underneath is the context for whatever
        // went wrong.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case .working:
            ProgressView()
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .ended:
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(Color.secondary)
        }
    }
}
