# ADR 0003 - NetBox OpenAPI Sync

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
2. **Single owner.** `NetBoxSyncEngine` is the only full-sync entry. Boot and Apply changes call `sync()` (delta, or a full mirror when the watermark is missing, gone, or past the safety interval). Full Resync calls `fullSync()`. Overlapping user callers join the in-flight pass. `lastNetBoxUpdate` is stamped only after a full mirror finishes every type, or after a changelog page has fully applied. A page that fails is not stamped. An idle delta runs while the app is open and never starts a full mirror.
3. **Ingest DTOs, not generated list types.** Generated `Tenant` / `Site` / `Rack` / `Device` / `Service` / `Interface` types require unused counts and nested `display_url` that lab JSON omits. `NetBoxRecord.*` decodes the stored fields only. A skipped element is logged with the missing key; `skipped > 0` blocks that type's delete pass.
4. **Full instance, role presentation.** Sync stores every device, type, and role. Fetch and delete share that scope (the whole instance). Visibility, monitoring, and rack drawing are `RolePresentation` (Settings → Roles). The future billable-device count is derived from those surfaces (graph, list, or named-in-rack); it is not a user toggle. Do not put manufacturer or role excludes back on the pull.
5. **No writes in P1.** Add Site is disabled with an honest message. Site create is P4.
6. **Delete All must not invalidate live `@Query` graphs.** See *Delete All and SwiftData* below.

## What ships when

| Phase | Ships |
|---|---|
| **P1 (this ADR)** | Generated GET client, boot + dashboard + on-demand site loads, ingest DTOs, delete gate, Add Site disabled, operator stub |
| **P2 (this amendment)** | Persisted `Interface` `@Model`, streaming ingest, `InterfaceVO` edges, drop `InterfaceCache` |
| **P3 (this amendment)** | Changelog watermark, boot delta pass, weekly safety mirror |
| **P4 (this amendment)** | Interface/cable writes, gated device/site, last-write-wins |
| **P5 (accepted)** | In-memory write intents. The sheet returns when the ask is recorded. Cable proves the same lifecycle |

## Structural enforcement

- Views never import `NetBoxAPI` or call the generated `Client`.
- SwiftData models do not cross actors; `NetBoxRecord` values do.
- Logger subsystem `netbox`. Operator errors go through `RequestStatusManager`.

## Transport (P1 amendment)

P1 list traffic uses `NetBoxLiveFetcher` (URLSession + typed `URLQueryItem` + offset pages). That is the ratified P1 transport: generated list types require fields the lab omits, so ingest goes through `NetBoxRecord` DTOs and the per-element decoder, not `Client`. `NetBoxClientFactory` and `NetBoxAuthMiddleware` stay in tree as the future generated-transport path (typed operations, P4 writes) and must not grow a second Token/Bearer implementation. Both the live fetcher and the middleware call the single `NetBoxAuthorization` / `NetBoxServerURL` rule (fail-closed empty token, `https` + host). Wiring the generated client as the runtime transport is a later, explicit change - not a silent dual stack.

## Interfaces (P2 amendment)

`Interface` is a SwiftData `@Model` with denormalized indexed `deviceId` and `siteId`. Optional reference ids (`connectedEndpointId`, `lagId`, `bridgeId`, `parentId`) are nil, never 0. `mtu` / `speed` are integers (the wire type).

Ingest streams `/api/dcim/interfaces/` page-by-page (`streamDecoded`, `maxPages` = 60_000). Each page upserts in a fresh `ModelContext` and is released. `fetchComplete` is true only after the last page returns cleanly. The delete pass uses the **union of accepted ids from every page**, not the last page. A mid-walk throw leaves already-upserted rows (idempotent) and does not delete or stamp.

Unresolved device or a device with no site is **out of scope**: logged, not stored, not counted as `skipped`. Only poisoned JSON increments `skipped` and gates delete. The interface list is unfiltered by role or manufacturer; leftovers with no stored parent still drop as out of scope.

The interface walk is a full-sync stage after services, on the launch progress bar and on Settings → Sync Data. P3 will replace the one-time full pull with changelog deltas. `lastNetBoxUpdate` stamps only after interfaces succeed.

Delete All includes `Interface`. Map pin colour reads stored severity fields on `Site` / `Device` (`refreshSeverityFromEvents` at event ingest and after boot sync) so `body` never walks `Event.rClock` after a wipe.

