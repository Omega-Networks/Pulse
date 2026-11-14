# ADR 0007 - NetBox clusters and virtual machines

| | |
|---|---|
| **Status** | Accepted for the data mirror. Later slices are not in this change. |
| **Date** | 2026-11-14 |
| **Decision owner** | Leon Cassidy |
| **Applies to** | `Cluster`, `VirtualMachine`, `NetBoxObjectRef`, `NetBoxSyncEngine` mirror stages, service port mappings |

## Principle

**A virtual machine is a NetBox object in its own right. Pulse stores it beside devices, keyed by id, and does not invent a second copy of a device view.**

This record is the data mirror only. Zabbix owner lookup, site sections, seats, SSH, the Web window target, and the Clusters browser are later slices. They are not in this change.

## Decisions

Taken with Leon Cassidy on 2026-11-14. The plan is `docs/plans/netbox-clusters-and-vms.md`.

| # | Decision |
|---|---|
| D1 | Cluster type and group are strings on `Cluster` (`typeName`, `groupName`). They are not models. |
| D2 | VM interfaces, virtual disks, and a VM type are not imported. |
| D3 | Tested against NetBox 4.7.4 behaviour. Service decode falls back to `protocol` and `ports` when `port_mappings` is absent, so a 4.3 to 4.6 instance still ingests. |
| D4 | `zabbix_id` is the same custom field as on a device. Slice 2 writes it. This slice only stores the number. |
| D5 | Cluster rollup severity is display only. Site counts do not read it. Slice 2 writes severity. |
| D6 | `Event.virtualMachine` and `Event.cluster` sit beside `Event.device`. `Event.owner` prefers the device, then the virtual machine, then the cluster. |
| D7 | Items for a VM or cluster load when that detail opens, not when the site opens. Not in this slice. |
| D8 | Site View groups hosts and VMs by cluster. Not in this slice. |
| D9 | VMs are not drawn on the site graph. |
| D10 | A cluster or VM with no single site is stored with `siteId` 0. The Clusters browser is slice 8. |
| D11 | macOS first. |
| D12 | A VM takes a licence seat the same way a device does. Not in this slice. This slice does not seat VMs. |
| D13 | SSH and Web targets come from NetBox services. This slice teaches the Web resolver `portMappings`. It does not change window targets. |
| D14 | A cluster does not take a seat. |
| D15 | `NetBoxObjectRef` is the one reference (`dcim.device`, `virtualization.virtualmachine`, `virtualization.cluster`). One SSH scene and one Web scene come later. No second copy of a device view. |

## What this slice stores

`Cluster` resolves its site from scope. `dcim.site` uses that id. `dcim.location` uses the stored location's site. A region, a site group, a missing location, or a missing scope id leaves `siteId` 0. A missing location is logged.

`VirtualMachine` stores placement as optional relationships and as denormalized ids. A missing parent stays nil. The id is still stored, or 0 when NetBox sent none. The name is not a key.

`Service.portMappings` replaces `protocolValue` and `ports`. A present `port_mappings` array is stored as sent, including an empty array. When the key is absent or null, Pulse synthesizes `tcp/22` from `protocol` and `ports`. A null protocol and no mappings stores nothing.

Device and virtual machine list and retrieve send `omit=config_context`. Pulse does not store config context. The device create body is unchanged.

## Sync

The mirror has 18 stages. Clusters run after locations. Virtual machines run after devices. Neither stage is required: a 403 keeps the rows already stored and the rest of the mirror finishes. Virtual machines stream page by page. A page with `skipped > 0` does not delete.

`SyncProvider.mirrorShape` is 0 on a store filled before this change. The next boot or Apply changes full-mirrors once, logged as `mirror shape changed`, and stamps shape 2 only when that mirror finishes. The check sits after the empty-store and missing-watermark reasons, and before the weekly safety interval. Idle catch-up never full-mirrors.

Changelog kinds are `virtualization.cluster` and `virtualization.virtualmachine` (alias `virtualization.virtual_machine`). `clustertype`, `clustergroup`, `vminterface`, and `virtualdisk` stay unknown, so they are skipped and the watermark can still advance.

Delete All removes events and services first, then virtual machines, then devices, then clusters.

## Scale

The design holds at 1,000,000 devices and the virtual machines that sit with them. A virtual machine page is applied and released. A question about one object does not fetch the table. `deleteStale` still scans a type when a delete is allowed. That scan is existing debt, not a new primitive.

## What was deleted

`Service.protocolValue`, `Service.protocolLabel`, and `Service.ports`. NetBox 4.7 leaves them null on a multi-protocol service, so they could not answer which port a button should open. `portMappings` is the replacement.

`InitializationState.totalSteps = 16.0`. The progress total is `NetBoxSyncEngine.mirrorStageCount`.

## Revision history

- 2026-11-14 - Data mirror accepted for implementation. Later slices stay out until their gates.
