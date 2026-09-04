# ADR 0002 - Billing & Distribution for Pulse

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-06-04 |
| **Decision owner** | Leon Cassidy |
| **Applies to** | Pulse's App Store presence, StoreKit 2 integration, paywall surface, device-cap enforcement, subscription tier definitions, export compliance posture. Cross-references ADR 0001 for the security model that billing must not compromise. |

## Revision history

| Round | What changed | Driver |
|---|---|---|
| Initial (2026-06-04) | Acceptance - three-tier subscription, App Store distribution via dual-licence posture, structural cap enforcement, intro offer on Pro monthly, no Family Sharing, subscription-lapse degrade-don't-delete | Research synthesis (five-angle deep-research pass, June 2026) |
| Seats amendment (2026-08-17) | Cap table, insert-path enforcement, lapse ranking, intro product, and grant durability superseded as enumerated below. | Owner ratification after RolePresentation count and full-instance sync |
| Pricing (2026-08-19) | Plus renamed Growth. Caps Free 50 / Growth 250 / Pro 1,500 / Unlimited none. List prices NZD 14.99 / 24.99 / 49.99 monthly; annual is 10 × monthly (two months free). | Owner ratification |
| Upgrade timing (2026-08-19) | A higher-rank auto-renew product is the live tier immediately. A lower-rank change stays pending until period end. | StoreKit Testing / App Store leave upgrades on `autoRenewPreference` until the next transaction |
| App Store encryption plist (2026-09-04) | `ITSAppUsesNonExemptEncryption` is **NO**. App Store Connect’s encryption questionnaire (standard algorithms, not France) requires no documentation upload; the plist must match or uploads fail with 90592. SSH/TLS/AES still exist; this flag means exempt from Apple-side docs, not “no crypto.” | App Store Connect App Encryption Documentation |

## Principle

**Governance is code, applied to billing.** The same structural-enforcement discipline that landed ADR 0001 applies here. Caps are not soft suggestions enforced by UI - the data model refuses inserts past the limit. Compliance choices are not runtime flags - `ITSAppUsesNonExemptEncryption` is set in the bundle. Family Sharing is not handled in code by exception - it is disabled at the App Store Connect tier and the `.familyShared` ownership type is unreachable.

Pulse's billing has to defend three properties:

1. **The free tier is honest.** 15 devices is the limit. The App Store listing says so. The data layer enforces it. No soft warnings, no "you can go over a bit," no creep over time.
2. **The paid tiers are not security tiers.** Every capability from ADR 0001 - hardware-attested credentials, session recording, audit trail, host certificate machinery - is available on every tier including free. The only variable is device count. A free-tier credential and a paid-tier credential are cryptographically identical.
3. **Forks are first-class.** AGPL source on GitHub; the App Store binary is a proprietary licence Omega grants itself as sole copyright holder via the Contributor License Agreement's §2 sublicensing grant. Community forks build their own App Store presence or distribute outside it. Neither path is privileged in the architecture.

## Context

Pulse is local-first, operator-controlled, and is the operator's console for infrastructure work - SSH access, web companion, live monitoring, network topology, NetBox inventory, PowerSense grid telemetry. The functional category is "integrated operator console" - closer to enterprise tools (Forescout, Auvik, Datadog Network Monitoring) than to single-purpose SSH clients (Termius, Prompt 3). Consumer-prosumer pricing for an enterprise-functional category is the deliberate positioning: broad operator adoption rather than enterprise revenue extraction.

Three constraints shape the billing decision:

1. **Apple App Store distribution is the primary channel** - for reach to individual operators, homelabbers, and prosumer markets that wouldn't engage with a direct-download enterprise tool.
2. **Pulse's source is AGPL-3.0.** Binary distribution on the App Store requires dual-licensing. This is enabled by Omega being the sole pre-CLA copyright holder and the CLA's §2 grant for post-CLA contributions ("the right to license your Contribution under any license, including AGPL-3.0 (or later) or commercial licenses").
3. **Enterprise is a separate product** - role-based, multi-user, multi-hub, license-key activation via Omega's own backend. Deferred from this ADR; tracked separately.

Within those constraints, the billing model must work at consumer-prosumer subscription rates through Apple's StoreKit 2, with conversion economics that survive RevenueCat's 2026 benchmarks (median 2.1% freemium → 10.7% hard-paywall Day-35 conversion).

## Non-negotiables

### 1. Three subscription tiers, device-count-gated only

