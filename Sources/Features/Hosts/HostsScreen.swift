// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The host list, and the app's home screen.
///
/// Ported from the Android `HostsScreen`: ungrouped hosts first with no header,
/// then one collapsible section per group, a host's own colour overriding its
/// group's, and a badge for open sessions.
///
/// Double-back-to-exit has no counterpart here: iOS apps do not quit on a back
/// gesture. Open sessions are marked as Android marks them, with two separate
/// badges — a count for shells, a folder for a file browser — because a host can
/// have either without the other.
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
            // All three on the trailing side, in the Android order: keys,
            // settings, add. The Android top bar puts them in `actions`, which
            // is the right-hand group, and a user moving between the two builds
            // should not have to look for them somewhere else.
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    KeysScreen()
                } label: {
                    Label(String(localized: .keysTitle), systemImage: "key")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
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
                sessionCount: environment.sessions.sessions(forHostID: host.id ?? -1).count,
                hasFileBrowser: environment.browsers.isOpen(hostID: host.id),
                onOpenFiles: { browsing = host },
                // The same actions the long press gives, from a control that
                // says it is there. A context menu is native on iOS and close to
                // invisible: nothing on a row announces that holding it does
                // anything. Android carries both — a `MoreVert` button beside
                // the row and a long press — opening one menu, and so does this.
                actions: { AnyView(hostActions(host, model: model)) }
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
            .contextMenu { hostActions(host, model: model) }
        }
    }

    /// Everything a host can be told to do, in Android's order.
    ///
    /// One definition feeding both the long press and the button: two lists of
    /// the same actions drift, and the one nobody looks at drifts first.
    @ViewBuilder
    private func hostActions(_ host: Host, model: HostsModel) -> some View {
        Button(String(localized: .hostMenuNewTerminal), systemImage: "terminal") { openNew(host) }
        Button(String(localized: .hostMenuFiles), systemImage: "folder") { browsing = host }
        Button(String(localized: .actionEdit), systemImage: "pencil") { editing = .existing(host) }
        // Between Edit and Delete, as on Android. The copy opens in the editor
        // straight away: nobody duplicates a host to leave it identical, so
        // landing on the form is the next step either way.
        Button(String(localized: .actionDuplicate), systemImage: "doc.on.doc") {
            Task {
                if let copy = await model.duplicate(host) { editing = .existing(copy) }
            }
        }
        Button(String(localized: .actionDelete), systemImage: "trash", role: .destructive) {
            hostToDelete = host
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

    /// An SFTP browser left open for this host. A separate mark from the session
    /// count, as on Android, because they are separate things: one is shells,
    /// the other is a file browser, and a host can have either without the
    /// other. Losing that distinction is how an SFTP session left running became
    /// invisible from the list.
    let hasFileBrowser: Bool

    /// Tapping the folder goes back into the browser that is already open, which
    /// is the whole use for a badge that says one is. Android wires its badges
    /// the same way: `Modifier.clickable { onSftp() }` around the folder.
    let onOpenFiles: () -> Void

    /// The row's own menu, the same one the long press opens.
    let actions: () -> AnyView

    var body: some View {
        HStack(spacing: 12) {
            // Icon, then the marks stacked beside it — Android's arrangement,
            // a `Column` of badges next to the computer icon rather than a badge
            // pinned to its corner. Keeping them together in one place means one
            // glance answers "what is open on this host", and it leaves the name
            // to be a name.
            Image(systemName: "desktopcomputer")
                .foregroundStyle(tint ?? .primary)
                .font(.title3)

            if sessionCount > 0 || hasFileBrowser {
                VStack(spacing: 3) {
                    if sessionCount > 0 {
                        Text(verbatim: "\(sessionCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Color.accentColor, in: .circle)
                            .accessibilityLabel(String(localized: .hostMenuNewTerminal))
                    }
                    // Android's amber folder, without its digit: it counts
                    // because it can hold several browsers per host, and this
                    // holds one.
                    if hasFileBrowser {
                        Button(action: onOpenFiles) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(red: 0.976, green: 0.659, blue: 0.145))
                                // Bigger than it looks: a 15pt glyph is a hard
                                // thing to hit, so the tappable area is padded
                                // out around it, as Android pads its badge by
                                // 4dp for the same reason.
                                .frame(width: 15, height: 15)
                                .padding(4)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: .hostMenuFiles))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(host.label)
                Text(verbatim: "\(host.username)@\(host.hostname):\(String(host.port))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                actions()
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
            }
            .accessibilityLabel(String(localized: .hostsOptionsCd))
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
                                Text(String(localized: .sessionPickerSessionLabel).replacingOccurrences(of: "%1$d", with: "\(index + 1)"))
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
