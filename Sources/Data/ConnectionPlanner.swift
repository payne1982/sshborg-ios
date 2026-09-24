// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Turns a stored ``Host`` into the parameters needed to connect to it.
///
/// This exists because the mapping is not one field to one field. A host record
/// keeps jump hosts as text or as a list of other host IDs, port forwards as
/// text, and agent forwarding as a flag whose meaning is "offer every key the
/// app holds" — so reaching ``SSHConnectionParams`` means parsing, and in
/// host-list mode reading other records and their credentials out of the
/// keychain.
///
/// Three call sites need it (terminal, SFTP, history) and each used to build
/// the parameters by hand, which is why jump hosts and port forwarding were
/// saved but inert: the fields existed and nothing translated them. One builder
/// is what stops a fourth caller from quietly omitting a field again.
struct ConnectionPlanner {

    let hosts: HostRepository
    let keys: SSHKeyRepository

    init(hosts: HostRepository, keys: SSHKeyRepository) {
        self.hosts = hosts
        self.keys = keys
    }

    /// Builds the parameters for `host`.
    ///
    /// `auth` is passed in rather than resolved here because the caller may have
    /// just asked the user for a password, and that answer has to win over
    /// anything stored.
    func params(
        for host: Host,
        auth: SSHAuth,
        hostKeyPolicy: HostKeyPolicy
    ) async -> SSHConnectionParams {
        var params = SSHConnectionParams(
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            auth: auth,
            allowLegacyCiphers: host.allowLegacyCiphers
        )
        params.hostKeyPolicy = hostKeyPolicy
        params.agentForwarding = host.agentForwarding
        params.portForwardings = PortForwarding.parseList(host.portForwardings)
        params.jumpHosts = await jumpHosts(for: host)

        if host.agentForwarding {
            params.agentIdentities = await agentIdentities()
        }

        return params
    }

    /// Credentials stored for a host, with no user interaction.
    ///
    /// Returns `nil` when the host has none, which for a jump host means the
    /// hop falls back to the target's credentials — the behaviour an
    /// `ssh_config` `ProxyJump` has.
    func storedAuth(for host: Host) async -> SSHAuth? {
        if let keyId = host.keyId {
            guard let key = try? await keys.fetch(id: keyId),
                  let pem = KeychainCrypto.privateKeyPEM(for: key)
            else { return nil }
            return .publicKey(privateKeyPEM: pem)
        }
        return KeychainCrypto.password(for: host).map { SSHAuth.password($0) }
    }

    // MARK: - Jump hosts

    private func jumpHosts(for host: Host) async -> [JumpHost] {
        switch host.parsedJumpMode {
        case .simple:
            return JumpHost.parseList(host.jumpHosts, knownHostKeys: host.jumpHostKeys)
        case .hostList:
            return await jumpHostsFromRecords(ids: host.jumpHostIDs)
        }
    }

    /// Resolves stored hosts used as hops, in the order the user arranged them.
    ///
    /// A hop whose record has been deleted is skipped rather than failing the
    /// connection: the alternative is a host that cannot connect at all with no
    /// way to see why, and the remaining chain is still what the user asked for
    /// minus a hop that no longer exists.
    private func jumpHostsFromRecords(ids: [Int64]) async -> [JumpHost] {
        var result: [JumpHost] = []

        for id in ids {
            guard let record = try? await hosts.fetch(id: id) else { continue }

            result.append(
                JumpHost(
                    host: record.hostname,
                    port: record.port,
                    username: record.username,
                    knownHostsEntry: record.knownHostsEntry,
                    auth: await storedAuth(for: record),
                    hostId: record.id
                )
            )
        }

        return result
    }

    // MARK: - Agent

    /// Every key the app can read, offered to the forwarded agent.
    ///
    /// A key that will not decrypt is left out rather than treated as an error:
    /// it would otherwise stop the connection over a key the user may not even
    /// have meant to forward. The remote `ssh-add -l` shows what did load.
    private func agentIdentities() async -> [AgentIdentity] {
        guard let stored = try? await keys.fetchAll() else { return [] }

        return stored.compactMap { key in
            guard let pem = KeychainCrypto.privateKeyPEM(for: key) else { return nil }
            return AgentIdentity(privateKeyPEM: pem, passphrase: nil, comment: key.label)
        }
    }
}

extension ConnectionPlanner {

    /// Writes back the host keys collected from hops on first connection.
    ///
    /// Without this the chain is verified once and never again: every later
    /// connection would see an unknown key for each hop and accept it, which is
    /// the trust-on-every-use behaviour ``HostKeyPolicy/promptIfUnknown`` exists
    /// to avoid.
    func persistJumpHostKeys(_ collected: [SSHSession.JumpHostKey], for host: Host) async {
        guard !collected.isEmpty else { return }

        switch host.parsedJumpMode {
        case .hostList:
            // Each hop is a host record of its own, so its key belongs there and
            // is then shared by every chain using that hop.
            for entry in collected {
                guard let id = entry.hostId else { continue }
                try? await hosts.updateKnownHostsEntry(id: id, to: entry.knownHostsLine)
            }

        case .simple:
            // The hops are only text on this host, so their keys are kept here,
            // one line per hop, in the order they were collected.
            guard let id = host.id else { return }
            let existing = host.jumpHostKeys.map { $0.split(whereSeparator: \.isNewline).map(String.init) } ?? []
            let merged = existing + collected.map(\.knownHostsLine)
            try? await hosts.updateJumpHostKeys(
                id: id,
                to: merged.joined(separator: "\n")
            )
        }
    }
}