| Tier | Device cap | Monthly | Annual | Intro offer | Family Sharing |
|---|---|---|---|---|---|
| **Free** | 15 | $0 | $0 | - | - |
| **Pro** | 100 | $9.99 | $99.00 | $2.49/mo × 3 months on monthly | Off |
| **Unlimited** | No cap | $24.99 | $249.00 | None | Off |

All three tiers have identical feature surfaces. The only variable is `maxDevices`, sourced from a static lookup against `SubscriptionTier`. There is no other billing-driven feature variation in v1 and there will not be in v2.

The Unlimited tier exists as a **bridge for adopters with > 100 devices who need Pulse before Enterprise ships**. It is not a long-term consumer-ceiling product. When Enterprise launches via direct sales, Unlimited may sunset (with operator grandfathering - see §Operational consequences) or be retained at Omega's discretion based on adoption data.

Prices are USD base values. Apple's pricing tier system auto-renders local equivalents in each storefront; for NZ, USD $9.99/month resolves to approximately NZ$16.99/month after Apple's 15% GST inclusion and FX-rounding.

### 2. Caps are enforced at the data layer, not the UI layer

`Device.init` (or the equivalent NetBox sync insert path in `ProviderModelActor`) checks the current entitlement before insert. If the device count would exceed the tier cap, the insert throws `BillingError.tierCapReached`. There is no alternate insert path.

NetBox auto-sync hits the same insert path as manual add. When the cap is reached during sync, the sync stops with a user-facing message - no partial sync, no silent device dropping. Message text (canonical):

> *Free tier limit reached (15 devices). Upgrade to Pro to sync up to 100 devices, or remove a device to make room.*

The cap is **structural, not configurable**. It cannot be bypassed by:

- Build configuration flags (the check runs in Debug and Release identically)
- Runtime feature flags (none exist for billing)
- Alternative insert paths (every device insert routes through `Device.init`)
- The sync source (manual add and NetBox auto-sync both hit the same check)

### 3. Family Sharing is disabled

In App Store Connect, the Family Sharing toggle on every Pulse subscription product is **OFF**. `Transaction.ownershipType == .familyShared` will never appear in practice. The code path includes a defensive `assertionFailure` if it ever does - that's a configuration drift indicator, not a feature to handle.

Rationale: Pulse is a professional tool. Each operator has their own infrastructure context. Family Sharing would let a single subscriber's family use Pulse at no marginal cost, which is not the intent of the model. The decision is reversible later if data shows genuine demand (it won't - this is operator software, not media).

### 4. Annual default, monthly secondary

The paywall renders annual first and larger, with the per-month equivalent and a "Save 17%" subtitle. Monthly is the secondary option. Standard SwiftUI `SubscriptionStoreView` plus explicit display ordering.

Annual default optimises for Y1 revenue per converter. RevenueCat's 2026 data shows ~35% of annual subscribers cancel auto-renew in Month 1; that's expected and not a reason to default to monthly. Combined with App Store Small Business Program enrolment (15% commission), the unit economics favour annual capture.

### 5. One introductory offer per Apple ID per subscription group, lifetime

The Pro **monthly** subscription has a single introductory offer: **$2.49/month for 3 months**, then $9.99/month rolling. Pay-as-you-go payment mode, three billing cycles, configured in App Store Connect.

Eligibility is checked via `Product.SubscriptionInfo.isEligibleForIntroOffer(for: groupID)` before displaying the offer on the paywall. Apple enforces eligibility at the *subscription group* level per Apple ID, lifetime - taking the intro on Pro burns the intro for the whole group, so a user who later upgrades to Unlimited will not get a second intro.

The Pro annual subscription and both Unlimited subscriptions do not have intro offers in v1. Operators committing to annual or Unlimited are by definition more committed and do not need the intro to convert.

Three months is calibrated for Pulse's evaluation horizon: operators need 2–3 sprint cycles to sync NetBox, configure credentials, validate Pulse against real infrastructure, and decide. A 3-day or 7-day trial wouldn't clear the validation runway; 3 months at $2.49/month does, while still validating payment details up front.

### 6. No feature gating across tiers

ADR 0001's structural capabilities - SE credentials, session recording, host trust polymorphism, audit logs, web companion - are available on every tier including Free. There is no `feature.requiresProTier(_:)` check anywhere in the code. The only billing-driven check in the entire codebase is `device.canBeInserted(currentTier:)`.

Any future feature-gating proposal must explicitly amend this ADR with a §amendment. Reviewers can grep `requiresProTier` and find zero results; that's the structural guarantee.

