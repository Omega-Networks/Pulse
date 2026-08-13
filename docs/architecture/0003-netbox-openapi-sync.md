# ADR 0003 — NetBox OpenAPI Sync

| | |
|---|---|
| **Status** | Accepted (P1) |
| **Date** | 2026-08-13 |
| **Decision owner** | Leon Cassidy |
| **Applies to** | `Pulse/NetBox/**`, `NetBoxAPI/**`, `Pulse/Models/SiteDataService.swift`, boot + Sync Dashboard |

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

## What ships when

| Phase | Ships |
|---|---|
| **P1 (this ADR)** | Generated GET client, boot + dashboard + on-demand site loads, ingest DTOs, delete gate, Add Site disabled, operator stub |
| **P2** | Persisted `Interface` `@Model`, drop `InterfaceCache` |
| **P3** | Changelog watermark, delta pass |
| **P4** | MACD writes, real Add Site, ETag |

## Structural enforcement

- Views never import `NetBoxAPI` or call the generated `Client`.
- SwiftData models do not cross actors; `NetBoxRecord` values do.
- Logger subsystem `netbox`. Operator errors go through `RequestStatusManager`.

## Verification

| Gate | Status |
|---|---|
| Gate 1 — lab count parity, skip+delete, network kill, Add Site disabled | In progress (lab) |
| Gate 2 — offline interfaces | Not yet |
| Gate 3 — changelog converge | Not yet |
| Gate 4 — write round-trips | Not yet |

## Alternatives rejected

- **Build plugin.** Hand-maintained pbxproj; generation must be reviewable in git.
- **Keep `*Properties`.** They re-derived the schema and failed closed on unused fields.
- **Tag-filtered spec.** NetBox 4.6 collapsed tags; filter by operation IDs.

## Revision history

- 2026-08-13 — P1 accepted. Ingest-DTO lesson recorded after generated types skipped lab tenants, sites, racks, devices, and services.
