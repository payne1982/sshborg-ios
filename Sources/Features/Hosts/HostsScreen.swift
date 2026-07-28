// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The host list, and the app's home screen.
///
/// Ported from the Android `HostsScreen`: ungrouped hosts first with no header,
/// then one collapsible section per group, a host's own colour overriding its
/// group's, and a badge for open sessions.
///
/// Two Android behaviours have no counterpart here. Double-back-to-exit is
/// meaningless because iOS apps do not quit on a back gesture, and the SFTP
/// affordance waits for phase 6 rather than shipping a dead button.
struct HostsScreen: View {

    @Environment(\.appEnvironment) private var environment
    @State private var model: HostsModel?
    @State private var hostToDelete: Host?
    @State private var editing: EditorTarget?
    @State private var sessionPickerHost: Host?
    @State private var groupEditing: GroupEditorTarget?
    @State private var groupToDelete: HostGroup?

    /// What the editor sheet is currently doing.
    private enum EditorTarget: Identifiable {
        case new
        case existing(Host)

        var id: Int64 {
            switch self {
            case .new: -1
            case .existing(let host): host.id ?? -1
            }
        }
    }

    private enum GroupEditorTarget: Identifiable {
        case new
        case existing(HostGroup)

        var id: Int64 {
            switch self {
            case .new: -1
            case .existing(let group): group.id ?? -1
            }
        }
    }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Hosts")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    KeysScreen()
                } label: {
                    Label("SSH keys", systemImage: "key")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New host", systemImage: "desktopcomputer") { editing = .new }
                    Button("New group", systemImage: "folder") { groupEditing = .new }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .task {
            let model = model ?? HostsModel(hosts: environment.hosts, groups: environment.groups)
            self.model = model
            await model.observe()
        }
        .sheet(item: $editing) { target in
            NavigationStack {
                switch target {
                case .new:
                    HostEditorScreen(host: nil)
                case .existing(let host):
                    HostEditorScreen(host: host)
                }
            }
        }
        .sheet(item: $sessionPickerHost) { host in
            SessionPickerSheet(host: host) { sessionPickerHost = nil }
        }
        .alert(
            "Delete host?",
            isPresented: .init(get: { hostToDelete != nil }, set: { if !$0 { hostToDelete = nil } }),
            presenting: hostToDelete
        ) { host in
            Button("Cancel", role: .cancel) { hostToDelete = nil }
            Button("Delete", role: .destructive) {
                let target = host
                hostToDelete = nil
                Task { await model?.delete(target) }
            }
        } message: { host in
            Text("\(host.label) will be removed. Sessions already open stay connected.")
        }
        .sheet(item: $groupEditing) { target in
            NavigationStack {
                switch target {
                case .new:
                    GroupEditorScreen(group: nil)
                case .existing(let group):
                    GroupEditorScreen(group: group)
                }
            }
        }
        .alert(
            "Delete group?",
            isPresented: .init(get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } }),
            presenting: groupToDelete
        ) { group in
            Button("Cancel", role: .cancel) { groupToDelete = nil }
            Button("Delete", role: .destructive) {
                let target = group
                groupToDelete = nil
                Task { await model?.delete(target) }
            }
        } message: { group in
            Text("\(group.name) will be removed. Its hosts are kept and become ungrouped.")
        }
    }

    @ViewBuilder
    private func content(_ model: HostsModel) -> some View {
        if model.isEmpty {
            ContentUnavailableView {
                Label("No hosts", systemImage: "desktopcomputer")
            } description: {
                Text("Add a host to connect to it.")
            } actions: {
                Button("Add host") { editing = .new }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                ForEach(model.sections) { section in
                    if let group = section.group {
                        Section {
                            if !group.collapsed {
                                rows(for: section.hosts, model: model)
                            }
                        } header: {
                            GroupHeader(group: group, count: section.hosts.count) {
                                Task { await model.toggleCollapsed(group) }
                            }
                            .contextMenu {
                                Button("Edit", systemImage: "pencil") { groupEditing = .existing(group) }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    groupToDelete = group
                                }
                            }
                        }
                    } else {
                        Section {
                            rows(for: section.hosts, model: model)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func rows(for hosts: [Host], model: HostsModel) -> some View {
        ForEach(hosts) { host in
            HostRow(
                host: host,
                tint: model.color(for: host).map { Color(argb: $0) },
                sessionCount: environment.sessions.sessions(forHostID: host.id ?? -1).count
            )
            .contentShape(.rect)
            .onTapGesture { open(host) }
            // Swipe reaches edit only. Deleting a host throws away its stored
            // credentials and pinned host key, and SwiftUI promotes the first
            // trailing action to the full-swipe gesture — so putting delete
            // here would let a slightly long swipe destroy it with no
            // deliberate press. Delete lives in the context menu instead.
            .swipeActions(edge: .trailing) {
                Button("Edit", systemImage: "pencil") { editing = .existing(host) }
                    .tint(.blue)
            }
            .contextMenu {
                Button("New terminal", systemImage: "terminal") { openNew(host) }
                Button("Edit", systemImage: "pencil") { editing = .existing(host) }
                Button("Delete", systemImage: "trash", role: .destructive) { hostToDelete = host }
            }
        }
    }

    // MARK: - Opening sessions

    /// Tapping a host reuses its session when there is exactly one, and asks
    /// when there are several — the same rule as the Android list.
    private func open(_ host: Host) {
        let existing = environment.sessions.sessions(forHostID: host.id ?? -1)

        switch existing.count {
        case 0: openNew(host)
        case 1: environment.sessions.selectedID = existing[0].id
        default: sessionPickerHost = host
        }
    }

    private func openNew(_ host: Host) {
        environment.sessions.open(host: host, hosts: environment.hosts, keys: environment.keys)
    }
}

/// The header of a group section: colour dot, name, count, collapse state.
private struct GroupHeader: View {

    let group: HostGroup
    let count: Int
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: group.collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Circle()
                    .fill(group.swiftUIColor)
                    .frame(width: 10, height: 10)

                Text(group.name)
                Text("(\(count))")
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .textCase(nil)
    }
}

/// One host: tinted icon, label, and the `user@host:port` line.
private struct HostRow: View {

    let host: Host
    let tint: Color?
    let sessionCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(tint ?? .primary)
                .font(.title3)
                .overlay(alignment: .topTrailing) {
                    if sessionCount > 0 {
                        Text("\(sessionCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Color.accentColor, in: .circle)
                            .offset(x: 7, y: -7)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(host.label)
                Text("\(host.username)@\(host.hostname):\(String(host.port))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}

/// Shown when a host already has more than one session open.
private struct SessionPickerSheet: View {

    @Environment(\.appEnvironment) private var environment
    let host: Host
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(environment.sessions.sessions(forHostID: host.id ?? -1).enumerated()), id: \.element.id) { index, session in
                    Button {
                        environment.sessions.selectedID = session.id
                        onDismiss()
                    } label: {
                        HStack {
                            Image(systemName: "terminal")
                            VStack(alignment: .leading) {
                                Text("Session \(index + 1)")
                                Text(status(of: session))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Button {
                    environment.sessions.open(host: host, hosts: environment.hosts, keys: environment.keys)
                    onDismiss()
                } label: {
                    Label("New session", systemImage: "plus")
                }
            }
            .navigationTitle(host.label)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private func status(of session: TerminalSession) -> String {
        switch session.phase {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .needsPassword: "Waiting for a password"
        case .needsHostKeyApproval: "Waiting for host key approval"
        case .failed: "Failed"
        case .disconnected: "Disconnected"
        }
    }
}
