# NetBox sync (operator)

Pulse mirrors a subset of NetBox into local SwiftData. The **first** launch (and any launch with no changelog watermark) does a full pull, including interfaces. After that, boot applies `/api/core/object-changes/` since the last applied change id. Settings → Database → **Full Resync** still does a complete mirror.

A watermark older than NetBox’s retained changelog (default 90 days — `CHANGELOG_RETENTION` must exceed the longest expected offline gap) or a wiped store with a leftover watermark forces a full mirror. A weekly safety mirror covers edits made without request context (shell, migrations).

After a failed delta, the watermark does not move; the next run retries from the same id.

## Token

In Settings, enter the NetBox API URL (must be `https://` with a host) and a token. An empty token is refused — Pulse will not send an unauthenticated request. `http://` is rejected even on the local network.

- Tokens that do **not** start with `nbt_` are sent as `Authorization: Token …` (v1).
- Tokens that start with `nbt_` are sent as `Authorization: Bearer …` (v2).

P1 is read-only. A write-enabled token is not required. Writes (P4) will need `write_enabled` and a dedicated service account.

## Filters

Fetch and local delete share one configuration (`NetBoxFilterConfiguration`). Defaults match the previous baked-in query so a first sync is a parity run, not a scope change.

| Filter | Default | Used on |
|---|---|---|
| Exclude manufacturer IDs | `5` | device types, devices |
| Exclude role IDs | `29`, `30` | device roles, devices, interfaces (`device_role_id__n`) |
| Static-device role IDs | `6`, `7`, `18`, `27` | on-demand rack fillers (blank plate, cable management, patch panel, shelf) |

Changing these is configuration, not a code edit. A Settings UI comes later.

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

## Site creation

Add Site is disabled. The previous control never POSTed. Writes land in P4.
