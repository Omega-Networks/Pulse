# NetBox sync (operator)

Pulse mirrors a subset of NetBox into local SwiftData. The **first** launch (and any launch with no changelog watermark) does a full pull, including interfaces, cables, rack fillers, device bays, and front ports. After that, boot applies `/api/core/object-changes/` since the last applied change id. Settings → Database → **Full Resync** still does a complete mirror.

A watermark older than NetBox’s retained changelog (default 90 days - `CHANGELOG_RETENTION` must exceed the longest expected offline gap) or a wiped store with a leftover watermark forces a full mirror. A weekly safety mirror covers edits made without request context (shell, migrations).

After a failed delta, the watermark does not move; the next run retries from the same id.

## Token

In Settings, enter the NetBox API URL (must be `https://` with a host) and a token. An empty token is refused - Pulse will not send an unauthenticated request. `http://` is rejected even on the local network.

- Tokens that do **not** start with `nbt_` are sent as `Authorization: Token …` (v1).
- Tokens that start with `nbt_` are sent as `Authorization: Bearer …` (v2).

Use a **dedicated service account**. Read-only tokens still work for sync. Writes (interface enable/description, cable connect/disconnect) need:

- `write_enabled` on the token
- model/action-scoped permissions: `dcim.interface` change, `dcim.cable` add/delete
- v1 `Token …` or v2 `Bearer nbt_…` (same as read)

A token without write permission returns 403; Pulse shows NetBox's body and does not change local data.

Pulse does **not** send `If-Match`. Concurrent edits last-write-wins. A 412 from the server is shown as a conflict, not applied.

## Filters

Sync stores every device, device type, and device role. There is no `manufacturer_id__n` or `role_id__n` on the pull. Fetch and local delete stay aligned (the whole instance).

What you see is **Settings → Roles**. Those toggles never delete rows. Roles 6, 7, 18, and 27 (blank, cable management, patch panel, shelf) default to rack hardware: hidden from the site graph and device list, drawn in the rack, not monitored.

Seats count roles that appear on the site graph, in the device list, or in the rack as a named device. **As hardware** does not count. See the [user guide](user-guide.md).

After this change, run **Full Resync** once so previously excluded Generic devices, roles 29/30, and their interfaces land in the store.

## Custom fields (Zabbix host id)

Pulse matches a NetBox device to Zabbix using a **custom field on `dcim.device`**. Create it in NetBox (Customization → Custom Fields) if it is not already there. Pulse does not create the field.

| NetBox key | Type | Purpose |
|---|---|---|
| `zabbix_id` | Integer | Zabbix host id for this device. Required for live items, charts, and problems. `0` or empty means no Zabbix host. |
| `zabbix_instance` | Integer | Optional Zabbix instance discriminator when more than one Zabbix server is in play. |
| `coordinate_x`, `coordinate_y` | Decimal | Site-graph layout. Not used for Zabbix. |

The slug must be exactly `zabbix_id` (and `zabbix_instance` if you use it). Pulse reads these on sync and stores them on the local device. Interface, cable, and rack writes do not send `custom_fields` unless that key changed.

Without `zabbix_id`, the device still appears from NetBox. It has no monitoring colour, no item charts, and no problem feed.

## Forced resync

Settings → Database → **Full Resync**. That is a complete pull and resets the changelog watermark to the latest object-change id. Ordinary launches apply deltas only.

**Delete All Data** wipes NetBox (and Event) rows on a side context so the open map and event toolbar are not left holding deleted models. If it crashes with `Event.rClock` / “backing data could no longer be found”, rebuild this branch (commit `47684d2` or later). A later change will replace the store file instead of deleting row-by-row.

## Regenerating the client

After a NetBox minor upgrade:

```bash
export NETBOX_URL=https://netbox.example.com
export NETBOX_TOKEN=…          # shell only; never commit
./Scripts/regenerate-netbox-client.sh
```

The script fails if the instance host is still present in the vendored YAML or generated Swift. Review the spec diff before committing.

## Writes

From a device's Interfaces table or faceplate popover:

- Edit a description and press Return - PATCH `/api/dcim/interfaces/{id}/` with `description` only
- Toggle Enabled - PATCH with `enabled` only
- **Connect…** - pick a free interface at the site (filter by device or name), then POST `/api/dcim/cables/` with `a_terminations` / `b_terminations` `{"object_type":"dcim.interface","object_id":N}`. The open site graph reloads after the write.
- **Disconnect** - asks first, then DELETE `/api/dcim/cables/{id}/`. If the local row has no cable id (interfaces synced before that field existed), Pulse reads the live interface first. Right-click a row if the button is hard to hit.

Every successful write re-reads the object from NetBox. If the write never reaches NetBox (offline, 403, validation), Pulse discards the edit and shows the last stored value. Offline is **NetBox is unreachable. The change was not saved.** - the cable or description stays as it was. There is no queued retry; reconnect and submit again.

To see a **validation** body: **Connect…** on a free interface, pick a port under **Already connected**, and Connect. NetBox rejects a second cable (occupied termination / duplicate). Pulse shows that JSON and does not change the local row.

Validation errors (duplicate cable, missing field) show the server JSON.

`custom_fields` are only sent when that key changed. Enable/description/cable writes do not touch them.

## Site and device creation

**New site** is the map window **+**. Tap the map first if you want coordinates and a reverse-geocoded address; then **+**. The form sends `name`, a slug derived from the name, `status`, and optional region/group/tenant. Address is the MapKit full line, clipped to 200 characters. Coordinates are rounded to 5 decimals. Region is preselected when a stored region name appears in that address. A failed POST leaves no local site.

**New device** is Site View **+**. Name, role, type, status. Create POSTs `/api/dcim/devices/`, then Pulse loads that device’s interfaces so template ports (FortiAP and similar) show immediately. A failed POST leaves no local device. Serial, primary IP, and other fields are not on this form yet.

## Rack edit

Racks live in Site View's right-hand **Rack View** tab and scroll left to right, aligned to the top of the pane. Elevations follow EIA-310-D / IEC 60297: 1 RU is 1.75 in, the frame is 19 in, equipment chassis is 17.75 in between the rails, and blank plates / patch panels span the full 19 in.

The pencil next to **+** arms edit mode. Drag is off until then, so a glance cannot unrack a device. In edit mode, drag a graph node onto a U, drag a racked device to another U or another rack, or drop it on the graph (or empty strip) to unrack. Click an empty U to place an existing unracked device or **Create new…** (the same New Device form, including tenant). Each rack has a Front / Rear control; occupancy is per face. In edit mode, right-click a device to move it to the other face.

Click a patch-panel port to Connect (to a free interface or another front port at the site) or Disconnect. That POSTs / DELETEs `/api/dcim/cables/` with `dcim.frontport` terminations. Ports stay numbered placeholders until a Full Resync has stored FrontPort rows. While you drag, the original stays put and the target Us highlight until you drop. **Undo** / **Cancel** / **Save** sit next to **Racks**. Undo and Cancel stay local. **Save** PATCHes each device (`rack` + `position` + `face`, or nulls on unrack). Creating a new device POSTs immediately. A failed write stops the rest and does not queue a retry.

**+** on the Racks row POSTs `/api/dcim/racks/` with name, site, status, `u_height`, form factor, width, mounting depth, outer dimensions, airflow, tenant, location, rack role, and the other optional fields on the form. Empty optionals are omitted. Location and rack-role pickers read `/api/dcim/locations/` and `/api/dcim/rack-roles/` (Full Resync once after this change).
