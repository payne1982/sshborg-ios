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
        /// Something is being asked, not reported. A first connection to a host
        /// is ordinary, and dressing it as a fault teaches the user to dismiss
        /// exactly the prompt they are meant to read.
        case question
    }

    let kind: Kind
    let message: String

    /// The technical text, if there is any worth keeping.
    var detail: String?

    /// Shows ``detail`` outright instead of behind a disclosure.
    ///
    /// For a failure the detail is context you reach for when you want it. For a
    /// host key it is the *entire point* — a fingerprint nobody unfolds is a
    /// fingerprint nobody checks, and the prompt becomes a formality.
    var showsDetailOutright = false

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
                    .foregroundStyle(Color(.label))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            if let detail, !detail.isEmpty {
                if showsDetailOutright {
                    detailBody(detail)
                } else {
                    DisclosureGroup(isExpanded: $isShowingDetail) {
                        detailBody(detail).padding(.top, 4)
                    } label: {
                        Text(.terminalErrorDetails)
                            .font(.caption.weight(.medium))
                    }
                }
            }

            actions
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        // Opaque, not a material.
        //
        // A material is translucent, so what shows through decides how dark the
        // panel reads — and what is behind this one is a terminal, black by
        // default and recoloured by the user. Meanwhile `Color.primary` resolves
        // against the *app's* colour scheme, which knows nothing about that. The
        // two disagreed and the fingerprint came out white on white.
        //
        // An opaque background pairs predictably with the label colours, whatever
        // the terminal is doing underneath.
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        )
        .shadow(radius: 8)
        // High, not centred: the output underneath is the context for whatever
        // went wrong.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func detailBody(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail)
                .font(.caption.monospaced())
                .foregroundStyle(kind == .question ? Color(.label) : Color(.secondaryLabel))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                UIPasteboard.general.string = detail
                didCopy = true
            } label: {
                Label(
                    String(localized: didCopy ? .actionCopied : copyLabel),
                    systemImage: didCopy ? "checkmark" : "doc.on.doc"
                )
                .font(.caption)
            }
            .buttonStyle(.bordered)
        }
    }

    /// Copying a fingerprint to compare it against the server is a normal thing
    /// to do; calling it "copy error" would be wrong twice over.
    private var copyLabel: LocalizedStringResource {
        kind == .question ? .actionCopy : .terminalCopyError
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
        case .question:
            Image(systemName: "lock.shield").foregroundStyle(Color.accentColor)
        }
    }
}
