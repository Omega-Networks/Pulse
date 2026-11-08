//
//  EntitlementStore.swift
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
import Observation
import os
#if canImport(StoreKit)
import StoreKit
#endif
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// StoreKit 2 entitlements. Listener starts at launch, before UI.
/// The tier is what `Transaction.currentEntitlements` says and nothing
/// else; StoreKit answers offline from the device's transaction cache.
/// Until the first refresh publishes, the tier is Free and writes fail
/// closed.
@MainActor
@Observable
final class EntitlementStore: Sendable {
    private(set) var tier: SubscriptionTier
    /// Monthly vs annual of the active product. Nil on Free.
    private(set) var billingPeriod: BillingPeriod? = nil
    /// Next renewal or period end from StoreKit. Nil on Free.
    private(set) var periodEnd: Date? = nil
    /// Lower (or other) tier Apple will apply at `periodEnd`. Nil if no change queued.
    private(set) var pendingTier: SubscriptionTier? = nil
    /// From the renewal info. Nil when StoreKit could not be asked.
    private(set) var willAutoRenew: Bool? = nil
    /// Set in tests. When non-nil, StoreKit is not consulted.
    private let previewTier: SubscriptionTier?
    /// `currentTier` is read off the main actor by the sync engine and
    /// Zabbix writes. The lock covers that read and the write in
    /// `publish`. It is not held across a StoreKit call.
    private nonisolated let tierLock: OSAllocatedUnfairLock<SubscriptionTier>
    /// Each `refresh` takes the next number. Only the latest publishes,
    /// so a slow refresh cannot overwrite a newer answer.
    @ObservationIgnored private var refreshGeneration = 0
    private let logger = Logger(subsystem: "pulse", category: "billing")

    init(previewTier: SubscriptionTier? = nil) {
        let start = previewTier ?? .free
        self.previewTier = previewTier
        self.tier = start
        self.tierLock = OSAllocatedUnfairLock(initialState: start)
    }

    /// The tier for a write gate that runs off the main actor.
    nonisolated var currentTier: SubscriptionTier {
        tierLock.withLock { $0 }
    }

    var periodCaption: String? {
        PeriodCaption.text(
            tier: tier,
            periodEnd: periodEnd,
            pending: pendingTier,
            willAutoRenew: willAutoRenew
        )
    }

    func isCurrent(tier: SubscriptionTier, annual: Bool) -> Bool {
        self.tier == tier && billingPeriod == (annual ? .annual : .monthly)
    }

    func isOtherPeriod(of tier: SubscriptionTier, annual: Bool) -> Bool {
        self.tier == tier && billingPeriod != nil && !isCurrent(tier: tier, annual: annual)
    }

    /// Call from `PulseApp.init` so updates run before first paint.
    func startAtLaunch() {
        if previewTier != nil { return }
        Task { await self.refresh() }
        Task { await self.finishUnfinished() }
        Task { await self.listenUpdates() }
        Task { await self.listenSubscriptionStatus() }
        Task { await self.listenActivation() }
    }

    func finishUnfinished() async {
        #if canImport(StoreKit)
        for await result in Transaction.unfinished {
            await handle(result)
        }
        #endif
    }

    func listenUpdates() async {
        #if canImport(StoreKit)
        for await result in Transaction.updates {
            await handle(result)
        }
        #endif
    }

    func listenSubscriptionStatus() async {
        #if canImport(StoreKit)
        for await _ in Product.SubscriptionInfo.Status.updates {
            await refresh()
        }
        #endif
    }

    /// StoreKit Testing and the macOS subscriptions page change the
    /// plan while Pulse is in the background. Refresh on become-active
    /// so an upgrade is not stuck until the next cold start.
    func listenActivation() async {
        #if os(macOS)
        let name = NSApplication.didBecomeActiveNotification
        #elseif os(iOS)
        let name = UIApplication.didBecomeActiveNotification
        #else
        return
        #endif
        for await _ in NotificationCenter.default.notifications(named: name) {
            await refresh()
        }
    }