`InterfaceCache` and `.interfacesDidUpdate` are gone. Site open does not call NetBox for interfaces, cables, racks, fillers, or bays - `SiteDataService.loadAllSiteData` is Zabbix items only. Consumers load `InterfaceVO` via an indexed `FetchDescriptor`. `SiteGraphView` and `LayoutManager` share `SiteTopologyEdges` (one local per-site fetch + undirected join on `connectedEndpointId`). Duplicate cable rendering (once per end) is collapsed to a single edge - accepted visual change. `Cable` rows persist tenant, length, colour, and the DELETE id; they do not own the graph join.

`deleteStale` still full-table-scans the type (P1 pattern). Fine at the 12K lab if measured. At tens of millions of rows that scan is P2 debt; do not invent a new delete primitive here.

## Store QoS (P1 amendment)

`NetBoxStore` apply/delete runs inside `Task.detached(priority: .userInitiated)` with a context created on that task. SwiftData `fetch`/`save` on a Background queue while boot or Sync Dashboard waits at User-initiated is a priority inversion (Instruments hang risk at the delete-pass fetch). Do not apply on the engine actor's inherited executor.

## Verification

| Gate | Status |
|---|---|
| Gate 1 - lab count parity, skip+delete, network kill, Add Site disabled | In progress (lab) |
| Gate 2 - offline interfaces | Lab 2026-08-13: startup sync, offline site open, edge parity (minus accepted dedupe), Delete All signed off. Owner waived proxy capture, P1-store upgrade, Instruments, headless re-run. Cables deferred. |
| Gate 3 - changelog converge | Deferred by owner (2026-08-17). Does not block further work on this branch. Lab matrix still required before a formal P3 merge to a parent. |
| Gate 4 - write round-trips | Lab 2026-08-13: interface enable/description (including clear) and cable create/delete signed. Disconnect confirms first. Owner deferred further cable UI. 412, validation-body, custom_fields changelog diff, and read-only token not signed. `If-Match` stays off. Remaining Gate 4 items deferred with Gate 3 (2026-08-17). |

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