This commitment is load-bearing for the security model. Gating SE-backed credentials behind a paywall would mean the free tier is structurally less safe than the paid tier - that's not a position Pulse can defend, and it contradicts ADR 0001 §1.

### 7. The App Store listing is the contract

The App Store product page must clearly state the device caps and the prices. The free-tier limit, the Pro/Unlimited caps, monthly and annual prices in USD (Apple auto-renders local), and the auto-renewing nature of the subscriptions.

The in-app cap-reached message uses identical phrasing to the listing. Operators agreed to the contract when they downloaded; the in-app message reminds them of what they agreed to, not introduces a surprise.

**No surprise gating** - every cap that exists in code is documented on the listing. **No expanding gating** - caps cannot tighten over time without a new App Store version submission and an updated listing.

### 8. Subscription lapse degrades, doesn't delete

When a Pro or Unlimited subscription lapses (cancellation, billing failure, refund, intentional non-renewal), Pulse retains all credentials and data. The user reverts to free-tier behaviour:

- All credentials remain accessible
- All previously-synced devices remain in SwiftData
- The first 15 devices (sorted by `Device.lastActivityAt` descending, falling back to `createdAt` descending) remain *interactive* - SSH, web companion, recording all work
- Devices 16+ remain *visible but action-disabled* - they appear in the inventory but the actions menu items are greyed out with a "Subscribe to resume" affordance

This is a deliberate departure from the "hard refusal" pattern for new inserts. Existing data is preserved; only behavioural reach shrinks to the free-tier surface. Resubscribing restores full functionality immediately; no re-sync or re-configuration needed.

### 9. Export and IP compliance is bundle-level, not runtime

- `ITSAppUsesNonExemptEncryption = NO` in the generated Info.plist (`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption`). App Store Connect determined no encryption documentation upload; the flag skips the per-upload questionnaire. SSH, TLS, Secure Enclave, and session-log AES still ship. Annual BIS self-classification remains a US filing, not an Apple PDF.
- App Store Connect submission answers: "Does your app use encryption? **YES**. Does it qualify for any exemptions? **YES**" - citing 15 CFR §740.17(b)(1) License Exception ENC for standard cryptography (AES, ECDSA P-256, SHA-256, ECIES, SSH protocol algorithms; no proprietary or non-standard crypto).
- Annual BIS Self-Classification Report (ECCN 5D002, Authorization Type ENC, Item Type "network communications/infrastructure") filed by **Feb 1 each year** to `crypt-supp8@bis.doc.gov` and `enc@nsa.gov`. NON-U.S. Components and NON-U.S. Manufacturing Locations both = New Zealand.
- NZ NSGL: General Software Note carve-out documented in `docs/compliance/nzsgl-assessment.md` citing Wassenaar Cat 5 Part 2 Note 3 publicly-available-software exemption. No MFAT consent required.
- App Store Small Business Program enrolment **before** first paid sale. New developers with no prior App Store revenue qualify automatically and should enrol immediately.

### 10. Paywall complies with App Store Review Guideline 3.1.2 (2026 enforcement)

Required UX elements:

- Price and billing period visible on the paywall in ≥ 16pt type.
- Terms of Use AND Privacy Policy linked from *inside* the paywall, not only from the App Store listing.
- Restore Purchases button present and labelled.
- **No "free trial toggle" UI** - Apple began rejecting these in January 2026 as misleading.
- Intro-offer language uses the full price after the intro: *"$2.49 for the first 3 months, then $9.99/month."*

These are not aesthetic guidelines - they are review-blocking requirements in 2026 enforcement.

## Structural enforcements

The following invariants cannot be bypassed by configuration, runtime state, or build mode:

1. **`Device` insert refuses past cap.** `BillingError.tierCapReached` is thrown at exactly one site per insert pattern. Grep-checkable: `grep -rn "throw BillingError.tierCapReached" Pulse/` returns exactly the expected sites and no others.
2. **`SubscriptionTier.maxDevices` is hard-coded.** A static lookup against the enum; not in `Configuration`, not in remote config, not in App Store Connect (which sets prices, not caps).
3. **`ITSAppUsesNonExemptEncryption` lives in the generated Info.plist.** Set to `NO` so App Store Connect does not expect an export-compliance key (Connect: no documents required). Not a claim that Pulse uses no cryptography. The §740.17(b)(1) ENC route still carries the annual BIS self-classification report (see §9).
4. **No tier-gated feature checks.** `grep -rn "requiresProTier\|requiresUnlimited\|isPremium" Pulse/` returns empty. Adding any future check requires amending this ADR.
5. **Active tier sourced from `Transaction.currentEntitlements`.** Single resolver, single source of truth. No manual override, no debug bypass in Release builds.
6. **Family Sharing unreachable.** The `.familyShared` case in `Transaction.ownershipType` is handled with a defensive `assertionFailure` only; no real code path consumes it.
7. **Paywall and listing language are identical.** The cap-reached message and the App Store description use the same wording. Drift between them is a release-blocker.

