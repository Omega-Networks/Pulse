# ADR 0003 — NetBox OpenAPI Sync

| | |
|---|---|
| **Status** | Accepted (P1) |
| **Date** | 2026-08-13 |
| **Decision owner** | Leon Cassidy |
| **Applies to** | `Pulse/NetBox/**`, `NetBoxAPI/**`, `Pulse/Models/SiteDataService.swift`, `Pulse/Models/SwiftData Models/Interface.swift`, boot + Sync Dashboard |

## Principle

**The NetBox schema is the contract; Pulse stops re-deriving it by hand.** Types are generated from a vendored, path-filtered OpenAPI document. List ingest reads only the fields Pulse stores. One actor owns sync. A type's delete pass runs only after a complete, clean fetch.

## Context

The previous read path was `APIRequest` + `NetboxResource` + hand-written `*Properties` decoders. It had silent page-abort on one bad record, a new-object insert bug, hardcoded instance filter IDs, two independent sync actors, and a fake-success site create (GET, not POST).

## Non-negotiables

1. **AOT generation.** `docs/netbox/openapi-filtered.yaml` is vendored. `NetBoxAPI` is never hand-edited. Regeneration is `Scripts/regenerate-netbox-client.sh` with `NETBOX_URL` / `NETBOX_TOKEN` from the environment. The script fails if the instance host survives into outputs. `servers` in the vendored document is `url: ''`.
2. **Single owner.** `NetBoxSyncEngine` is the only full-sync entry. Boot and Sync Dashboard call `fullSync()`. Overlapping callers join the in-flight pass. `lastNetBoxUpdate` is stamped only after every type applies.
3. **Ingest DTOs, not generated list types.** Generated `Tenant` / `Site` / `Rack` / `Device` / `Service` / `Interface` types require unused counts and nested `display_url` that lab JSON omits. `NetBoxRecord.*` decodes the stored fields only. A skipped element is logged with the missing key; `skipped > 0` blocks that type's delete pass.
4. **Filter configuration.** `NetBoxFilterConfiguration.default` holds today's exclude / static-role IDs. Fetch and delete share that object. A Settings control is later work; do not scatter new literals.
5. **No writes in P1.** Add Site is disabled with an honest message. Site create is P4.
6. **Delete All must not invalidate live `@Query` graphs.** See *Delete All and SwiftData* below.

## What ships when

| Phase | Ships |
|---|---|
| **P1 (this ADR)** | Generated GET client, boot + dashboard + on-demand site loads, ingest DTOs, delete gate, Add Site disabled, operator stub |
| **P2 (this amendment)** | Persisted `Interface` `@Model`, streaming ingest, `InterfaceVO` edges, drop `InterfaceCache` |
| **P3** | Changelog watermark, delta pass |
| **P4** | MACD writes, real Add Site, ETag |

## Structural enforcement

- Views never import `NetBoxAPI` or call the generated `Client`.
- SwiftData models do not cross actors; `NetBoxRecord` values do.
- Logger subsystem `netbox`. Operator errors go through `RequestStatusManager`.

## Transport (P1 amendment)

P1 list traffic uses `NetBoxLiveFetcher` (URLSession + typed `URLQueryItem` + offset pages). That is the ratified P1 transport: generated list types require fields the lab omits, so ingest goes through `NetBoxRecord` DTOs and the per-element decoder, not `Client`. `NetBoxClientFactory` and `NetBoxAuthMiddleware` stay in tree as the future generated-transport path (typed operations, P4 writes) and must not grow a second Token/Bearer implementation. Both the live fetcher and the middleware call the single `NetBoxAuthorization` / `NetBoxServerURL` rule (fail-closed empty token, `https` + host). Wiring the generated client as the runtime transport is a later, explicit change — not a silent dual stack.

## Interfaces (P2 amendment)

`Interface` is a SwiftData `@Model` with denormalized indexed `deviceId` and `siteId`. Optional reference ids (`connectedEndpointId`, `lagId`, `bridgeId`, `parentId`) are nil, never 0. `mtu` / `speed` are integers (the wire type).

Ingest streams `/api/dcim/interfaces/` page-by-page (`streamDecoded`, `maxPages` = 60_000). Each page upserts in a fresh `ModelContext` and is released. `fetchComplete` is true only after the last page returns cleanly. The delete pass uses the **union of accepted ids from every page**, not the last page. A mid-walk throw leaves already-upserted rows (idempotent) and does not delete or stamp.

Unresolved device or a device with no site is **out of scope**: logged, not stored, not counted as `skipped`. Only poisoned JSON increments `skipped` and gates delete. The interface list query sends `device_role_id__n` from `NetBoxFilterConfiguration`; there is no `manufacturer_id__n` on this endpoint, so manufacturer-excluded leftovers drop as out of scope.