- 2026-08-13 - P1 accepted. Ingest-DTO lesson recorded after generated types skipped lab tenants, sites, racks, devices, and services.
- 2026-08-13 - Delete All / SwiftData invalidation: P1 stop-crash recorded; store-replace and severity-as-data named as the real design.
- 2026-08-13 - Transport: `NetBoxLiveFetcher` ratified for P1; factory/middleware retained for the generated path; one `NetBoxAuthorization` rule. Store apply hops to user-initiated QoS.
- 2026-08-13 - P2: persisted `Interface`, streaming ingest, out-of-scope vs skipped, VO edges, cache deleted. Gate 2 still lab.
- 2026-08-13 - P2 lab: owner signed startup/offline/edges/Delete All. Site-open interface HTTP already removed. Cables into SwiftData deferred.
- 2026-08-13 - P3: `lastObjectChangeId`/`Time` are NetBox server values, advanced only after a fully applied delta. Boot uses delta when the watermark is present and retained; full mirror on empty store, missing watermark, 404 watermark, or weekly safety. Settings → Full Resync is always a mirror. Unknown `changed_object_type` is skipped. `dcim.cable` re-fetches both interface ends.
- 2026-08-13 - P4: hand-written write bodies (generated `PatchedWritable*Request` is not Encodable; client not regenerated). Interface PATCH (enabled/description) and cable POST/DELETE are live. Device/site methods exist and refuse. `If-Match` is off (weak ETag). Post-write re-fetch uses the delta-apply path. Add Site stays disabled and never POSTs.
- 2026-08-13 - P4 lab: description/enable/clear and cable connect/disconnect signed. Empty description sends `""`. Disconnect asks first. Successful writes post `netBoxStoreDidApply` so the open site graph reloads.
- 2026-08-14 - Cables and racks in SwiftData. `Cable` and `DeviceBay` `@Model`s; device port/bay counts; filler roles pulled with devices (even when manufacturer 5 is excluded) and hidden from the site graph; site-open filler HTTP and `StaticDeviceCache` / `DeviceBayCache` deleted. Cable tenant/length/colour/description persist; `bundleId` stored unused.
- 2026-08-14 - Sync no longer excludes manufacturer 5 or roles 29/30. Role presentation is the only filter. The future billable-device count is derived from graph / list / named-in-rack, not a License toggle. Full Resync required once.
- 2026-08-14 - `SiteLocation` and `RackRole` persist; New rack sends `location` and `role`. Rack drag uses the occupant snapshot under the pointer (not a detached preview from the window origin). Hover highlight is per face and clears when the mouse is released.
- 2026-10-09 - Writes do not page the changelog. A device create stores the 201 body; site, rack, and cable writes still re-read. While Pulse is open, the same delta runs every 120s and 2s after the last write. That pass never full-mirrors. Page-cap on the idle pass leaves the watermark; boot and Apply changes still fall back to a full mirror. `netBoxStoreDidApply` from the idle pass fires only when at least one object was applied.
- 2026-10-09 - A chained write keeps the engine until the chain drains, and the quiet delta waits with it. Idle stops before the next changelog page when a write or user sync is waiting, drops the pages it already fetched, and does not move the watermark. The idle loop still starts after a failed boot sync. That failed boot, a successful boot, Apply changes, and Full Resync seat the whole store off the main actor and skip rows whose grant is already right. Idle seats the device rows that pass applied. Under a cap it also fills an open slot from the oldest ungranted device. A front-port-only delta does not read the device table.
- 2026-10-13 - An idle changelog that passes the page cap is reported once on the NetBox status line. Later idle ticks do not re-download that window. Launch and Apply changes clear that latch; those paths still full-mirror when the cap is hit. The capped seat fill matches a missing device role without force-unwrapping it. A launch seat read does not mark a device unbilled when a grant arrived while that read was in flight.
- 2026-10-13 - Changelog pages apply and stamp one at a time. A delta seats the devices that page applied. A full mirror and a failed boot still seat the whole store. See *Changelog pages and seats*.
- 2026-10-13 - A 403 on a model other than sites or devices skips that model, keeps its stored rows, and lets the rest of the mirror finish. The idle loop does not ask again until launch or Apply changes. A 403 on the changelog list is latched and does not full-mirror. See *Permission gaps*.
- 2026-10-14 - Write intents proposed. An ask lives in memory until NetBox confirms it. A failed ask is not stored. One lab switch create measured the write wait at 0 ms and `computeEdges` at 674 ms. The write frame stays as it is. See *Write intents (P5 amendment)*.
- 2026-10-14 - Write intents accepted. Device create records the ask and returns the sheet before the POST. A failed ask stays on screen until Discard.
- 2026-10-14 - `computeEdges` reads a fresh `ModelContext` off the main actor and publishes `[Edge]`. The per-device walk stays. A superseded pass does not assign.
- 2026-10-14 - Cable create, interface to interface, uses the same ask. The pair sheet returns on submit. Retire runs one turn after the apply notification. The off-main edge pass can still leave a cable missing until `[Edge]` is assigned.
- 2026-10-15 - Lab remeasure of `timing computeEdges` after the off-main fetch. A device ask draws that role's symbol at the stored icon's size. A cable ask keeps the tether at the stored stroke's width until the pass assigns the cable, then the tether fades out and the stored stroke fades in.
- 2026-10-15 - A device ask also draws the picked model under the name, in the same stack as a stored device. `.position` anchors the centre, so a shorter ask moved the icon when the stored device replaced it. A node drag keeps the point under the pointer: the centre at the start of the drag, plus the pointer's translation in the diagram. The centre is not assigned the pointer's location.
- 2026-10-15 - Review fixes. An ask commits on NetBox's 201, and a later store failure is left to the quiet delta. A created cable is stored from its POST body without a GET. A failed sync no longer fails a write queued behind it. Edit keeps the failed ask until Create. The recorded graph point is removed, so toolbar devices are no longer pinned to the fallback point. The token-less `createDevice` is removed; tests use `submit`.
- 2026-10-15 - The pending layer is kept for now after review. *Why the pending layer is here, and what comes next* records its purpose, its limit, and the site-draft phase that replaces it.

## Changelog pages and seats

A delta reads `/api/core/object-changes/?id__gt=&ordering=id` one page at a time. That page is coalesced on its own (latest action per object, then foreign-key order), each object is re-fetched by id, and the page's highest change id is stamped before the next page is requested. Coalescing does not span pages. Unknown `changed_object_type` is skipped and still advances the high water when its id is ahead of the watermark. The watermark never moves backward.

A yield before the next page, or between objects, leaves earlier pages stamped and does not stamp the page that stopped. `skipped > 0` on a page throws and does not stamp or apply that page. Idle never full-mirrors. When the page cap is hit, idle reports it once and does not retry; pages already stamped stay applied. Launch and Apply changes clear that latch and, past the cap, full-mirror.

