// SPDX-License-Identifier: GPL-3.0-or-later

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
    @State private var browsing: Host?

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
        .navigationTitle(Text(.hostsTitle))
        .navigationDestination(item: $browsing) { host in
            SFTPScreen(host: host)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    KeysScreen()
                } label: {
                    Label(String(localized: .keysTitle), systemImage: "key")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    SettingsScreen()
                } label: {
                    Label(String(localized: .settingsTitle), systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(String(localized: .addHostTitle), systemImage: "desktopcomputer") { editing = .new }
                    Button(String(localized: .groupDialogTitleNew), systemImage: "folder") { groupEditing = .new }
                } label: {
                    Label(String(localized: .hostsAddHostCd), systemImage: "plus")
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
            String(localized: .hostsDeleteTitle),
            isPresented: .init(get: { hostToDelete != nil }, set: { if !$0 { hostToDelete = nil } }),
            presenting: hostToDelete
        ) { host in
            Button(String(localized: .actionCancel), role: .cancel) { hostToDelete = nil }
            Button(String(localized: .actionDelete), role: .destructive) {
                let target = host
                hostToDelete = nil
                Task { await model?.delete(target) }
            }
        } message: { host in
            Text(String(localized: .hostsDeleteMessage).replacingOccurrences(of: "%1$@", with: host.label))
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
            String(localized: .groupDeleteTitle),
            isPresented: .init(get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } }),
            presenting: groupToDelete
        ) { group in
            Button(String(localized: .actionCancel), role: .cancel) { groupToDelete = nil }
            Button(String(localized: .actionDelete), role: .destructive) {
                let target = group
                groupToDelete = nil
                Task { await model?.delete(target) }
            }
        } message: { group in
            Text(String(localized: .groupDeleteMessage).replacingOccurrences(of: "%1$@", with: group.name))
        }
    }

    /// First line of `hosts_empty`, and the rest of it.
    ///
    /// Every translation keeps the two-line shape, so splitting on the newline
    /// works in all ten; a language that did not would simply get a heading and
    /// no detail, which still reads correctly.
    private static var emptyStateLines: [String] {
        String(localized: .hostsEmpty)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static var emptyStateHeading: String {
        emptyStateLines.first ?? String(localized: .hostsEmpty)
    }

    private static var emptyStateDetail: String? {
        let lines = emptyStateLines
        guard lines.count > 1 else { return nil }
        return lines.dropFirst().joined(separator: " ")
    }

    @ViewBuilder
    private func content(_ model: HostsModel) -> some View {
        if model.isEmpty {
            // `hosts_empty` is two lines on Android — a heading and the
            // instruction under it — so it is split back into the two slots iOS
            // has for them. Passing the whole thing as the title rendered both
            // lines in large bold, which is not what either platform intends.
            //
            // No button here on purpose. The text says to tap +, the + is in the
            // toolbar above, and adding a second control that does the same thing
            // left the screen telling the user to do one thing while offering
            // another. Android has the one affordance; so does this.
            ContentUnavailableView {
                Label(Self.emptyStateHeading, systemImage: "desktopcomputer")
            } description: {
                if let detail = Self.emptyStateDetail {
                    Text(detail)
                }
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
                                Button(String(localized: .actionEdit), systemImage: "pencil") { groupEditing = .existing(group) }
                                Button(String(localized: .actionDelete), systemImage: "trash", role: .destructive) {
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
                Button(String(localized: .actionEdit), systemImage: "pencil") { editing = .existing(host) }
                    .tint(.blue)
            }
            .contextMenu {
                Button(String(localized: .hostMenuNewTerminal), systemImage: "terminal") { openNew(host) }
                Button(String(localized: .hostMenuFiles), systemImage: "folder") { browsing = host }
                Button(String(localized: .actionEdit), systemImage: "pencil") { editing = .existing(host) }
                Button(String(localized: .actionDelete), systemImage: "trash", role: .destructive) { hostToDelete = host }
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
                Text(verbatim: "(\(count))")
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
                        Text(verbatim: "\(sessionCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Color.accentColor, in: .circle)
                            .offset(x: 7, y: -7)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(host.label)
                Text(verbatim: "\(host.username)@\(host.hostname):\(String(host.port))")
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
                                Text(String(localized: .iosSessionNumber).replacingOccurrences(of: "%1$d", with: "\(index + 1)"))
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