The interface walk is a full-sync stage after services, on the launch progress bar and on Settings → Sync Data. P3 will replace the one-time full pull with changelog deltas. `lastNetBoxUpdate` stamps only after interfaces succeed.

Delete All includes `Interface`. Map pin colour reads stored severity fields on `Site` / `Device` (`refreshSeverityFromEvents` at event ingest and after boot sync) so `body` never walks `Event.rClock` after a wipe.

`InterfaceCache` and `.interfacesDidUpdate` are gone. Site open does not call `/api/dcim/interfaces/` — `SiteDataService.loadAllSiteData` is static devices + Zabbix items only. Consumers load `InterfaceVO` via an indexed `FetchDescriptor`. `SiteGraphView` and `LayoutManager` share `SiteTopologyEdges` (one local per-site fetch + undirected join). Duplicate cable rendering (once per end) is collapsed to a single edge — accepted visual change. Cables themselves are not a SwiftData type; that is a later revision.

`deleteStale` still full-table-scans the type (P1 pattern). Fine at the 12K lab if measured. At tens of millions of rows that scan is P2 debt; do not invent a new delete primitive here.

## Store QoS (P1 amendment)

`NetBoxStore` apply/delete runs inside `Task.detached(priority: .userInitiated)` with a context created on that task. SwiftData `fetch`/`save` on a Background queue while boot or Sync Dashboard waits at User-initiated is a priority inversion (Instruments hang risk at the delete-pass fetch). Do not apply on the engine actor's inherited executor.

## Verification

| Gate | Status |
|---|---|
| Gate 1 — lab count parity, skip+delete, network kill, Add Site disabled | In progress (lab) |
| Gate 2 — offline interfaces | Lab 2026-08-13: startup sync, offline site open, edge parity (minus accepted dedupe), Delete All signed off. Owner waived proxy capture, P1-store upgrade, Instruments, headless re-run. Cables deferred. |
| Gate 3 — changelog converge | Not yet |
| Gate 4 — write round-trips | Not yet |

## Delete All and SwiftData

Lab: Settings → Database → Delete All Data, with the map window still open, trapped in `Event.rClock.getter` (`BackingData.swift`: model instance invalidated). The log had already printed “All data deleted successfully.” Map pins and the toolbar event counter still walked `Device.events` / `@Query [Event]` and read persisted fields on tombstoned rows.

**P1 (as-built, `47684d2`):** wipe on a **side** `ModelContext` so the UI context merges a refetch; skip events whose `modelContext` is nil before touching `rClock` / `severity`. That is a tactical stop-crash. `modelContext != nil` is not a documented validity API. A side-context save can still invalidate objects already registered on the main context; the guards are load-bearing.

**Do not treat this as the finished design.** Follow-ups, in order of how much they remove the class of bug:

1. **Delete All = replace the store** (preferred for a true wipe). Tear down the persistent store and hand SwiftUI a new `ModelContainer`. No tombstones, no relationship walks, watermark reset is free. Requires swapping the environment container while windows are open.
2. **Stop deriving UI from live `Event` models at render time.** EventCounter should snapshot `[(severity, count)]` on save. Site/device pin colour should be stored fields updated at event ingest (P3 already wants severity recompute). Then deleting events cannot crash `body`.
3. Keep the side-context wipe + `isStoreBacked` only until (1) or (2) ships.

Do not “fix” this by deleting Events later in the type list or by hoping `@Query` drops its array before the next render.

## Alternatives rejected

- **Build plugin.** Hand-maintained pbxproj; generation must be reviewable in git.
- **Keep `*Properties`.** They re-derived the schema and failed closed on unused fields.
- **Tag-filtered spec.** NetBox 4.6 collapsed tags; filter by operation IDs.

## Revision history

- 2026-08-13 — P1 accepted. Ingest-DTO lesson recorded after generated types skipped lab tenants, sites, racks, devices, and services.
- 2026-08-13 — Delete All / SwiftData invalidation: P1 stop-crash recorded; store-replace and severity-as-data named as the real design.
- 2026-08-13 — Transport: `NetBoxLiveFetcher` ratified for P1; factory/middleware retained for the generated path; one `NetBoxAuthorization` rule. Store apply hops to user-initiated QoS.
- 2026-08-13 — P2: persisted `Interface`, streaming ingest, out-of-scope vs skipped, VO edges, cache deleted. Gate 2 still lab.
- 2026-08-13 — P2 lab: owner signed startup/offline/edges/Delete All. Site-open interface HTTP already removed. Cables into SwiftData deferred.