A delta boot and Apply changes seat with `grantArrivals` on the device ids that page applied. Under a cap an open slot still goes to the oldest ungranted eligible device. Unlimited seats only those ids. A full mirror (empty store, missing or gone watermark, weekly safety, page-cap fallback, Full Resync) and a failed boot seat the whole store with `grantMirroredStore` and skip rows whose stamp is already right. Tier and role changes still reconcile. `deleteStale` and the severity walk are unchanged.

## Permission gaps

A 401, a missing token, or a transport failure fails the sync and does not stamp a full success. A 403 on sites or devices does the same. A 403 on any other mirrored model skips that model, leaves the rows already stored (the `fetchComplete` delete does not run), and continues. When sites and devices succeeded, the watermark still stamps. The refused list path is remembered for the session. Idle does not request it again. The next launch or Apply changes clears that set and tries the model again.

A 403 while re-fetching one changelog object skips that object and does not delete the local row. The page's high water still stamps when it is ahead. The model's list path joins the same refused set.

A 403 on `/api/core/object-changes/` is reported once and latched. Idle does not re-download it and does not full-mirror. Launch and Apply changes clear the latch and try the changelog again.

Each refusal posts an `OperatorNotice` on `OperatorNoticeCenter` (in memory, replaced when the same id is posted again, cleared when that fetch later succeeds). Zabbix failures post there too, using the sentence already shown for that failure. The toolbar warning reads the list. A later event log is a view of the same list. Writes are unchanged: a 403 on a POST or PATCH still shows NetBox's message and does not change local data.

## Writes (P4 amendment)

Views call `NetBoxSyncEngine`. The engine owns `NetBoxWriteService`, which encodes `NetBoxWriteBody` values and sends them through `NetBoxFetching.send`. Generated write types stay unused. A device create upserts the 201 body and does not GET the device again. Interface enable, description, and label store the fields that were sent. Site, rack, and cable writes re-read the object (both interface ends for a cable) through `applyDeltaItem`. No write pages `/api/core/object-changes/`.

`NetBoxWritePolicy.shipped` is last-write-wins: no `If-Match`. NetBox 4.6 emits `ETag: W/"<last_updated>"`. RFC 7232 strong comparison never matches a weak validator; do not turn `sendIfMatch` on until the lab proves both the 412 path and a successful match. 412 still surfaces as `NetBox conflict (412): <server body>`.

`custom_fields` is omitted unless the caller passes changed keys only. Interface enable/description PATCHes never include it.

Site and device create are small forms. Map **+** POSTs `/api/dcim/sites/` (name, derived slug, status, optional region/group/tenant/pin). Site View **+** POSTs `/api/dcim/devices/` (name, role, type, status). After a device POST, Pulse lists `/api/dcim/interfaces/?device_id=` and applies those rows with no delete pass (template ports, e.g. FortiAP). A successful write does not page `/api/core/object-changes/`. A device create stores the 201 body. Site, rack, and cable writes re-read the object from NetBox. Interface enable, description, and label store the fields that were sent. The watermark moves on launch, Apply changes, Full Resync, and the idle delta (every 120 seconds, and 2 seconds after the last write in a burst). That idle pass is delta-only: a due safety mirror, a missing watermark, or a watermark NetBox no longer has waits for the next launch or Apply changes. Unknown `changed_object_type` stays skipped. `dcim.frontport` and `dcim.devicebay` apply on the idle pass, so a new patch panel's ports appear without a relaunch. Site pins send `MKAddress.fullAddress` clipped to 200 characters and lat/lon rounded to 5 decimals. Region is suggested by matching stored region names in the address. Failed POSTs leave no local row.

`Interface.cableId` is the NetBox cable id used to DELETE. If it is missing on a connected row (store predates the field), disconnect retrieves the live interface and reads the id from NetBox.

## Cables and racks (P4 amendment)

`Cable` is a SwiftData `@Model` (`#Index` on denormalized `siteId`). The cable's own tenant, length, colour, and description persist; `bundleId` is stored and unused. Streaming ingest of `/api/dcim/cables/` follows the interface walk. A write or changelog `dcim.cable` upserts the cable row and re-fetches both interface ends. Delete All includes `Cable`.

Every device is a `Device` row, including rack hardware. `Device` stores `frontPortCount` / `rearPortCount` / `deviceBayCount`. `DeviceBay` is a `@Model` (`#Index` on shelf `deviceId`). `FrontPort` is a `@Model` (`#Index` on `deviceId` and `siteId`). Full sync walks `/api/dcim/front-ports/` after device bays. The rack elevation reads `rack.devices`; shelves read stored bays; patch panels read stored front ports and Connect/Disconnect through `dcim.frontport` cable terminations. Which roles appear on the graph, DeviceRow, and elevation, and which will count toward a future license, is `RolePresentation` (Settings → Roles).

