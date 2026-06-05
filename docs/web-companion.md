# Device Web companion

Operator guide to opening a device's web UI inside Pulse. For the architecture, see [ADR 0001](architecture/0001-ssh-terminal-and-web-foundations.md); the SSH terminal has its own guide in [credentials.md](credentials.md).

The Web companion is a second operator window, a sibling to the SSH terminal. It renders a device's management web UI (Proxmox, OPNsense, a backup server, an appliance console) inside Pulse, so you do not leave the app to reach a device's browser interface.

## Opening a device's web UI

Right-click a device (in the site list or the topology graph) and choose **Open Web UI**. The window opens for that device and loads its web interface.

The **Open Web UI** option appears only when NetBox declares a web service for the device (see below). If it is absent, the device has no HTTP or HTTPS service defined in NetBox.

The first time Pulse reaches a device on your local network, macOS asks whether Pulse may access local network devices. Grant it, or the page fails to load with a "could not connect" error (`NSURLErrorCannotConnectToHost`, -1004). You can change this later in **System Settings > Privacy & Security > Local Network**.

Appliances reached by a routed or public IP work too: Pulse relaxes App Transport Security for the web window's content only, so a self-signed certificate on a public host can load once you accept it, while the app's own NetBox and Zabbix traffic stays under standard ATS. You still get the trust prompt for any untrusted certificate.

## How Pulse picks the URL: NetBox is the source of truth

Pulse does not guess a device's web address. It reads the device's **NetBox Application Services** (IPAM > Services) and opens what NetBox declares:

- The **scheme** comes from the service name. A TCP service whose name contains `HTTPS` opens over `https`; a name containing `HTTP` opens over `http`.
- The **port** is the service's own declared port.
- The **address** is the service's IP, with any CIDR mask stripped.

So a service named `HTTPS` on port `8006` opens `https://<device-ip>:8006/`. If a device has several web services, Pulse prefers `https` over `http`, then the lowest port.

If a device's web UI does not open, the fix is in NetBox: define an `HTTP` or `HTTPS` service on the device with the right port. Pulse surfaces exactly what the source of truth says.

## The certificate trust prompt

Many appliances serve their web UI over a self-signed or otherwise untrusted certificate. Pulse handles this with a per-host, operator-acknowledged trust decision. It never disables certificate checking globally.

- **Trusted certificates load silently.** If the device's certificate chains to a trusted authority (a public or corporate CA your Mac already trusts), the page loads with no prompt.
- **An untrusted certificate prompts you on first sight.** You see the host, the reason it is untrusted, and the certificate's SHA-256 fingerprint. Choose **Trust** to proceed (Pulse pins that certificate for this host) or **Cancel** to abort. The prompt focuses **Cancel** by default, so a stray Return key never extends trust.
- **A changed certificate prompts a mismatch.** If a host you previously trusted later presents a different certificate, Pulse shows the stored and presented fingerprints side by side and when you first trusted it. Choose **Accept** (a legitimate rotation, re-pins), **Reject** (abort, keep the old pin), or **Forget** (drop the pin; the next connection is a fresh first sight).
- **The prompt times out after 90 seconds.** If you do not decide, Pulse rejects the connection. This matches the SSH host-key prompt.

Accepting a certificate means: for this host and port, Pulse will load that exact certificate silently from now on, and will prompt you again only if it changes.

## Reviewing and editing trusted hosts

Open **Settings > Web Trust** to see every device-web host you have trusted or blocked, on this device only. Each entry shows the `host:port`, its status, the pinned certificate fingerprint, and when it was first seen and last verified.

- **Forget** removes a pinned certificate. The next time you open that host you get a fresh first-sight prompt, exactly as if you had never trusted it.
- **Block** marks a host as explicitly distrusted. Pulse then refuses to load it (with no prompt) until you unblock it. Use this for a host you never want the app to reach.
- **Unblock** drops the block, so the next visit is a fresh first-sight prompt again.

A declined first-sight prompt is not the same as a block: declining cancels that one attempt and stores nothing, so the host prompts again next time. Only **Block** records a standing refusal.

## Navigation stays on the device

In-app navigation is contained to the device you opened. Links to the same host, port, and scheme load in the window. A link to any other origin is handed to your system browser instead of navigating away inside Pulse, so the window always shows the device you opened. The current address is shown beneath the page.

## New windows and pop-ups

The web window does not open new windows or pop-ups. When a page calls `window.open` (appliance consoles such as noVNC or a serial console, and some "open in new tab" buttons), the platform web API Pulse is built on gives no way to host or redirect that request, so it does not open. This is tracked and will be revisited if the platform gains the capability.

For an interactive console, use the built-in SSH terminal, which is the supported path. Foreign links followed inside the page still open in your system browser, as described above; only new windows are affected.

## Downloads

Downloading files from a device's web UI (firmware images, config backups, logs, certificates) is not yet supported in the web window. The native API Pulse needs to save a download has not shipped in the current OS, so the capability is deferred and tracked, and will be revisited. Until then, pull files using the built-in SSH terminal, or open the device in a desktop browser.

## Where trust is stored

TLS trust is stored on-device in Pulse's local database, keyed by host and port, separate from SSH host-key trust. Forgetting a device's TLS trust does not touch its SSH host-key trust, and vice versa. As with the rest of Pulse, nothing syncs to iCloud.

## Audit

Trust and session events are logged under the `pulse` subsystem, categories `web.trust` and `web.session`:

```bash
log show --predicate 'subsystem == "pulse" AND category BEGINSWITH "web"' --last 1h
```

Events include `web.trust.system` (loaded a trusted certificate), `web.trust.pinned` (trusted on first sight), `web.trust.accepted` (accepted a rotation), `web.trust.rejected` (with a reason such as `decision_timeout`), `web.trust.forgotten`, `web.trust.distrusted` (an operator blocked a host from Settings), `web.session.opened`, and `web.session.navigation_blocked`.

## Lab procedure

End-to-end verification against a self-signed appliance:

1. In NetBox, give a test device an `HTTPS` service on its management port (for example `8006` for Proxmox), with the device's IP.
2. Sync Pulse so the service appears.
3. Right-click the device and choose **Open Web UI**. The window opens and a trust prompt appears showing the certificate fingerprint.
4. Choose **Trust**. The page loads. Confirm the address strip shows the expected `host:port`.
5. Close and reopen the window. The page loads with no prompt (the certificate is pinned).
6. Re-key the appliance (or point the service at a different self-signed host). Reopen. Confirm the mismatch prompt shows the stored and presented fingerprints, and that **Reject** aborts while **Accept** re-pins.
7. Click a link to an external site. Confirm it opens in your system browser, not in the Pulse window.

## A note on certificate key size

A self-signed appliance that serves a large RSA key (for example 4096-bit) completes its TLS handshake noticeably slower than a 2048-bit one, and a web UI that opens many connections at once multiplies that cost. This is a property of the appliance's certificate, not of Pulse: once trusted, the host loads fine, it just handshakes slower. After you accept a certificate, Pulse loads the page in a single navigation (it does not reload on top of the accepted load), so the handshake cost is paid once rather than twice.

## Related

- [ADR 0001](architecture/0001-ssh-terminal-and-web-foundations.md) for the architecture and the trust model.
- [credentials.md](credentials.md) for the SSH terminal and its host-key trust, which the Web companion mirrors.
