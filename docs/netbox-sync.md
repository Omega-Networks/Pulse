# NetBox sync (operator)

Pulse mirrors a subset of NetBox into local SwiftData on every launch and when you press **Sync Data** in Settings → Database.

## Token

In Settings, enter the NetBox API URL (including `https://`) and a token.

- Tokens that do **not** start with `nbt_` are sent as `Authorization: Token …` (v1).
- Tokens that start with `nbt_` are sent as `Authorization: Bearer …` (v2).

P1 is read-only. A write-enabled token is not required. Writes (P4) will need `write_enabled` and a dedicated service account.

## Filters

Fetch and local delete share one configuration (`NetBoxFilterConfiguration`). Defaults match the previous baked-in query so a first sync is a parity run, not a scope change.

| Filter | Default | Used on |
|---|---|---|
| Exclude manufacturer IDs | `5` | device types, devices |
| Exclude role IDs | `29`, `30` | device roles, devices |
| Static-device role IDs | `6`, `7`, `18`, `27` | on-demand rack fillers (blank plate, cable management, patch panel, shelf) |

Changing these is configuration, not a code edit. A Settings UI comes later.

## Forced resync

Settings → Database → **Sync Data**. That is a full pull. There is no incremental changelog pass yet (P3).

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
