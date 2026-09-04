# Pulse user guide

This guide covers day-to-day operation of Pulse: connecting your data sources, navigating the app, monitoring infrastructure, and connecting to devices over SSH. For installation and build setup see the [README](../README.md). For the SSH credential model in depth see the [SSH credentials guide](credentials.md).

Pulse is local-first: all data lives on your device, sourced live from your own NetBox and Zabbix servers. Nothing is sent to a cloud service.

## 1. First run: connect your data sources

Pulse reads infrastructure inventory from NetBox and monitoring status from Zabbix. Configure both in Settings.

- **macOS:** open **Pulse menu > Settings** (Cmd-,). The window has tabs: **Settings** (subscription meter, NetBox + Zabbix), **Roles**, **PowerSense**, **SSH**, **Web Trust**, and **Database**.
- **iOS / iPadOS:** open Settings from the main sheet. **Subscription**, **Device Roles**, and **Database** are under NetBox.

In the **Settings** tab:

1. Under **NetBox Settings**, enter your NetBox **API Server** URL (for example `https://netbox.example.com`) and **API Token**.
2. Under **Zabbix Settings**, enter the Zabbix **API Server** URL, **API User**, and **API Token**. Zabbix is optional but recommended for live monitoring.
3. Click **Apply Settings**. Pulse validates the connection and begins syncing.

The first sync pulls sites, devices, roles, and types from NetBox. Later launches refresh in the background.

Live monitoring needs a NetBox **custom field** on each device: slug `zabbix_id`, integer, set to that host's Zabbix id. Pulse does not create the field. Devices without it still sync from NetBox; they have no charts or problems. See [NetBox sync](netbox-sync.md#custom-fields-zabbix-host-id).

### Device Roles

Pulse stores every device NetBox has. What you see is controlled in **Settings → Roles** (macOS) or **Settings → Device Roles** (iOS). These toggles never change the NetBox pull and never delete local rows.

| Column | Purpose |
|---|---|
| **Site graph** | Show this role as a node on the site topology. Patch panels and blanks are usually off. |
| **Device list** | Show this role in the site device list. |
| **In rack** | Draw this role in the rack elevation at its U position. Off leaves that space empty. |
| **As hardware** | Draw it as rack hardware (panel, blank, shelf) instead of a named device with severity colour. |
| **No monitoring** | Do not pull Zabbix items for this role. Use this when the role has no telemetry. |

There is no License checkbox. What counts toward a seat is explained once: the (i) next to **Seats** in Settings.

### Subscription seats

Pulse is free for 50 devices that count toward a seat, then Growth 250, Pro 1,500, Unlimited none. Sync still stores every device. Unseated devices stay visible; writes, SSH, Web, rack Save, Connect/Disconnect, and Zabbix updates (`event.acknowledge`) stay off. Rack hardware (blanks, panels, shelves) is not billed and can still be moved. The Zabbix feed still lands so lists and charts stay current.

The Settings meter shows `seated of cap`. Subscribe or Restore Purchases from that section. Moving to a larger plan takes effect immediately. Moving to a smaller plan waits until the current period ends (Settings shows the date). Missed payment after the App Store grace period drops you to Free and keeps the oldest 50 seats. A refund or revocation takes effect immediately.

A Full Resync is required after upgrading to this unfiltered pull, so Generic types and previously omitted devices appear.

## 2. Navigating Pulse

Pulse presents your infrastructure at three zoom levels:

- **Map view** shows sites geographically. Use it to gauge regional scope during an outage and to jump into a site.
- **Site view** shows a single site's topology: devices, racks, and their connections, with live monitoring status.
- **Device view** shows one device in detail: interfaces, monitoring charts, events, and (where available) a live camera feed.

Selecting a site on the map opens its Site view; selecting a device opens its Device view.

## 3. Monitoring and alerts

With Zabbix configured, Pulse colours every device by its current severity and surfaces events:

- Device and site colours reflect the highest active Zabbix severity.
- Events and problems are listed per device; historical patterns are charted in Device view.
- Notifications are dispatched **locally** from background polling. There is no cloud push; alerts are generated on-device.

## 4. Connecting to a device over SSH (macOS)

