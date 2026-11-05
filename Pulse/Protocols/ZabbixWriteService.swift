//
//  ZabbixWriteService.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  Pulse
//  The Platform for Unified Leadership in Smart Environments.
//
//  This program is distributed to enable communities to build and maintain their own
//  digital sovereignty through local control of critical infrastructure data.
//
//  By open sourcing Pulse, we create a circular economy where contributors can both build
//  upon and benefit from the platform, ensuring that value flows back to communities rather
//  than being extracted by external entities. This aligns with our commitment to intergenerational
//  prosperity through collaborative stewardship of public infrastructure.
//
//  This program is free software: communities can deploy it for sovereignty, academia can
//  extend it for research, and industry can integrate it for resilience — all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import os
import SwiftData
import SwiftUI

/// The targeted problem refresh after a successful acknowledge. `getProblems`
/// logs and publishes its own failure, and it does not throw. The ask still
/// retires. Tests pause a fake. The problem GET is not moved onto `ZabbixTransport`.
protocol ZabbixProblemRefreshing: Sendable {
    func refreshProblems(eventIds: [String]) async
}

extension SiteDataService: ZabbixProblemRefreshing {
    func refreshProblems(eventIds: [String]) async {
        await getProblems(using: eventIds)
    }
}

/// Builds the `event.acknowledge` request. The live value reads the
/// configured server and the keychain token. Tests supply a recorder so
/// they do not write that token.
protocol ZabbixAcknowledgeRequesting: Sendable {
    func request(for draft: ProblemUpdateDraft) async throws -> URLRequest
}

struct LiveZabbixAcknowledgeRequest: ZabbixAcknowledgeRequesting {
    func request(for draft: ProblemUpdateDraft) async throws -> URLRequest {
        try await EventAcknowledgeResource(params: draft.requestBody).request
    }
}