## What ships when

### v1 (this ADR)

- Three tiers (Free, Pro, Unlimited) in one App Store Connect subscription group
- StoreKit 2 integration with `Transaction.updates` listener + `Transaction.unfinished` reconciliation at cold start
- Paywall using `SubscriptionStoreView` plus explicit annual-default ordering, compliant with Guideline 3.1.2
- Hard cap at `Device.init`
- Family Sharing disabled at App Store Connect
- $2.49 × 3-month intro on Pro monthly only
- SBP enrolled pre-launch
- BIS annual CSV filed
- NZ NSGL assessment in repo

### v2 - Enterprise (deferred from this ADR)

- Distributed direct from omeganetworks.nz, not the App Store
- License-key activation via Omega's own backend
- Multi-user organisation accounts
- Per-role pricing (router/switch/camera differentials)
- Multi-hub licensing
- SAML SSO, audit log forwarding to operator-controlled SIEM
- Custom contracts and invoicing

When Enterprise ships, the Unlimited App Store tier's future is re-evaluated. Default expectation: Unlimited sunsets with a minimum 12-month grandfather window for existing operators; new Unlimited subscriptions close at the announcement date.

### Out of scope for v1

- **Volume discounts on App Store tiers.** No good mechanism for individual subscriptions.
- **Per-region pricing overrides.** Apple's automatic tier translation handles NZ, AU, GB, EU, etc.
- **In-app consumable purchases.** Pulse uses only auto-renewable subscriptions.
- **Server-side receipt validation.** Per ADR 0001, Pulse is local-first. StoreKit 2's `Transaction.verifyResult` client-side cryptographic verification using Apple's published certificate chain is sufficient and is what Apple recommends for offline-tolerant apps.
- **Telemetry tracking user behaviour for pricing optimisation.** Pulse does not phone home. Aggregate App Store Connect analytics are sufficient.
- **Promotional offers and win-back offers.** Reserved for post-launch experimentation, not v1.

## Operational consequences

- **SBP timing.** Apply for App Store Small Business Program *before* first paid sale. Rate applies 15 days after the fiscal-month-end of approval. Do not ship pre-SBP unless willing to pay 30% on the first weeks of sales.
- **BIS filing cadence.** Diary February 1 every year for the prior calendar year's exports. The report is one CSV emailed to two BIS addresses.
- **NZ NSGL.** One-page internal assessment lives at `docs/compliance/nzsgl-assessment.md`. Reviewed annually alongside the BIS filing. No MFAT consent required for App Store distribution under the General Software Note.
- **Bundle ID and Team ID coupling.** Per ADR 0001 §1, changing either invalidates SE credentials AND constitutes a new App Store product. Pulse cannot rename the bundle ID without (a) a new app listing and (b) a credential re-enrolment for every existing operator. Bundle ID changes are governance events, not routine.
- **Subscription lapse retains data.** Operators can resubscribe and pick up where they left off. Data is never destroyed at lapse. The degrade-but-preserve model is structural.
- **Intro offer consumption is permanent.** One intro per Apple ID per subscription group, lifetime. Cannot be reset without Apple's intervention.
- **Refunds are Apple's responsibility.** Pulse does not have a refund process. Apple's flow is the only mechanism; Omega does not process refunds directly.
- **Unlimited tier is temporary.** Operators on Unlimited at sunset get a grandfather period (minimum 12 months from announcement). Final terms decided at Enterprise launch.
- **Paywall and listing drift is a release blocker.** Changes to in-app cap-reached language must be matched by App Store listing updates in the same release.

## Verification