HTTP error bodies are the server JSON, not `HTTPURLResponse.localizedString`.

Failed writes do **not** stay in Pulse. There is no outbox and no retry queue: a transport or validation error leaves SwiftData on the last authoritative fetch and the editor reverts. Staging a local change would diverge from NetBox and fight the next delta. The operator retries when the instance is reachable.

## Write intents (P5 amendment)

**Status: accepted** (2026-10-14). Decision owner: Leon Cassidy. Device create is the first slice on `feat/netbox-write-intents`: the sheet returns when the ask is recorded. The DEBUG timers under *Measurement* stay.

**One lifecycle for every write.** The sheet returns when the ask is recorded. NetBox's POST stays on `NetBoxSyncEngine`. A failed ask stays on screen with NetBox's own words. SwiftData changes only after a NetBox id exists.

An intent satisfies the no-outbox rule because it is memory. `PendingWrites` is not SwiftData, and it is not replayed on launch. A crash or a quit drops the ask. If NetBox committed the POST, the next delta inserts the object. If NetBox did not, nothing appears. There is no provisional id, no negative id, and no placeholder flag. Discard removes an ask that has not committed. Undo of a committed write stays a per-kind DELETE or PATCH with a confirm, as disconnect does today.

### Lifecycle

What is shared is the ask: composed locally, posting, committed (NetBox id known) or failed (server body). What varies per kind already exists, plus the ghost the surface draws: `NetBoxWriteBody`, `NetBoxRecord`, `NetBoxChangeKind`. `submit` takes `[some NetBoxWriteIntent]` (one Swift type per call), inserts `.posting` entries, and returns `[WriteToken]` before the POST. The intents then run inside the existing `performWrite` frame, in order. One failure marks that entry `.failed` and the rest continue. The store and `submit` do not switch on kind. The intent produces the ghost at insert.

```swift
protocol NetBoxWriteIntent: Sendable {
    associatedtype Body: Encodable & Sendable
    associatedtype Record: Decodable & Sendable
    associatedtype Ghost: Sendable
    static var kind: NetBoxChangeKind { get }
    var body: Body { get }
    var siteId: Int64 { get }
    func ghost(token: WriteToken) -> Ghost
    func send(through writer: NetBoxWriteService) async throws -> (record: Record, raw: Data)
    func perform(on engine: NetBoxSyncEngine, token: WriteToken) async throws
}

enum WriteState: Sendable, Equatable {
    case posting
    case committed(id: Int64)
    case failed(NetBoxSyncError)
}
```

`send` returns the response body so the store does not GET the object again. `perform` is how `submit` stays free of a kind switch. The device intent's `perform` calls `runDeviceCreate`, which calls `send`, marks `.committed`, then stores the 201. A cable intent implements `perform` the same way and does not edit `submit` or `PendingWrites`.

`PendingWrites` is `@MainActor` and `@Observable`. `PulseApp` constructs it beside the engine and injects it as its own environment value, the same way views read `LicenseSeatStore` and `OperatorNoticeCenter`. The engine is the only mutator. The store cannot live on the actor: a view has to read it synchronously, and `NetBoxSyncEngine` is an actor. Views do not see `NetBoxWriteService`.

`ghosts(of:at:)` filters that dictionary by intent type and site. It is O(pending) and does not touch SwiftData. Pending is the asks of this session. Merging ghosts into the site graph does not call `fetchVOs`.

`DeviceCreateIntent.Ghost` is a small Sendable: name, role id, site id, optional rack placement (U and face), and the token. It is not a `@Model`. The graph keeps its `@Query` of `Device`. A `DeviceVO` migration of the graph is out of scope.

### Decisions

1. **Where it lives.** Sibling environment value. The engine writes it. Views read it.

