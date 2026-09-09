---
name: xcode-commit-hygiene
description: >
  Before every git commit in Pulse, restore Xcode project rewrites and keep
  Team IDs out of git. Use when committing, staging Pulse.xcodeproj,
  Archiving, Signing & Capabilities, DEVELOPMENT_TEAM, Development.xcconfig,
  or when the user runs /xcode-commit-hygiene.
---

# Xcode commit hygiene (Pulse)

Run this **before** `git add` / `git commit` in this repo. Xcode Automatic
signing rewrites `Pulse.xcodeproj/project.pbxproj` on Archive and on the
Signing tab (`objectVersion` 56→60, file-list shuffle, literal Team ID).

The mechanical gate is `.githooks/pre-commit`. Enable it:

```bash
git config core.hooksPath .githooks
```

## Before staging

1. If `project.pbxproj` is dirty **and** the diff is Xcode churn (Team ID
   literal, `objectVersion` bump, mass file-ref reorder) with no intended
   project-setting change:

   ```bash
   git checkout -- Pulse.xcodeproj/project.pbxproj
   ```

2. Never stage `Development.xcconfig` (gitignored). Team ID, bundle ID,
   and App Store version/build live there only.

3. `DEVELOPMENT_TEAM` must not appear as a 10-character Team ID in
   `*.pbxproj`, `*.plist`, or `*.entitlements`. Omit the key (xcconfig
   supplies it) or keep `$(DEVELOPMENT_TEAM)`.

4. Refuse `*.xcuserstate`, `xcuserdata/`, `Pulse/Products.storekit`.

## Real pbxproj edits

Intended setting changes (encryption key, incoming network, `$(MARKETING_VERSION)`)
are fine. After editing, grep the staged diff:

```bash
git diff --cached -U0 -- '*.pbxproj' '*.plist' '*.entitlements' \
  | grep -E '^\+' | grep -E 'DEVELOPMENT_TEAM = [A-Z0-9]{10}' && echo FAIL
```

If that matches, restore and restage. Do not commit the rewrite “to make Archive work”; signing already reads the local xcconfig.
