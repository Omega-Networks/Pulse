# NetBox sync (operator)

Pulse mirrors a subset of NetBox into local SwiftData. The **first** launch (and any launch with no changelog watermark) does a full pull, including interfaces, cables, rack fillers, device bays, and front ports. After that, boot applies `/api/core/object-changes/` since the last applied change id. Settings → Database → **Full Resync** still does a complete mirror.

A watermark older than NetBox’s retained changelog (default 90 days - `CHANGELOG_RETENTION` must exceed the longest expected offline gap) or a wiped store with a leftover watermark forces a full mirror. A weekly safety mirror covers edits made without request context (shell, migrations).

Each changelog page is stored before the next page is requested. If a page fails, the watermark stays at the last page that applied, and the next run retries that failed page. The watermark does not move backward.

While Pulse is open it also applies the changelog about every two minutes, including after a launch sync error, and again shortly after you save. That pass is a delta only. A full mirror still waits for the next launch or **Apply changes** when the weekly safety interval is due, or for **Full Resync** when you ask for one. Edits made outside a request (shell, migrations) still need that safety mirror. Devices that changed are seated as part of that pass. A full mirror, including one caused by the page cap, and a failed launch still seat every stored device. A changelog page that only touches ports does not rescan devices. If the unsynced changelog is too large for one idle pass, pages that finished stay applied, the NetBox status line says the rest is waiting, and the two-minute loop does not download that window again. The next launch or **Apply changes** clears that wait and, past the page cap, runs a full mirror.

## Token

In Settings, enter the NetBox API URL (must be `https://` with a host) and a token. An empty token is refused - Pulse will not send an unauthenticated request. `http://` is rejected even on the local network.

- Tokens that do **not** start with `nbt_` are sent as `Authorization: Token …` (v1).
- Tokens that start with `nbt_` are sent as `Authorization: Bearer …` (v2).

Use a **dedicated service account**. Read-only tokens still work for sync. Writes (interface enable/description, cable connect/disconnect) need:

- `write_enabled` on the token
- model/action-scoped permissions: `dcim.interface` change, `dcim.cable` add/delete
- v1 `Token …` or v2 `Bearer nbt_…` (same as read)

A token without write permission returns 403; Pulse shows NetBox's body and does not change local data.

A token that can read sites and devices but not another model still finishes the sync. Pulse keeps the rows it already stored for the model it cannot read, shows a warning, and does not ask for that model again until the next launch or **Apply changes**. A token that cannot read sites or devices, or that NetBox rejects entirely (401), stops the sync. A token that cannot read the changelog does not start a full mirror from the two-minute loop. The warning stays up, and the next launch or **Apply changes** tries the changelog again.

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
- **Pull a cable (macOS site graph)** - turn on the hand (build mode). Hover a seated device and click the plus. The plus hides while the line is out, and while a device is being dragged. Back on the device you started from, that plus is an X; click it to spring the line back to where it started and drop it. The line follows the pointer and sits on another seated device when the pointer is over that device's icon. Left-click the icon. The sheet lists each device's free interfaces, with the first one selected. Create closes the sheet and sends the same cable POST as **Connect…** (interface terminations only; status, type, and tenant are left to NetBox). The line stays at the same width as a stored cable, and fades out as that cable fades in. Right-click, or press Cancel, before Create, springs the tether back and drops it. A left-click on empty graph does not. If NetBox refuses or is unreachable, the line stays at that same width, with NetBox's words and Discard. Nothing is stored locally until NetBox accepts the cable. iOS has no pull-a-cable gesture; use **Connect…**.
- **Disconnect** - asks first, then DELETE `/api/dcim/cables/{id}/`. If the local row has no cable id (interfaces synced before that field existed), Pulse reads the live interface first. Right-click a row if the button is hard to hit. There is no undo on the graph.

A new device or cable is stored from the POST response. Site and rack writes re-read the object from NetBox. If NetBox stored the object but Pulse could not store it locally, the write still counts as done and the next quiet delta brings it. If the write never reaches NetBox (offline, 403, validation), Pulse discards the edit and shows the last stored value. Offline is **NetBox is unreachable. The change was not saved.** - the cable or description stays as it was. There is no queued retry; reconnect and submit again.