2. **Hand-over, one rule for every kind.** The engine marks `.committed(id:)` when NetBox returns the created object. NetBox is the record, so a 201 is the fact. The store write follows in the same frame: for a device, `upsertRetrieved` of the 201, then the seat grant and the interface list; for a cable, the POST body, then both ends. A store failure after the 201 is a log line on `netbox`/`write`. The ask still retires, the frame counts as a success, and the quiet delta brings the object. The engine retires the entry on the first `.netBoxStoreDidApply` it posts after that commit. For a device that is the `postApply` at the end of `performWrite`, after the interface GET. For a cable it is the `postApply` after `applyCableAndEnds`. Views filter the entries still held. They do not remove them. A per-kind retire check means the protocol is missing a requirement. There is no second notification name.

   The site graph's `@Query` of `Device` is not the retire signal. A cable has no such query. The real edge appears only after both interface ends are stored and `computeEdges` re-derives. `computeEdges` starts when the view receives that notification, so retiring in the same turn left the cable missing. Retire now runs on the next main-actor turn. There is still no per-kind branch. The edge pass then reads off the main actor. Until that pass assigns the cable, the graph keeps the tether, at the stored stroke's width and cap (`edgeStroke`, 1.69 pt, round). The tether then fades out and the stored stroke fades in, over 0.35 s. A failed ask fades in at that same stroke, with Discard. The view does not remove the ask. `Edge.id` is the undirected interface pair, so a later pass does not rebuild every cable.

   A device ghost is drawn at `DeviceGhost.fallbackPoint`, `CGPoint(x: 150, y: 150)`, the point `positionBinding` already uses when a device has no layout slot. A ghost is not in `site.devices`, so the layout will not place it. There is no drop-to-create on the canvas, so the ask records no point and the engine does not pin one. The stored device takes its layout slot, or the same fallback until the layout runs again. Rack U and face stay on the body. They are a different coordinate space. A cable ghost has no point of its own. Its ends are real devices.

3. **Failed entries.** `.failed` keeps the entry and the body until Discard. A 400 shows NetBox's body. Transport shows the existing offline sentence. The entry survives a site switch. `ghosts(of:at:)` hides it from other sites. Discard clears the entry and its notice. Edit opens `DeviceBuilder` prefilled and leaves the failed ask on screen. Create submits a new token, then discards the old one. Cancel keeps the failed ask.

4. **Admission.** `requireAdmit` stays in the engine, in front of the POST. The sheet's `canAdmitEligible` check stays so the paywall can appear before dismiss. If the engine refuses after dismiss, that entry becomes `.failed` with the cap message and no POST is sent.

5. **The write frame.** Left as it is. On the lab switch create, `timing performWrite wait` was 0 ms, so the idle pass and the previous write were not in front of the POST. `performWrite` already cancels the previous quiet-catch-up timer at entry and arms one 2-second delta when `writeDepth` returns to 0, so a burst shares one catch-up. Idle still yields before the next changelog page and between objects once `writeInProgress` is set. No new preemption. A sync that is in flight is still waited for, but its failure is not the write's: the sync has published its own error, and the write runs and reports its own outcome.

6. **After the 201.** The device is real when the 201 body is stored. Seat grant and `refreshDeviceInterfaces` stay in the same frame after `.committed` is published. The graph draws the device without its interfaces. The faceplate and the interface table reload on `.netBoxStoreDidApply`, which still fires after the interface GET. A failed interface GET stays a log line. The quiet delta is the recovery, as it is today.

7. **Main-thread fetches.** The lab create spent 674 ms inside `computeEdges` on the main actor, after the POST had already returned. That pass runs on every apply. `computeEdges` now captures the visible device ids on the main actor, reads a fresh `ModelContext` on a detached user-initiated task (the `applyOnStore` shape), and publishes `[Edge]`. A fetch error still draws no edges. A pass that is no longer the latest, or whose view task was cancelled, does not assign. The next pass does. The 674 ms is the whole pass. It is not yet split between the site fetch and the per-device loop, so the loop in `SiteTopologyEdges.fetchVOs(siteId:)` stays until a later timer shows the walk is the cost. The replacement, when that timer says so, is two indexed fetches: interfaces whose `siteId` is the site, and interfaces still at `siteId == 0` joined to that site's device ids. Current applies stamp `Device.siteId` from the record and `Interface.siteId` from the owning device. Older rows can still be zero. One `siteId` fetch would drop those edges. The ghost merge does not call `fetchVOs`.