| # | Test | Pass criterion |
|---|---|---|
| 1 | App Store Connect configuration | Four subscription products in one group: Pro Monthly, Pro Annual, Unlimited Monthly, Unlimited Annual. Family Sharing OFF on all four. Intro offer configured on Pro Monthly only: $2.49 × 3 months, pay-as-you-go. |
| 2 | Generated Info.plist | `ITSAppUsesNonExemptEncryption = NO` (Connect: no documentation upload). |
| 3 | Cap enforcement | `Device.init` throws `BillingError.tierCapReached` when count == cap. Unit test in `PulseTests/Billing/` verifies for each tier. |
| 4 | No feature gating | `grep -rn "requiresProTier\|requiresUnlimited\|isPremium" Pulse/` returns empty. |
| 5 | Single tier resolver | All tier reads route through one resolver fed by `Transaction.currentEntitlements`. Grep confirms. |
| 6 | Family Sharing unreachable | `grep -rn "familyShared" Pulse/` returns only the defensive `assertionFailure` site in the transaction listener. |
| 7 | Paywall compliance | `SubscriptionStoreView` renders TOS + Privacy Policy links inside the paywall, Restore Purchases button visible, price and period visible, no free-trial-toggle UI. Manual lab review against Guideline 3.1.2. |
| 8 | Listing matches in-app | App Store listing device caps and prices match in-app cap-reached language verbatim. Diff review pre-submission. |
| 9 | SBP enrolment | App Store Connect shows program acceptance and 15% commission rate applied to all Pulse subscription proceeds. |
| 10 | BIS filing archived | `docs/compliance/bis-filings/<year>.csv` exists; copy of submission email retained. |
| 11 | NZ NSGL assessment | `docs/compliance/nzsgl-assessment.md` exists; reviewed annually. |
| 12 | Lapse behaviour | Lab procedure: cancel subscription, confirm first 15 devices (by last-activity desc) remain interactive, devices 16+ are visible but action-disabled, no data destroyed. |
| 13 | Intro eligibility check | Paywall calls `Product.SubscriptionInfo.isEligibleForIntroOffer(for:)` and hides the offer when ineligible. Unit test or manual repro with Apple's sandbox eligible/ineligible test accounts. |
| 14 | Offline verification | Receipt verification works without network access. `Transaction.verifyResult` returns `.verified` against Apple's bundled public-key chain. |
| 15 | NZ pricing renders | App Store Connect preview shows ~NZ$16.99/mo for Pro Monthly, ~NZ$169/yr for Pro Annual, etc. Apple's auto-rendering, not manual override. |

## Alternatives considered

- **Permissive licence (Apache 2.0 instead of AGPL).** Rejected. AGPL's network-use protection prevents vendor enclosure of Pulse's network-facing features. Dual-licensing via CLA preserves AGPL for the community fork while permitting App Store distribution. Permissive licensing would give up the protection without gaining anything not already available via dual-licensing.
- **Distribute outside the App Store via Developer ID.** Rejected. App Store reach is the primary asset for individual-operator adoption; the sovereignty gain from direct distribution is marginal at consumer-prosumer scale. Enterprise will distribute direct anyway, so the sovereignty story is preserved.
- **Server-side receipt validation.** Rejected per ADR 0001. Pulse is local-first; introducing a billing backend for receipt checks contradicts the architectural principle. StoreKit 2's client-side cryptographic verification is sufficient and Apple-recommended.
- **Hard quotas per organisation (centralised).** Rejected for App Store distribution; org-level quotas aren't appropriate for individual Apple ID subscriptions. Deferred to Enterprise where they make sense.
- **Free tier > 15 devices.** Considered. Higher free caps are more generous but materially hurt freemium → paid conversion (RevenueCat 2026: 2.1% freemium vs 10.7% hard-paywall Day-35 - a 5× delta). The 15-device cap triggers immediately for any real NetBox sync, functioning as a hard paywall. The free tier is for evaluation and small homelabs, not full deployments.
- **Per-feature pricing.** Rejected per ADR 0001. Security features cannot be tier-gated without compromising the safety model.
- **No introductory offer.** Rejected. Pulse requires 2–3 sprint cycles of real-infrastructure use before operators can validate its value. The intro offer gives them that runway.
- **Free trial (zero cost) instead of paid intro offer.** Rejected. RevenueCat data shows paid intro offers outperform free trials in many cohorts; charging $2.49 filters tire-kickers and validates payment details up front.
- **Subscription model only, no Unlimited tier.** Rejected - operators with > 100 devices need an option *now*, before Enterprise ships. Unlimited is the bridge.
- **Lifetime / perpetual licence instead of subscription.** Rejected. App Store doesn't support non-consumable IAPs as primary monetisation for tools needing ongoing maintenance, and one-time pricing doesn't fund the multi-year roadmap. Subscription is the correct model.
- **Stable cross-bundle access group (per the ADR 0001 Option A discussion).** Rejected. Bundle-coupled access group is the choice per ADR 0001 §1; billing inherits that posture. Forks re-enrol; this is correct.
- **Same intro offer on Pro Annual.** Rejected for v1. Annual subscribers self-select as committed; the intro is for risk-mitigating monthly converters.

