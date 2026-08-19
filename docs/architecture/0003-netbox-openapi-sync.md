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
2. **Single owner.** `NetBoxSyncEngine` is the only full-sync entry. Boot and Sync Dashboard call `fullSync()`. Overlapping callers join the in-flight pass. `lastNetBoxUpdate` is stamped only after every type applies.
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

## Writes (P4 amendment)

Views call `NetBoxSyncEngine`. The engine owns `NetBoxWriteService`, which encodes `NetBoxWriteBody` values and sends them through `NetBoxFetching.send`. Generated write types stay unused. After a 2xx the engine re-fetches the object (both interface ends for a cable) through `applyDeltaItem` - the write response is not applied locally.

`NetBoxWritePolicy.shipped` is last-write-wins: no `If-Match`. NetBox 4.6 emits `ETag: W/"<last_updated>"`. RFC 7232 strong comparison never matches a weak validator; do not turn `sendIfMatch` on until the lab proves both the 412 path and a successful match. 412 still surfaces as `NetBox conflict (412): <server body>`.

`custom_fields` is omitted unless the caller passes changed keys only. Interface enable/description PATCHes never include it.

Site and device create are small forms. Map **+** POSTs `/api/dcim/sites/` (name, derived slug, status, optional region/group/tenant/pin). Site View **+** POSTs `/api/dcim/devices/` (name, role, type, status). After a device POST, Pulse lists `/api/dcim/interfaces/?device_id=` and applies those rows with no delete pass (template ports, e.g. FortiAP). A successful write then tries a watermark delta; that failure is logged, not a failed create. Site pins send `MKAddress.fullAddress` clipped to 200 characters and lat/lon rounded to 5 decimals. Region is suggested by matching stored region names in the address. Failed POSTs leave no local row.

`Interface.cableId` is the NetBox cable id used to DELETE. If it is missing on a connected row (store predates the field), disconnect retrieves the live interface and reads the id from NetBox.

## Cables and racks (P4 amendment)

`Cable` is a SwiftData `@Model` (`#Index` on denormalized `siteId`). The cable's own tenant, length, colour, and description persist; `bundleId` is stored and unused. Streaming ingest of `/api/dcim/cables/` follows the interface walk. A write or changelog `dcim.cable` upserts the cable row and re-fetches both interface ends. Delete All includes `Cable`.

Every device is a `Device` row, including rack hardware. `Device` stores `frontPortCount` / `rearPortCount` / `deviceBayCount`. `DeviceBay` is a `@Model` (`#Index` on shelf `deviceId`). `FrontPort` is a `@Model` (`#Index` on `deviceId` and `siteId`). Full sync walks `/api/dcim/front-ports/` after device bays. The rack elevation reads `rack.devices`; shelves read stored bays; patch panels read stored front ports and Connect/Disconnect through `dcim.frontport` cable terminations. Which roles appear on the graph, DeviceRow, and elevation, and which will count toward a future license, is `RolePresentation` (Settings → Roles).

HTTP error bodies are the server JSON, not `HTTPURLResponse.localizedString`.

Failed writes do **not** stay in Pulse. There is no outbox and no retry queue: a transport or validation error leaves SwiftData on the last authoritative fetch and the editor reverts. Staging a local change would diverge from NetBox and fight the next delta. The operator retries when the instance is reachable.