    func refresh() async {
        if previewTier != nil { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        #if canImport(StoreKit)
        var entitled = SubscriptionTier.free
        var entitledPeriod: BillingPeriod?
        var bestProductID: String?
        var bestExpiration: Date?
        var environment = "none"
        for await result in Transaction.currentEntitlements {
            guard let next = Self.tier(from: result),
                  let productID = Self.productID(from: result),
                  let period = SubscriptionTier.period(from: productID),
                  case .verified(let transaction) = result else {
                continue
            }
            if next.rank >= entitled.rank {
                entitled = next
                entitledPeriod = period
                bestProductID = productID
                bestExpiration = transaction.expirationDate
                environment = transaction.environment.rawValue.lowercased()
            }
        }
        var autoRenew: SubscriptionTier?
        var autoRenewPeriod: BillingPeriod?
        var renews: Bool?
        var end = bestExpiration
        if let bestProductID,
           let product = try? await Product.products(for: [bestProductID]).first,
           let statuses = try? await product.subscription?.status {
            for status in statuses {
                guard case .verified(let info) = status.renewalInfo else { continue }
                renews = info.willAutoRenew
                if let nextID = info.autoRenewPreference {
                    autoRenew = SubscriptionTier.from(productID: nextID)
                    autoRenewPeriod = SubscriptionTier.period(from: nextID)
                }
                if let date = info.renewalDate {
                    end = date
                }
            }
        }
        let resolved = EntitlementResolution.resolve(
            entitled: entitled,
            entitledPeriod: entitledPeriod,
            autoRenew: autoRenew,
            autoRenewPeriod: autoRenewPeriod
        )
        let paid = resolved.tier != .free
        publish(
            generation: generation,
            tier: resolved.tier,
            period: resolved.period,
            periodEnd: paid ? end : nil,
            pending: resolved.pending,
            willAutoRenew: paid ? renews : nil,
            environment: environment
        )
        #else
        publish(
            generation: generation,
            tier: .free,
            period: nil,
            periodEnd: nil,
            pending: nil,
            willAutoRenew: nil,
            environment: "none"
        )
        #endif
    }

    private func publish(
        generation: Int,
        tier: SubscriptionTier,
        period: BillingPeriod?,
        periodEnd: Date?,
        pending: SubscriptionTier?,
        willAutoRenew: Bool?,
        environment: String
    ) {
        guard generation == refreshGeneration else { return }
        tierLock.withLock { $0 = tier }
        self.periodEnd = periodEnd
        self.pendingTier = pending
        self.willAutoRenew = willAutoRenew
        self.billingPeriod = period
        self.tier = tier
        logger.notice("Entitlement \(tier.rawValue, privacy: .public) from \(environment, privacy: .public)")
    }

    func restore() async {
        #if canImport(StoreKit)
        do {
            try await AppStore.sync()
            OperatorNoticeCenter.shared.clear(id: OperatorNotice.billingRestoreID)
        } catch StoreKitError.userCancelled {
            // The operator closed the sign-in. Not a failure.
        } catch {
            report(error, action: "Restore Purchases", noticeID: OperatorNotice.billingRestoreID)
        }
        #endif
        await refresh()
    }

    /// Opens Apple's subscription sheet. Apps cannot cancel a sub themselves.
    func openManageSubscriptions() async {
        #if canImport(StoreKit)
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        if let scene {
            do {
                try await AppStore.showManageSubscriptions(in: scene)
                OperatorNoticeCenter.shared.clear(id: OperatorNotice.billingManageID)
            } catch StoreKitError.userCancelled {
                // The operator closed Apple's sheet. Not a failure.
            } catch {
                report(error, action: "Manage Subscription", noticeID: OperatorNotice.billingManageID)
            }
        } else {
            logger.error("Manage Subscriptions had no window")
            post(OperatorNotice.billingManageID, "Subscriptions could not be opened.", severity: .failure)
        }
        #elseif os(macOS)
        let opened = URL(string: "https://apps.apple.com/account/subscriptions")
            .map { NSWorkspace.shared.open($0) } ?? false
        if opened {
            OperatorNoticeCenter.shared.clear(id: OperatorNotice.billingManageID)
        } else {
            logger.error("Manage Subscriptions could not be opened")
            post(OperatorNotice.billingManageID, "Subscriptions could not be opened.", severity: .failure)
        }
        #endif
        #endif
        await refresh()
    }

    #if canImport(StoreKit)
    /// Records what the paywall's `PurchaseAction` returned. True when
    /// the plan was bought. A pending purchase (Ask to Buy, bank
    /// approval) lands later through `Transaction.updates`.
    func completePurchase(_ result: Product.PurchaseResult) async -> Bool {
        switch result {
        case .success(let verification):
            guard case .verified = verification else {
                // Leave it in Transaction.unfinished. The paywall must
                // not close as if the plan were bought.
                logger.error("Purchase could not be verified")
                post(
                    OperatorNotice.billingPurchaseID,
                    "The purchase could not be verified. Pulse will try again the next time it opens.",
                    severity: .failure
                )
                return false
            }
            await handle(verification)
            return true
        case .pending:
            post(
                OperatorNotice.billingPurchaseID,
                "The purchase is waiting for approval. The plan changes when it is approved.",
                severity: .warning
            )
            return false
        case .userCancelled:
            return false
        @unknown default:
            logger.error("Purchase returned an unknown result")
            post(OperatorNotice.billingPurchaseID, "The purchase did not complete.", severity: .failure)
            return false
        }
    }

    func purchaseFailed(_ error: any Error) {
        report(error, action: "Purchase", noticeID: OperatorNotice.billingPurchaseID)
    }

    private func post(_ id: String, _ message: String, severity: OperatorNotice.Severity) {
        OperatorNoticeCenter.shared.post(OperatorNotice(
            id: id,
            source: .billing,
            severity: severity,
            message: message,
            occurredAt: Date()
        ))
    }

    private func report(_ error: any Error, action: String, noticeID: String) {
        logger.error("\(action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        post(noticeID, "\(action) did not complete. \(error.localizedDescription)", severity: .failure)
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            await transaction.finish()
            OperatorNoticeCenter.shared.clear(id: OperatorNotice.billingPurchaseID)
        case .unverified:
            // Leave in Transaction.unfinished so the next cold start
            // can retry verification. Never grant, never consume.
            break
        }
        await refresh()
    }

    private static func productID(from result: VerificationResult<Transaction>) -> String? {
        guard case .verified(let transaction) = result else { return nil }
        if transaction.revocationDate != nil { return nil }
        // currentEntitlements keeps a subscription that is in Billing
        // Grace Period, so a past expirationDate here is not a lapse.
        // Billing retry outside grace is not in the sequence at all.
        if transaction.ownershipType == .familyShared {
            assertionFailure("Family Sharing is off on Pulse subscriptions")
            return nil
        }
        return transaction.productID
    }

    private static func tier(from result: VerificationResult<Transaction>) -> SubscriptionTier? {
        guard let productID = productID(from: result) else { return nil }
        return SubscriptionTier.from(productID: productID)
    }
    #endif
}