/// Sends problem updates and owns their asks. Views call this through
/// `@Environment(\.zabbixWriteService)`. Nothing else calls `event.acknowledge`.
actor ZabbixWriteService {
    private let pendingWrites: PendingWrites
    private let problems: any ZabbixProblemRefreshing
    private let container: ModelContainer
    private let seats: LicenseSeatStore
    private let tier: @Sendable () -> SubscriptionTier
    private let transport: any ZabbixTransport
    private let requests: any ZabbixAcknowledgeRequesting
    private let logger = Logger(subsystem: "zabbix", category: "write")
    private var submittedFlight: Task<Void, Never>?

    init(
        pendingWrites: PendingWrites,
        problems: any ZabbixProblemRefreshing,
        container: ModelContainer,
        seats: LicenseSeatStore,
        tier: @escaping @Sendable () -> SubscriptionTier,
        transport: any ZabbixTransport,
        requests: any ZabbixAcknowledgeRequesting = LiveZabbixAcknowledgeRequest()
    ) {
        self.pendingWrites = pendingWrites
        self.problems = problems
        self.container = container
        self.seats = seats
        self.tier = tier
        self.transport = transport
        self.requests = requests
    }

    /// Records each ask, returns the tokens, then runs them. The await
    /// is the hop that puts `.posting` on screen. It is not the RPC.
    /// One failure marks that ask and the rest continue.
    func submit<I: ZabbixWriteIntent>(_ intents: [I]) async -> [WriteToken] {
        guard !intents.isEmpty else { return [] }
        let pairs = intents.map { (token: WriteToken(), intent: $0) }
        let pending = pendingWrites
        let superseded = await MainActor.run { () -> [WriteToken] in
            guard I.kindName == ProblemUpdateIntent.kindName else { return [] }
            var tokens: [WriteToken] = []
            var seen = Set<WriteToken>()
            for pair in pairs {
                guard case .events(let newIds) = pair.intent.scope else { continue }
                let covered = pending.ghosts(of: ProblemUpdateIntent.self, in: .events(newIds))
                    .filter { $0.ghost.eventIds.isSubset(of: newIds) }
                    .map(\.token)
                for token in covered where seen.insert(token).inserted {
                    tokens.append(token)
                }
            }
            return tokens
        }
        for token in superseded {
            await discard(token)
        }
        await MainActor.run {
            pending.stage(pairs)
        }
        logger.info("write staged \(pairs.count) \(I.kindName, privacy: .public)")
        let previous = submittedFlight
        let flight = Task { [pairs] in
            await previous?.value
            await self.runSubmitted(pairs)
        }
        submittedFlight = flight
        return pairs.map(\.token)
    }

    /// Drops an ask and its notice. The sheet offers this after failure,
    /// once the replacement ask has been staged.
    func discard(_ token: WriteToken) async {
        let pending = pendingWrites
        let removed = await MainActor.run {
            pending.discard(token: token)
        }
        if removed {
            logger.info("write discarded token \(token.id.uuidString, privacy: .public)")
        }
    }

    /// Awaits every `submit` that has been recorded, including earlier ones.
    func waitForSubmittedWrites() async {
        await submittedFlight?.value
    }

    /// The one `event.acknowledge` call. Returns Zabbix's `result.eventids`
    /// as strings. The public examples use both strings and numbers.
    func acknowledge(_ draft: ProblemUpdateDraft) async throws -> [String] {
        let request = try await requests.request(for: draft)
        let data = try await transport.send(request)
        let ids = try Self.eventIDs(from: data)
        logger.info("event.acknowledge accepted for \(draft.eventIds.count) events")
        return ids
    }

    /// Seat check, send, mark committed, refresh, then retire `.zabbix` on
    /// the next main-actor turn. A refresh failure is the log line
    /// `getProblems` already writes. The ask still retires.
    func runProblemUpdate(_ intent: ProblemUpdateIntent, token: WriteToken) async throws {
        if let message = seatRefusal(for: intent.draft.eventIds) {
            await storeFailure(token, message: message, status: nil)
            return
        }
        let ids = try await intent.send(through: self)
        let committedID = Int64(ids.first ?? "") ?? 0
        let pending = pendingWrites
        await MainActor.run {
            pending.markCommitted(token: token, id: committedID)
        }
        logger.info(
            "write committed token \(token.id.uuidString, privacy: .public) events \(intent.draft.eventIds.count)"
        )
        await problems.refreshProblems(eventIds: intent.draft.eventIds)
        await MainActor.run {
            pending.retireCommitted(provider: .zabbix)
        }
    }

    private func runSubmitted<I: ZabbixWriteIntent>(
        _ pairs: [(token: WriteToken, intent: I)]
    ) async {
        for pair in pairs {
            do {
                try await pair.intent.perform(on: self, token: pair.token)
            } catch {
                await fail(pair.token, error)
            }
        }
    }

    /// Copies device ids off a fresh context. An `Event` does not leave
    /// this function. A missing device, or one `allowsActions` refuses,
    /// refuses the whole ask. One token is one RPC, so a partial send
    /// would be a lie.
    private func seatRefusal(for eventIds: [String]) -> String? {
        let context = ModelContext(container)
        for eventId in eventIds {
            let id = eventId
            let descriptor = FetchDescriptor<Event>(
                predicate: #Predicate<Event> { $0.eventId == id }
            )
            let row: Event?
            do {
                row = try context.fetch(descriptor).first
            } catch {
                logger.error(
                    "seat check failed: \(error.localizedDescription, privacy: .public)"
                )
                return tier().capReachedMessage()
            }
            guard let deviceID = row?.device?.id, seats.allowsActions(deviceID: deviceID) else {
                return tier().capReachedMessage()
            }
        }
        return nil
    }

    private func fail(_ token: WriteToken, _ error: Error) async {
        let zabbix = (error as? ZabbixError) ?? ZabbixError.fromTransport(error)
        await storeFailure(
            token,
            message: zabbix.localizedDescription,
            status: ZabbixError.status(from: zabbix)
        )
    }

    /// A seat refusal passes `status` nil. It is not a Zabbix error, and
    /// the notice plus the row are the outcome. The dashboard line stays
    /// as it was.
    private func storeFailure(
        _ token: WriteToken,
        message: String,
        status: RequestStatusManager.RequestStatus?
    ) async {
        if let status {
            await MainActor.run {
                RequestStatusManager.shared.updateStatus(.zabbix, status)
            }
        }
        let pending = pendingWrites
        let failure = WriteFailure(provider: .zabbix, message: message)
        let stored = await MainActor.run {
            pending.fail(token: token, failure: failure)
        }
        if stored {
            logger.error(
                "write failed token \(token.id.uuidString, privacy: .public): \(message, privacy: .public)"
            )
        }
    }

    private static func eventIDs(from data: Data) throws -> [String] {
        let object = try zabbixJSONObject(from: data)
        guard object["error"] == nil, object["result"] != nil else {
            throw ZabbixError.fromRPC(object)
        }
        guard let result = object["result"] as? [String: Any] else { return [] }
        guard let raw = result["eventids"] as? [Any] else { return [] }
        return raw.compactMap { item in
            switch item {
            case let text as String:
                return text
            case let number as NSNumber:
                return number.stringValue
            default:
                return nil
            }
        }
    }
}

private struct ZabbixWriteServiceKey: EnvironmentKey {
    static let defaultValue: ZabbixWriteService? = nil
}

extension EnvironmentValues {
    var zabbixWriteService: ZabbixWriteService? {
        get { self[ZabbixWriteServiceKey.self] }
        set { self[ZabbixWriteServiceKey.self] = newValue }
    }
}