8. **Second kind.** Cable, interface to interface. `CableCreateIntent` adds a body, an `Edge` ghost, and `send`. It does not change `PendingWrites` or `submit`. `perform` calls `runCableCreate`, which is the same path as `createCable(from:to:)`: seat check, POST, `.committed`, then the POST body and both ends are stored. The front-port cable methods store their POST body the same way. That call is not nested in a second `performWrite`. `CablePairSheet` returns on submit. The public `createCable(from:to:)` still throws and does not stage an ask, so Connect and the popover stay as they are. Front-port cable methods stay as they are. `RackDraft` stays session-local. Replacing its undo stack is a later branch. A failed cable uses the same badge and Discard as a failed device. The stroke stays a path; the badge sits on the midpoint, because the modifier's stack would move the line. The ask and the stored edge share `edgeStroke`. The tether stays as ADR 0004 describes it: SwiftUI, no menu, no event monitor, and one approved right-click bridge (ADR 0005). After Create, the pointer overlay is down so the graph stays usable while the line waits for the stored stroke.

9. **Operator surfacing.** The ghost badge, plus one `OperatorNotice` per failed token (`id: "netbox.write.<token>"`, source `.netbox`), plus the existing `NetBoxSyncError.publish()` line on `RequestStatusManager`. The toolbar triangle reads the notice list. The sync dashboard reads the status manager. Edit and Discard live on the ghost.

10. **Scale.** Holds for an estate of about 12,000 devices today, about 120,000, and 1,000,000, and for a site of about 200 devices and 3,000 interfaces. `ghosts(of:at:)` does not scan the store. The edge pass reads one site, off the main actor, and still walks that site's devices. It does not load the estate. The two-index replacement in decision 7 is what makes one site a constant number of fetches, and it waits on a later timer.

### Logging

Intent logs use subsystem `netbox`, category `write`. That is the engine's subsystem. This ADR's structural rule is already "Logger subsystem `netbox`". SSH and Web audit events use subsystem `pulse` with dotted categories, as do the notes in `CLAUDE.md` for those areas. This amendment records the split and does not unify it. A later change should do that on purpose.

The DEBUG timers in *Measurement* stay on subsystem `netbox`, category `sync`, beside the existing `timing createDevice` lines.

### Measurement

One Debug create of a switch on the lab, device id 6066, 25 interfaces, 14994-byte POST body. Filter: `subsystem == "netbox" AND category == "sync" AND composedMessage BEGINSWITH "timing"`.

| Timer | What it covers | Lab, 2026-10-14 |
|---|---|---|
| `timing performWrite wait` | Entry of `performWrite` until the line before the closure runs. Previous write, in-flight sync, and the idle task. | 0 ms |
| `timing createDevice admit` | Seat check before the POST. | 0 ms |
| `timing createDevice POST` | `POST /api/dcim/devices/`. NetBox builds the component templates in that transaction. | 877 ms |
| `timing createDevice store POST body` | Upsert of the 201 body. | 44 ms |
| `timing createDevice grant seat` | `grantNewDevice`. | 2 ms |
| `timing createDevice GET interfaces` | `GET /api/dcim/interfaces/?device_id=6066`, 25 rows. | 236 ms |
| `timing createDevice total` | The closure. Admit through the interface list. | 1160 ms |
| `timing computeEdges` | Start of `computeEdges` until `[Edge]` is assigned. The lab figure is the per-device walk on the main actor. The walk now runs on a fresh `ModelContext`. The sheet does not await this. `postApply` schedules it. | 674 ms |

The sheet today awaits the closure, so this create held it for about 1.2 s. The wait in front of the closure was 0 ms. The POST is 877 ms of that 1.2 s, and it is NetBox's time. The 674 ms edge pass is the main-actor stall, and it runs after the closure returns. An earlier switch (55 interfaces) measured 1665 ms inside the closure and about 4 s of sheet wall clock. That earlier gap was not this wait.

The lines `Skipping unknown changelog type dcim.consoleport` and `dcim.powerport` are the quiet catch-up naming component types Pulse does not store. They are not part of the button wait.

After the device slice, the sheet dismisses without waiting on the POST. The edge slice is in. A later lab, 2026-10-15, measured the off-main pass. The 674 ms figure above is the main-actor walk and stays the before. `timing performWrite wait` was 0 ms on each write below.

| What happened | Lab, 2026-10-15 |
|---|---|
| `timing computeEdges`, no write staged in the pasted lines above it | 125 ms |
| Cable id 1452. Wait 0 ms. Then `computeEdges`, then the quiet pass skipped `dcim.cabletermination` ids 2768 and 2769, then `computeEdges` again | 46 ms, then 48 ms |
| Camera device id 6069. Wait 0 ms, admit 0 ms, `POST /api/dcim/devices/` 2152 bytes 571 ms, store 52 ms, grant 3 ms, `GET /api/dcim/interfaces/?device_id=6069` 1 row 144 ms, total 1268 ms. Then `computeEdges`, a WAL checkpoint, then `computeEdges` again | 132 ms, then 120 ms |
| Cable id 1453. Wait 0 ms. Then `computeEdges` | 59 ms |

