# Codeck Remote: Remodex Direct Install Plan

## Summary

This fork turns Remodex into a local-first, self-hosted iPhone companion app named Codeck Remote. The first version is for personal Xcode direct install only: no TestFlight, no App Store release, no Expo rewrite, no Remodex hosted relay, and no RevenueCat/paywall/free-send limit. The Mac side remains the local relay plus bridge, with the iPhone pairing to the user's own Mac Codex runtime by QR code.

## Key Changes

- App display name: `Codeck Remote`.
- iOS bundle id: `com.jingyang.codeck.remote`.
- URL scheme: `codeck`.
- Permission copy uses `Codeck Remote`.
- Existing app icon remains a temporary placeholder for the first private build.
- RevenueCat config is blank in shared build settings.
- Self-hosted direct-install mode grants app access locally without Pro entitlement checks.
- Push notification and Sign in with Apple entitlements are removed from the first direct-install build to keep free Apple ID signing simple.

## Local Runtime

Start the Mac relay and bridge from the repo root:

```bash
./run-local-remodex.sh --hostname <Mac LAN IP>
```

Then scan the terminal QR code from Codeck Remote on the iPhone.

Data path:

```text
iPhone -> local relay -> Mac bridge -> codex app-server
```

## Relay / CLI Notes

On this machine, `remodex` resolves to the globally installed npm package, not a local script in this source checkout:

```bash
which remodex
# /Users/jingyang/.local/state/fnm_multishells/3494_1778297936909/bin/remodex

readlink "$(which remodex)"
# ../lib/node_modules/remodex/bin/remodex.js
```

Because of that, `remodex up` may use defaults from the published npm package. In the current Remodex bridge config flow, a source checkout defaults the relay to empty, while a published package may read `src/private-defaults.json` and pick up a bundled default relay.

For the first direct-install phase, do not use global `remodex up` for self-hosted validation. Use the source checkout script instead:

```bash
cd /Users/jingyang/work/remodex
./run-local-remodex.sh --hostname <Mac LAN IP>
```

That script starts the local relay and sets the bridge relay URL to a local WebSocket endpoint such as:

```text
ws://<Mac LAN IP>:9000/relay
```

The first acceptance target is the local chain: the Xcode-built iPhone app can scan the script's QR code, send a message, and receive Codex output through `iPhone -> local relay -> Mac bridge -> local codex app-server`. Fully cleaning up hosted relay defaults in the published CLI path is deferred to a later branding/self-hosting pass.

## Xcode Install

1. Open `/Users/jingyang/work/remodex/CodexMobile/CodexMobile.xcodeproj`.
2. Select the `CodexMobile` scheme and the target iPhone.
3. In Signing & Capabilities, choose the Apple ID team.
4. Run to the device.

With a free Apple ID, direct-installed apps commonly need re-signing after about 7 days.

## Test Plan

- Xcode Debug installs successfully on the iPhone.
- The iPhone home screen shows `Codeck Remote`.
- App launch does not show Pro, paywall, or free-send UI.
- RevenueCat missing config does not block the main flow.
- `./run-local-remodex.sh --hostname <Mac LAN IP>` starts relay plus bridge.
- QR pairing succeeds.
- Relaunch reconnect works when the local host session is still valid.
- Sending more than 5 messages is not blocked.
- Streaming output, approvals, git status, and git diff still work through the local bridge.

## Assumptions

- This build is private and self-installed only.
- The upstream Apache-2.0 license and attribution stay intact.
- Full public rebrand work, replacement icons, NOTICE updates, and distribution hardening are deferred until any external release.
