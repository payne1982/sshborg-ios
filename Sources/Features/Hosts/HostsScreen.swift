// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Perception

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
    /// The host whose file browser is open, and whether it is on screen.
    ///
    /// Two properties rather than the one `navigationDestination(item:)` would
    /// need, because that overload is iOS 17. The iOS 16 form is driven by a
    /// Bool, and the host has to outlive it: clearing the host as the pop
    /// begins would empty the destination while it is still animating out, and
    /// flash blank. So `browsing` is only ever replaced by the next host, never
    /// cleared.
    @State private var browsing: Host?
    @State private var isBrowsing = false

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
        WithPerceptionTracking {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(Text(.hostsTitle))
            .navigationDestination(isPresented: $isBrowsing) {
                if let browsing {
                    SFTPScreen(host: browsing)
                }
            }
            .toolbar {
                // All three on the trailing side, in the Android order: keys,
                // settings, add. The Android top bar puts them in `actions`, which
                // is the right-hand group, and a user moving between the two builds
                // should not have to look for them somewhere else.
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        KeysScreen()
                    } label: {
                        Label(String(localized: .keysTitle), systemImage: "key")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        SettingsScreen()
                    } label: {
                        Label(String(localized: .settingsTitle), systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
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
            EmptyStateView {
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
            // A ForEach row builder is escaping, so the wrapper on the body does
            // not reach in here — and these two lines are the badges that say how
            // many terminals and whether a file browser is open on this host.
            // Untracked, they would show whatever was true when the list was
            // built. Reported by the device as 25 warnings for
            // SessionManager.sessions and 8 for SFTPBrowsers.models.
            WithPerceptionTracking {
                HostRow(
                    host: host,
                    tint: model.color(for: host).map { Color(argb: $0) },
                    sessionCount: environment.sessions.sessions(forHostID: host.id ?? -1).count,
                    hasFileBrowser: environment.browsers.isOpen(hostID: host.id),
                    onOpenFiles: { browsing = host; isBrowsing = true },
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
    }

    /// Everything a host can be told to do, in Android's order.
    ///
    /// One definition feeding both the long press and the button: two lists of
    /// the same actions drift, and the one nobody looks at drifts first.
    ///
    /// The first entries read the running sessions and change with them, as
    /// Android's do: "Connect" becomes "Resume terminal (2)" once there are two,
    /// and a separate "New terminal" appears only when resuming is a different
    /// thing from connecting. With nothing open the two would be the same
    /// action twice.
    @ViewBuilder
    private func hostActions(_ host: Host, model: HostsModel) -> some View {
        // Reached through `actions:` — an escaping closure — and through
        // .contextMenu, so this is built outside the body pass and needs its own
        // scope. The first entries change with the running sessions: "Connect"
        // becomes "Resume terminal (2)". Untracked, they change with nothing.
        WithPerceptionTracking {
            let shells = environment.sessions.sessions(forHostID: host.id ?? -1).count
            let hasBrowser = environment.browsers.isOpen(hostID: host.id)

            Button {
                open(host)
            } label: {
                Label {
                    if shells > 0 {
                        Text(String(localized: .hostMenuResumeTerminal)
                            .replacingOccurrences(of: "%1$d", with: "\(shells)"))
                    } else {
                        Text(.hostMenuConnect)
                    }
                } icon: {
                    Image(systemName: "terminal")
                }
            }

            if shells > 0 {
                Button(String(localized: .hostMenuNewTerminal), systemImage: "plus") { openNew(host) }
            }

            Button {
                browsing = host
                isBrowsing = true
            } label: {
                Label {
                    // The count is always one when it appears: this holds a single
                    // browser per host, keyed by its id, where Android can hold
                    // several. Hence no "New files session" either — there is
                    // nothing for a second one to be.
                    if hasBrowser {
                        Text(String(localized: .hostMenuResumeFiles)
                            .replacingOccurrences(of: "%1$d", with: "1"))
                    } else {
                        Text(.hostMenuFiles)
                    }
                } icon: {
                    Image(systemName: "folder")
                }
            }
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
        WithPerceptionTracking {
            NavigationStack {
                List {
                    ForEach(Array(environment.sessions.sessions(forHostID: host.id ?? -1).enumerated()), id: \.element.id) { index, session in
                        // A ForEach row builder is escaping: it runs outside the
                        // body pass above, so the wrapper up there does not reach
                        // it. `status(of:)` reads the session's phase, which is
                        // what makes a row say "connecting" and then "connected".
                        WithPerceptionTracking {
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
                    }

                    Button {
                        environment.sessions.open(host: host, hosts: environment.hosts, keys: environment.keys)
                        onDismiss()
                    } label: {
                        Label(
                            String(localized: .sessionPickerNewSession)
                                .replacingOccurrences(
                                    of: "%1$@",
                                    with: String(localized: .sessionTypeTerminal)
                                ),
                            systemImage: "plus"
                        )
                    }
                }
                .navigationTitle(host.label)
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
    }

    /// Android's four session states plus the two this app can tell apart. It
    /// asks its own question before connecting, so a session sitting on the
    /// password prompt is not the same as one still dialling — and in a list
    /// whose job is "which of these do I go back to", that is the difference
    /// between one that needs you and one that does not.
    private func status(of session: TerminalSession) -> String {
        switch session.phase {
        case .connected: String(localized: .sessionStatusConnected)
        case .connecting: String(localized: .sessionStatusConnecting)
        case .needsPassword: String(localized: .iosSessionStatusNeedsPassword)
        case .needsHostKeyApproval: String(localized: .iosSessionStatusNeedsHostKey)
        case .failed: String(localized: .sessionStatusError)
        case .disconnected: String(localized: .sessionStatusDisconnected)
        }
    }
}
