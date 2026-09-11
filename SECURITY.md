# Security Policy

Pulse handles material worth protecting: SSH credentials backed by the Secure Enclave, encrypted session recordings, NetBox and Zabbix API tokens, and an inventory of critical infrastructure. We take reports against any of that surface seriously.

## Reporting a vulnerability

Please report suspected vulnerabilities privately — do not open a public issue.

- Preferred: GitHub's private vulnerability reporting on this repository (**Security → Report a vulnerability**).
- Alternatively: email **innovate@omega.net.nz** with "SECURITY" in the subject line.

Include what you can: affected component (SSH, session logging, web companion, NetBox/Zabbix sync), reproduction steps, impact as you understand it, and the commit or release you tested. We will acknowledge within 5 working days, keep you informed as we investigate, and credit you in the fix's release notes unless you ask otherwise.

Please give us a reasonable window to ship a fix before public disclosure.

## What not to include

Never paste API tokens, SSH private keys, session recordings, or hostnames/addresses of real infrastructure into an issue, discussion, or report — yours or anyone else's. Redact first; a proof of concept against a lab instance is always preferred.

## Scope notes

- Pulse is a local-first client: it stores data on-device only and talks solely to the NetBox/Zabbix servers the operator configures. There is no Omega-operated backend to test.
- Findings against your own NetBox or Zabbix deployment belong upstream with those projects — but if Pulse *mishandles* a server response (crashes, leaks a token, renders untrusted content), that is in scope here.
- The `NetBoxAPI/Sources` files are generated from the NetBox OpenAPI schema; report issues in how Pulse generates or uses them here, and defects in the schema itself upstream to NetBox.

## Supported versions

Security fixes land on `main` and the most recent tagged release. Older tags are not patched retroactively.