## Cross-references

- [ADR 0001 - SSH Terminal & In-App Web: Architectural Foundations](./0001-ssh-terminal-and-web-foundations.md) - security model that this ADR must not compromise
- [Pulse Credentials Guide](../credentials.md) - operator-facing credentials documentation
- Billing research synthesis (June 2026, local working file) - five-angle research pass that informed this ADR's evidence base

## Seats amendment (2026-08-17)

This section **supersedes** the listed clauses. The rest of this ADR stands (Family Sharing off, no feature gating, listing = in-app, degrade-don’t-delete, export compliance, Guideline 3.1.2, StoreKit 2, no RevenueCat).

### What the code will do

Billable count is derived from RolePresentation (`countsTowardLicense`: graph, list, or named-in-rack). Hardware does not count. NetBox sync always stores. Actions (not the view, not the Zabbix **feed**) require an **effective seat**. Zabbix ingest continues; `event.acknowledge` and NetBox writes do not, except as gated below.

`Device.seatGrantedAt` is the only grant record (no second store). **Effective seated** = eligible **and** `seatGrantedAt` among the oldest `cap` grants **of currently eligible devices**. A stale grant on a now-hardware device cannot shadow a slot.

Grants are derived, reconstructible state. Durable facts: StoreKit entitlement (cap) and NetBox `created`, then `id`. While a row survives, shrink keeps timestamps and uses the oldest `cap` grants; upgrade/restore re-enables those surviving grants, then fills by `created`, `id`. A mirror rebuild (Full Resync, Delete All, NetBox delete+recreate) re-seats by `created`, `id`. Reconciling twice from identical inputs seats an identical set.

Link-level cable actions require **both** termination devices seated. Bulk acknowledge/update and bulk NetBox edit gate at **selection** (unseated rows not selectable). Single-object actions gate on the owning device. Rack hardware (`treatAsFiller` / not `countsTowardLicense`) has no seat and does not need one to place, unrack, or flip.

Eligibility-adding changes **in Pulse** at cap are refused. The same change via NetBox sync always lands, unseated. Hiding a role is not a paid-features dodge: hidden ⇒ unseated ⇒ read-only.

`Transaction.updates` starts at launch before UI. `Transaction.unfinished` reconciles at cold start. Billing Grace Period is enabled in App Store Connect; entitlement persists through retry. `Transaction.revocationDate` is lapse, effective immediately. A **higher-rank** `autoRenewPreference` is the live cap immediately (Apple prorates upgrades; StoreKit Testing often flips preference before `currentEntitlements`). A **lower-rank** change stays pending until period end. Refresh also runs on become-active and `Product.SubscriptionInfo.Status.updates`.

### Clauses this amendment supersedes

| Was | Now |
|---|---|
| **§1** Free 15 / Pro 100 / Unlimited. Prices in the ADR table. | Free **50**, **Growth 250**, Pro **1,500**, Unlimited none. List prices in App Store Connect (NZD 14.99 / 24.99 / 49.99 monthly; annual = 10 × monthly). |
| **§Structural-enforcement 1** `BillingError.tierCapReached` at `Device.init`. Grep that throw. | **Retired.** Sync and `Device.init` never refuse for cap. Grep `isSeated` / `allowsActions(deviceID:)`. |
| **§2 / §6** Single billing check `device.canBeInserted(currentTier:)`. Cap abort during NetBox sync. | `allowsActions(deviceID:)` (and create/eligibility Pulse paths). `requiresProTier` grep stays empty. Sync never aborts on cap. |
| **§8 lapse ranking** First 15 by `lastActivityAt` desc, then `createdAt`. | Oldest `seatGrantedAt` among **currently eligible** devices, count = cap. Refill by `created`, `id`. |
| **§5 intro** Pro monthly $2.49 × 3. | **Growth monthly**, optional at product-create. Still one intro per Apple ID per group, lifetime. |
| **Verification 1–3, 12** Four products; cap at `Device.init`; lapse 15 by last-activity. | Six paid products (Growth/Pro/Unlimited × monthly/annual). Cap tests are seat/action tests. Lapse test is oldest-grant effective set + grace + revocation. |