Pulse includes an operator SSH terminal backed by the device's Secure Enclave. First create at least one SSH credential in **Settings > SSH**; see the [SSH credentials guide](credentials.md) for credential tiers, biometric gating, and the bundle / team-ID coupling.

**Open a terminal:**

1. Right-click a device row (or a device node in the site topology) and choose **Open SSH Terminal**. The item is enabled only when the device has a primary IP recorded in NetBox.
2. A connect form appears: confirm the target `host:port`, enter a **username**, and pick a **credential**. Connect stays disabled until both are set (there is no silent default, by design).
3. Optionally tick **Save as default for this device** to skip the form on future connections once this one succeeds.
4. Click **Connect**. The first connection of an app session prompts for biometrics: once to sign the SSH handshake, and again to unwrap the recording key if recording is enabled on the credential.

**Host-key trust.** The first connection pins the server's host key (trust on first use). If a later connection presents a different key, Pulse shows a mismatch sheet with three choices: pin the new key, distrust it, or cancel. The sheet defaults to the safe (reject) option and times out to a rejection after 90 seconds.

**While connected.** The window toolbar shows a status pill (Connecting / Connected / Disconnected / Failed) and, if the credential records sessions, a red **Recording** badge. An in-view strip shows the live `host:port`. The toolbar's primary action is **Disconnect** while connected and **Reconnect** once the session ends. Closing the window tears down the session.

**Session recording.** When enabled per credential, every session is written to an encrypted, hash-chained log on disk and can be replayed (behind a biometric prompt) from the Debug menu. See [session recording](credentials.md#session-recording) for the lifecycle and the [architecture ADR](architecture/0001-ssh-terminal-and-web-foundations.md) for the security model.

> The SSH terminal UI ships on macOS today. The underlying engine (credentials, transport, recording) is platform-agnostic; iOS surfacing is tracked for a later release.

**Opening a device's web UI.** Right-click a device and choose **Open Web UI** to render its web interface (Proxmox, OPNsense, an appliance console) inside Pulse. The option appears only when NetBox declares an HTTP or HTTPS service for the device; the scheme and port come from that NetBox service. A self-signed certificate prompts you to trust it on first sight, and the page stays contained to that device. See the [Web companion guide](web-companion.md) for the service rule and the certificate-trust prompt.

## 5. Terminal preferences

A few terminal preferences (audible / visual bell, font size) are stored as app defaults; there is no dedicated settings pane yet. See [terminal preferences](credentials.md#terminal-preferences) for the keys and how to change them (`defaults write com.yourorg.pulse ...`, or the in-window Cmd +/-/0 shortcuts on macOS and pinch-to-zoom on iOS).

## 6. Settings reference

| Tab | What it configures |
|---|---|
| Settings | NetBox and Zabbix API endpoints and tokens |
| Roles | Per-role visibility, rack drawing, and monitoring. License count is derived from those surfaces. See [Device Roles](#device-roles). |
| PowerSense | Optional grid-power telemetry integration |
| SSH | SSH credentials (generate Secure Enclave or import portable keys) and per-credential session recording |
| Web Trust | Pinned and blocked hosts for Device Web |
| Database | Local data-store counts and maintenance |

## 7. Troubleshooting

- **NetBox or Zabbix connection fails:** re-check the API server URL (including the scheme) and token in Settings, and confirm the host is reachable from your network.
- **SSH connect fails:** confirm the device has a primary IP in NetBox, the username is correct, and the credential's public key is enrolled on the server (`~/.ssh/authorized_keys`). The connect form re-appears with the failure reason so you can fix the field and retry.
- **Host-key mismatch sheet keeps appearing:** the server's key changed (or the pin was Forgotten). Accept the new key only if you expect the change.
- **Inspect audit logs:** Pulse emits structured events under the `pulse` subsystem. On macOS: `log show --predicate 'subsystem == "pulse"' --last 1h`. SSH events use categories beginning `ssh.`.

## Getting help

- [README](../README.md) for installation and build setup.
- [SSH credentials guide](credentials.md) for the credential and recording model.
- [Web companion guide](web-companion.md) for the device web window and its certificate-trust prompt.
- [SSH and web foundations](architecture/0001-ssh-terminal-and-web-foundations.md): credential, trust, and session-recording model.
- The project [Wiki](https://github.com/omega-networks/pulse/wiki) and issue tracker for anything else.
