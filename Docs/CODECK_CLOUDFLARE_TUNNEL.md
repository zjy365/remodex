# Codeck Remote Cloudflare Tunnel Service

## Goal

Run Codeck Remote as a stable local macOS service while exposing the relay through Cloudflare Tunnel, so the iPhone is not limited to the same LAN.

Target path:

```text
iPhone -> Cloudflare hostname -> cloudflared on Mac -> 127.0.0.1:9000 local relay -> Mac bridge -> local codex app-server
```

Cloudflare Tunnel creates outbound connections from `cloudflared` to Cloudflare, so this setup does not require router port forwarding or opening inbound firewall ports.

## Prerequisites

- A domain added to Cloudflare DNS.
- `cloudflared` installed on the Mac.
- The Xcode-built `Codeck Remote` app already installed on the iPhone.
- This repo checked out at `/Users/jingyang/work/remodex`.

Check local tools:

```bash
cloudflared --version
```

## One-Time Cloudflare Setup

Authenticate cloudflared:

```bash
cloudflared tunnel login
```

Create a named tunnel:

```bash
cloudflared tunnel create codeck-remote
```

Create the DNS route. Replace `codeck.example.com` with your real Cloudflare-managed hostname:

```bash
cloudflared tunnel route dns codeck-remote codeck.example.com
```

## Install Stable Local Services

From the repo root:

```bash
cd /Users/jingyang/work/remodex
scripts/codeck-remote-service.sh install --hostname codeck.example.com --tunnel codeck-remote
```

This writes:

- `~/.cloudflared/codeck-remote.yml`
- `~/Library/LaunchAgents/com.jingyang.codeck.remote.local.plist`
- `~/Library/LaunchAgents/com.jingyang.codeck.remote.cloudflared.plist`

The local LaunchAgent runs:

```bash
./run-local-remodex.sh --relay-url wss://codeck.example.com/relay --bind-host 127.0.0.1 --port 9000
```

The cloudflared LaunchAgent proxies the public hostname to:

```text
http://127.0.0.1:9000
```

## Pair The iPhone

Tail the local service logs to find the QR code:

```bash
scripts/codeck-remote-service.sh logs local
```

Scan the QR from Codeck Remote. The pairing payload should advertise:

```text
wss://codeck.example.com/relay
```

After the first pairing, trusted reconnect should work as long as the Mac is awake and both LaunchAgents are running.

## Service Operations

Check status:

```bash
scripts/codeck-remote-service.sh status
```

Tail logs:

```bash
scripts/codeck-remote-service.sh logs all
```

Restart:

```bash
scripts/codeck-remote-service.sh restart
```

Stop:

```bash
scripts/codeck-remote-service.sh stop
```

Start again:

```bash
scripts/codeck-remote-service.sh start
```

Uninstall local LaunchAgents:

```bash
scripts/codeck-remote-service.sh uninstall
```

This does not delete the Cloudflare tunnel or DNS route. Delete those with `cloudflared` or the Cloudflare dashboard if needed.

## Verification

Use the phone off Wi-Fi, on cellular data:

- Codeck Remote reconnects.
- Sending a prompt streams output back.
- The Mac local service logs show bridge activity.
- `cloudflared` logs do not show repeated origin connection failures.

If cellular reconnect fails, check:

```bash
scripts/codeck-remote-service.sh logs cloudflared
```

Common causes:

- The DNS route points at a different tunnel.
- The tunnel is not running.
- The public hostname is not managed by Cloudflare DNS.
- The local relay service is down on `127.0.0.1:9000`.
- The Mac is asleep.

## Security Notes

- The local relay only binds to `127.0.0.1` in the LaunchAgent setup.
- The public hostname should be treated as a private control surface, even though pairing uses bearer-like session material.
- Do not log or share live QR payloads, relay session IDs, or pairing identifiers.
- For stronger access control, add Cloudflare Access in front of the hostname in a later pass. That may require verifying whether the iOS WebSocket client can handle the selected Access flow.
