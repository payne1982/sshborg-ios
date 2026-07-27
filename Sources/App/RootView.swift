// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Phase 0 placeholder showing the outcome of the stack smoke test.
/// Replaced by the hosts list in phase 4.
struct RootView: View {
    @State private var outcomes: [StackCheck.Outcome] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Stack") {
                    ForEach(outcomes) { outcome in
                        LabeledContent {
                            Text(outcome.detail)
                                .foregroundStyle(.secondary)
                                .font(.callout.monospaced())
                        } label: {
                            Label {
                                Text(outcome.component)
                            } icon: {
                                Image(systemName: outcome.ok
                                      ? "checkmark.circle.fill"
                                      : "xmark.circle.fill")
                                .foregroundStyle(outcome.ok ? .green : .red)
                            }
                        }
                    }
                }

                Section {
                    Text("Phase 0 — foundations. No features implemented yet: this screen only verifies that the dependencies link and run on device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("SSHBorg")
        }
        .task {
            outcomes = StackCheck.runAll()
        }
    }
}

#Preview {
    RootView()
}
