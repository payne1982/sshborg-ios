// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// What is shown instead of the app while it is locked.
///
/// It does two jobs at once and they want opposite things. As a **privacy
/// cover** it has to be opaque and instant, hiding a host list that may be on
/// screen the moment the app is swiped away. As a **prompt** it has to explain
/// itself, since a blank screen with no way forward is indistinguishable from a
/// hung app.
///
/// So: opaque from the first frame, with the explanation and the button arriving
/// only once the system has finished asking. While the system's own sheet is up
/// there is nothing to say, and saying it anyway would put two prompts on screen
/// at once.
struct LockScreen: View {

    let biometryName: String
    let isAsking: Bool
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            // Opaque, not a material: the whole point is that nothing behind it
            // shows through. The same lesson the terminal's prompts learned the
            // expensive way.
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                Text(.appName)
                    .font(.headline)

                if !isAsking {
                    Text(.biometricPromptSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button(action: onRetry) {
                        Label(
                            String(localized: .iosUnlockWith)
                                .replacingOccurrences(of: "%1$@", with: biometryName),
                            systemImage: "faceid"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(32)
        }
    }
}
