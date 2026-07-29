// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Tells the user when a port forwarding rule did not come up.
///
/// It only appears on failure, and that is the whole point of it. A rule that
/// fails to bind — the port is taken, or it is below 1024 and iOS will not let
/// an app have it — leaves a perfectly working terminal next to a forwarded
/// port that silently is not there. Without this the first sign would be some
/// other program failing to connect to localhost, which is a long way from the
/// cause.
///
/// Working rules stay quiet: a banner listing what is fine would be noise on
/// every single connection.
struct ForwardingNotice: View {

    let statuses: [PortForwarder.Status]

    @State private var isDismissed = false

    private var failures: [PortForwarder.Status] {
        statuses.filter { !$0.isListening }
    }

    var body: some View {
        if !failures.isEmpty, !isDismissed {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                    Text(
                        failures.count == 1
                            ? "A port forwarding rule is not active"
                            : "\(failures.count) port forwarding rules are not active"
                    )
                    .font(.subheadline.weight(.semibold))

                    Spacer(minLength: 0)

                    Button {
                        isDismissed = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }

                ForEach(failures) { status in
                    Text(description(of: status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
        }
    }

    private func description(of status: PortForwarder.Status) -> String {
        let rule = status.rule
        let route = "\(rule.bindAddress):\(rule.localPort) → \(rule.remoteHost):\(rule.remotePort)"

        guard let failure = status.failure, !failure.isEmpty else { return route }
        return "\(route) — \(failure)"
    }
}
