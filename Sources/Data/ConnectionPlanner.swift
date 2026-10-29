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
    /// - Parameters:
    ///   - host: the machine this session dials and logs in to. The host itself,
    ///     or — when the chain is walked from a bastion — the bastion.
    ///   - destination: the machine actually being reached, when that is not
    ///     `host`. Passing it says "the rest of the way is walked by the
    ///     bastion's own ssh", which changes three things and nothing else.
    func params(
        for host: Host,
        destination: Host? = nil,
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
        // Only for a mosh host, as Android does it: the setting is about the
        // family a mosh session will be stuck on, and asking a plain SSH host to
        // prefer one would be a different promise.
        if host.mosh {
            params.addressPreference = SSHSocket.AddressPreference(column: host.moshFamily)
        }
        if let destination {
            // Nothing left for SSH to tunnel: what was the first hop is the
            // machine being dialled, and the hops after it are on the `ssh` line
            // the bastion runs.
            params.jumpHosts = []
            // The destination's rules, on the bastion's session — the one
            // session SSH still has when the rest of the way is walked by the
            // bastion's own client. A rule naming a machine reaches it exactly
            // as before, the bastion being on the same side of the door. A rule
            // saying `localhost` does not: that name is resolved by the far end
            // of the session, and that end is now the bastion.
            params.portForwardings = PortForwarding.parseList(destination.portForwardings)
            // Either row asking for it is enough. The hop that needs the key is
            // the bastion, and the host that needs it is the one behind it, so
            // demanding the switch on both would only mean the `ssh` line
            // failing for a reason nobody would look for in the other form.
            params.agentForwarding = destination.agentForwarding || host.agentForwarding
        } else {
            params.agentForwarding = host.agentForwarding
            params.portForwardings = PortForwarding.parseList(host.portForwardings)
            params.jumpHosts = await jumpHosts(for: host)
        }

        if params.agentForwarding {
            params.agentIdentities = await agentIdentities()
        }

        return params
    }

    /// The bastion this host is reached *from*, and the one line that walks the
    /// rest of the way, or nil when the chain is tunnelled as it always was.
    ///
    /// Mosh cannot be tunnelled: a jump hop is an SSH channel inside the hop's
    /// own connection, and mosh has no channels at all. So a host whose **first
    /// hop** is itself a mosh host is reached from the other end — the session
    /// is made to that bastion over mosh, and the rest is typed into it as one
    /// `ssh` command. See ``BastionHop`` for why one command and not a hop at a
    /// time.
    ///
    /// The bastion's own switch is the whole decision, and there is deliberately
    /// nothing to tick on the host's row: a second consent would only be a
    /// second way to be puzzled, and a host's mosh switch already means "reach
    /// *me* over mosh" wherever it is read from. A chain whose first hop has
    /// mosh off is tunnelled exactly as before.
    ///
    /// Only the terminal takes this road. The SFTP tab opens a session of its
    /// own through the whole chain as it always did, because that one is SSH and
    /// can be tunnelled — which is why this is asked for by the terminal and not
    /// built into ``params(for:destination:auth:hostKeyPolicy:)``.
    ///
    /// A saved password on the destination does not change any of it. Past the
    /// bastion every login is run by the bastion's own ssh, which cannot be
    /// handed a password we hold — so it asks, in the terminal, and the person
    /// answers it there. A prompt is not a failure.
    func bastionWalk(for host: Host) async -> (bastion: Host, line: String)? {
        // Only the host-list mode has rows to read a switch from. Typed text
        // carries no mosh flag, which is not a gap: a hop nobody has a record of
        // is a hop nothing is known about.
        guard host.parsedJumpMode == .hostList else { return nil }

        var hops: [Host] = []
        for id in host.jumpHostIDs {
            guard let record = try? await hosts.fetch(id: id) else { continue }
            hops.append(record)
        }

        guard let bastion = hops.first, bastion.mosh else { return nil }

        // A name no shell can be trusted with is the one way out of the
        // arrangement: the bastion is given up on and the ordinary chain is
        // walked instead, which is what this host did before any of this
        // existed.
        guard let line = BastionHop.compose(
            target: BastionHop.Endpoint(user: host.username, host: host.hostname, port: host.port),
            through: hops.dropFirst().map {
                BastionHop.Endpoint(user: $0.username, host: $0.hostname, port: $0.port)
            }
        ) else { return nil }

        return (bastion, line)
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
            let incoming = collected.map(\.knownHostsLine)
            // A new key for a hop takes the place of its old one rather than
            // sitting beside it: two lines for one machine, and the old one
            // would still be found first.
            let replaced = Set(incoming.compactMap { KnownHostsLine.parse($0)?.marker })
            let kept = existing.filter { line in
                guard let marker = KnownHostsLine.parse(line)?.marker else { return true }
                return !replaced.contains(marker)
            }
            let merged = kept + incoming
            try? await hosts.updateJumpHostKeys(
                id: id,
                to: merged.joined(separator: "\n")
            )
        }
    }
}
