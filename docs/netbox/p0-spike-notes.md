# P0 spike notes — 2026-08-13

Against lab `https://netbox.omega.net.nz`. Token was env-sourced; not recorded here.

## Instance

| Key | Value |
|---|---|
| `netbox-version` | 4.6.2 |
| `netbox-full-version` | 4.6.2-Docker-5.0.1 |
| `django-version` | 6.0.5 |
| Schema | OpenAPI 3.0.3, 5.5 MiB, 226 968 lines, 329 paths |
| Plugins | `netbox_dns` 1.5.7 (out of scope) |

## UNVERIFIED plan items — confirmed or discounted

**Path-filter globbing — discounted.** Generator 1.13.0 `filter.paths` is an exact `OpenAPI.Path` match (`DocumentFilter.includePath`). `/api/dcim/devices/` does not include `/api/dcim/devices/{id}/`. Config therefore lists concrete operation IDs, not path prefixes.

**Tags collapsed to `api` — discounted for 4.6.2.** This instance has 14 real operation tags (`dcim`, `ipam`, `core`, `tenancy`, …). Path/operation filtering remains the right contract either way.

**ETag in the schema document — discounted; header is present.** No `ETag` / `If-Match` field in the OpenAPI document. A single-object GET returns `etag: W/"<last_updated>"` (weak, last-updated based) and `api-version: 4.6`. P4 can send `If-Match` even though the schema does not declare it.

**`MAX_PAGE_SIZE` — confirmed 1000.** Default page size is 50. `?limit=2000` and `?limit=10000` both return 1000 rows. Pagination helper should request `limit=1000`.

## Dates

DRF fractional-seconds footgun is still real in source, but **this lab snapshot had zero zero-microsecond timestamps** across devices (page), sites (page), tenants (all 15), racks, regions, roles, services, and all 163 changelog rows. Every sampled `created` / `last_updated` / `time` included microseconds.

The lenient transcoder is still mandatory: a single exact-second save will emit `2026-08-13T12:00:00Z` and the runtime's `.iso8601WithFractionalSeconds` will reject it. Proven:

- Real lab fractional timestamp decodes (fixture taken from device 882 `created=2022-09-21T03:30:07.062900Z`).
- Synthetic zero-microsecond `2024-01-02T03:04:05Z` decodes via the fallback.
- Invalid string throws.

## Changelog retention (for P3, recorded now)

`/api/core/object-changes/` count **163**. Oldest `id=103148` at `2026-05-15T01:50:48.072047Z`, newest `id=103310` at `2026-07-31T00:21:45.979725Z`. ~90-day window matches default `CHANGELOG_RETENTION`.

## Module isolation (not just a build-cost call)

Generated `Client.init` takes an unqualified `Configuration`. Pulse already has `@ConfigurationActor final class Configuration` with a private `init`. Compiling the generated files inside the app target fails (`Configuration initializer is inaccessible`). This is a name collision, not a measured-slow compile. The generated code therefore lives in a local Swift package `NetBoxAPI` so `OpenAPIRuntime.Configuration` and Pulse's `Configuration` never share a module. The factory in Pulse imports `NetBoxAPI` and qualifies `OpenAPIRuntime.Configuration`.

## Generation

- 29 operations (list+retrieve + status only). Write verbs were dropped: generated `PatchedWritable*Request` types do not conform to `Encodable` (empty `oneOf ()` in the NetBox 4.6.2 schema). P4 must solve that before regenerating writes.
- `Client.swift` 18 287 lines; `Types.swift` 28 837 lines. Isolated in local package `NetBoxAPI`.
- macOS Debug `xcodebuild` with generated client: **BUILD SUCCEEDED** (~50 s wall including regen; not a clean-from-zero measurement). Incremental after touching the factory is recorded in the P1 PR. No separate-module escalation for speed — the package exists because of the `Configuration` name collision.
- Filter CLI drops `components.securitySchemes`; the regenerate script restores `cookieAuth` / `tokenAuth` so the vendored document is generate-ready offline.
- Warnings to carry into P4: empty `oneOf ()` skipped on device/site **create** request bodies; optional multipart bodies skipped. GET responses generated cleanly.

## Auth

Lab token is v1 (`Token …`). Schema description already documents both `Token <token>` and `Bearer <key>.<token>`. Middleware picks Bearer iff the token starts with `nbt_`.

## Branching note

Local `main` was stale at `6f0ef9e`. Feature branch was recut from `origin/main` (`08cc1ff`, SSH terminal PR). Map-annotation commits were not included.
