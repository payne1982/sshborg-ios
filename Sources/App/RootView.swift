// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Temporary entry point: a connection form, so the terminal can be exercised
/// end to end before the host list exists. Phase 4 replaces this with the real
/// list, and nothing here is meant to survive it — the host is not saved.
struct RootView: View {

    @Environment(\.appEnvironment) private var environment

    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    @State private var showsTerminal = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Hostname", text: $hostname)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)

                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    SecureField("Password (optional)", text: $password)
                }

                Section {
                    Button("Connect") { connect() }
                        .disabled(hostname.isEmpty || username.isEmpty)
                } footer: {
                    Text("Leave the password empty to be prompted after the host key is verified.")
                }

                if !environment.sessions.sessions.isEmpty {
                    Section("Open sessions") {
                        Button("Back to terminal") { showsTerminal = true }
                    }
                }
            }
            .navigationTitle("SSHBorg")
            .navigationDestination(isPresented: $showsTerminal) {
                TerminalScreen(manager: environment.sessions)
            }
        }
    }

    private func connect() {
        let host = Host(
            label: hostname,
            hostname: hostname,
            port: Int(port) ?? 22,
            username: username,
            password: password.isEmpty ? nil : password
        )

        environment.sessions.open(
            host: host,
            hosts: environment.hosts,
            keys: environment.keys
        )
        showsTerminal = true
    }
}

#Preview {
    RootView()
        .environment(\.appEnvironment, .inMemory())
}