### Later check: stall after a save

Not changed in this pass. After a context save the graph and the map hitch, and the map's flashing site marks drop to about 1 to 2 fps. Check these, in this order:

1. A device create saves more than once before the button's work is done: the 201 body, `grantNewDevice`, and the interface list are each an `applyOnStore` save. The write's `postApply` then schedules `computeEdges`. The quiet catch-up applies that window again and, when it applied an object, posts `.netBoxStoreDidApply` a second time. Cable 1452 shows the pair (46 ms, then 48 ms after the skipped cable terminations). Device 6069 shows the pair (132 ms, then 120 ms) with `WAL checkpoint` between them. `stampDeltaSuccess` is its own save of `SyncProvider`.
2. Each of those saves merges into the view context. `@Query` surfaces refresh on that merge, including the site graph and the map. That matches a stall that starts at the save and then runs more than once.
3. `Edge.id` was a new UUID on every `derive`, so assigning `[Edge]` rebuilt every cable. The cable hand-off above now uses the interface pair. A pass no longer remounts unchanged cables. That does not remove the extra save or the second apply.
4. The map marks that drop to 1 to 2 fps are `AnnotationView`'s repeating `.symbolEffect(.pulse)` on `circle.fill` while `site.highestUnacknowledgedSeverity > 0`. That effect is the symptom of the main thread stalling. It is not a separate pulse bug. Leave it until the save path is checked.

### Order

Timers, this section, then sign-off. Accepted 2026-10-14. Device create is in: the ghost on the site graph and the rack elevation, `GhostedModifier` in `Pulse/Views/View Modifiers/`, `.ghosted(state:)` in `Pulse/Extensions/View+Extensions.swift`. The edge fetch runs off the main actor. Cable create, interface to interface, uses the same ask. The operator note is the Writes section of `docs/netbox-sync.md`.

### Why the pending layer is here, and what comes next

**What it is.** `PendingWrites` holds each create that NetBox has not answered yet: a device or a cable, its state (posting, committed, failed), and the picture the graph and rack draw for it. It lives in memory beside the SwiftData store. The store still changes only from NetBox's answer.

**Why it is here.** Leon Cassidy asked for New Device and the cable pair sheet to close before the POST, for the device to appear on the graph while NetBox works, and for the cable to stay drawn until the stored one replaces it. A refused create stays on screen with NetBox's sentence, Edit, and Discard, so the operator fixes it without typing the form again. The only other place a not-yet-stored object could live is the store, and the no-outbox rule keeps it out of there.

**Its limit.** A pending device is a picture, not a device. It cannot be moved, selected, racked, or cabled until NetBox answers, because those all key on a NetBox id and on interfaces that only exist after the create. Adding a second device works. Building a site in one sitting does not.

**Review, 2026-10-15.** A review proposed deleting the layer and returning to close-then-throw with one notice. Kept, by Leon Cassidy's decision: it is what lets a refusal be fixed in place, and the cable hand-off stays with it. The review's point stands for the next phase below.

**Next phase, to iterate on.** Build mode becomes a site draft, the `RackDraft` pattern applied to the site: draft, Undo, Cancel, Save.

1. Add, move, rack, and cable against the draft. Nothing waits on NetBox.
2. Save turns the draft into ordered writes: devices, then their interfaces, then cables matched to interfaces by name, then rack changes. They run through `submit`.
3. A refused item stays in the draft with NetBox's sentence. Items NetBox accepted leave it.
4. When the draft lands, it replaces `PendingWrites` and the ghosts as the place a not-yet-stored object lives. The throwing writes, the error sentence parser, and `ChoiceField` carry over.

Open before that work starts: whether a draft survives a quit; where graph positions are kept (a NetBox custom field or the on-device store), since they reset today; and syncing NetBox interface and front-port templates, which is what lets a drafted device be cabled before it exists. Templates are catalogue-sized, per device type, so the sync holds at 1,000,000 devices. NetBox's bulk POST can cut a Save to a few round trips once the design is settled.

### Held back

No SwiftData row for an ask. No retry queue. No kind switch in the store. No second notification. `NetBoxWritePolicy.sendIfMatch` stays off. `NetBoxAPI` is not hand-edited. `RackDraft` is not migrated. Front-port ghosts are not in this branch. Issue #47 stays open.