To see a **validation** body: **Connect…** on a free interface, pick a port under **Already connected**, and Connect. NetBox rejects a second cable (occupied termination / duplicate). Pulse shows that JSON and does not change the local row.

Validation errors (duplicate cable, missing field) show the server JSON.

`custom_fields` are only sent when that key changed. Enable/description/cable writes do not touch them.

### An ask on screen

New device, and Create on a pulled cable, record the ask and return immediately. The device is drawn dim while NetBox stores it, using the symbol for the role that was picked (a camera ask is the camera) and the model under the name, the same stack a stored device uses, so the icon does not move when the stored device replaces the ask. The cable is the same width as a stored cable and fades in and out. A failure stays on screen, with NetBox's words (or the offline sentence), until Discard. Edit on a failed device opens the same New Device form with those fields. The failed ask stays until Create sends a new one; Cancel keeps it. A cable has Discard and no Edit. Nothing is queued. Quitting Pulse drops an ask that has not been stored. If NetBox stored it and Pulse quit before the picture updated, the next sync brings the object.

**Connect…**, interface edits, front-port cables, and rack Save still wait for NetBox and show the error in place.

## Site and device creation

**New site** is the map window **+**. Tap the map first if you want coordinates and a reverse-geocoded address; then **+**. The form sends `name`, a slug derived from the name, `status`, and optional region/group/tenant. Address is the MapKit full line, clipped to 200 characters. Coordinates are rounded to 5 decimals. Region is preselected when a stored region name appears in that address. A failed POST leaves no local site.

**New device** is Site View **+**. Name, role, type, status. Every choice (role, type, status, tenant, face) is a typed field. Click or Tab into it and the full list opens; it scrolls, and it is no taller than the form. Typing narrows it. A value counts only when it matches an entry exactly. Tab and Shift-Tab move through every field, Return creates, and Escape closes the list, then the form. New Rack and Add at U use the same fields; the Descending units checkbox is reached by Tab only when Keyboard navigation is on in System Settings. Create records the ask and closes the form, then POSTs `/api/dcim/devices/` and stores that response, then loads that device's interfaces so template ports (FortiAP and similar) show. The device is drawn dim on the graph and, when it has a rack position, on the elevation, until that store finishes. A failed POST leaves no local device; the dim device stays until Discard or Edit. Serial, primary IP, and other fields are not on this form yet.

## Rack edit

Racks live in Site View's right-hand **Rack View** tab and scroll left to right, aligned to the top of the pane. Elevations follow EIA-310-D / IEC 60297: 1 RU is 1.75 in, the frame is 19 in, equipment chassis is 17.75 in between the rails, and blank plates / patch panels span the full 19 in.

The pencil next to **+** arms edit mode. Drag is off until then, so a glance cannot unrack a device. In edit mode, drag a graph node onto a U, drag a racked device to another U or another rack, or drop it on the graph (or empty strip) to unrack. Click an empty U to place an existing unracked device or **Create new…** (the same New Device form, including tenant). Each rack has a Front / Rear control; occupancy is per face. In edit mode, right-click a device to move it to the other face.

Click a patch-panel port to Connect (to a free interface or another front port at the site) or Disconnect. That POSTs / DELETEs `/api/dcim/cables/` with `dcim.frontport` terminations. Ports stay numbered placeholders until a Full Resync has stored FrontPort rows. While you drag, the original stays put and the target Us highlight until you drop. **Undo** / **Cancel** / **Save** sit next to **Racks**. Undo and Cancel stay local. **Save** PATCHes each device (`rack` + `position` + `face`, or nulls on unrack). Creating a new device POSTs immediately. A failed write stops the rest and does not queue a retry.

**+** on the Racks row POSTs `/api/dcim/racks/` with name, site, status, `u_height`, form factor, width, mounting depth, outer dimensions, airflow, tenant, location, rack role, and the other optional fields on the form. Empty optionals are omitted. Location and rack-role pickers read `/api/dcim/locations/` and `/api/dcim/rack-roles/` (Full Resync once after this change).
