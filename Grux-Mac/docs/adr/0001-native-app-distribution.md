# ADR 0001: Native App Distribution, Not Server Containers

**Status:** accepted
**Author:** Claude
**Date:** 2026-06-09

---

## Context

Some ambient-AI projects (the Odysseus model) ship as Docker containers on GPU servers: the assistant lives in the cloud, clients are thin, and deployment looks like any other web service. We had to decide whether Grux follows that model or ships as native apps.

Grux is an OS-level ambient assistant. Its job is to see and act on your actual machine: listen on the mic, watch the screen, drive other apps, speak, and run shell work where the files live.

## Decision

Grux ships as a code-signed native macOS app (Swift, Developer ID, team `<your-team-id>`) plus a native SwiftUI iOS companion (`com.dcj.gruxphone`). There is no Docker image, no GPU server deployment, and no hosted multi-tenant variant. Server-style deployment is explicitly out of scope.

## Why native is correct here

1. **TCC permissions only flow to signed native apps.** Microphone, screen recording, and accessibility (the three capabilities Grux is built on) are granted by macOS per signed bundle ID. A container has no path to them; a helper process inherits nothing. The permission grants ARE the product surface.
2. **Metal and the Neural Engine are local hardware.** On-device inference (Whisper, embeddings, local models) runs on Apple Silicon via Metal/ANE for free, with no per-token cloud cost and no audio leaving the machine. A GPU server reintroduces both.
3. **Keychain is the secret store.** Pairing keys, API keys, and the wire-protocol key material (X25519, ChaCha20-Poly1305) live in the user's Keychain, gated by code signature. No env-var sprawl, no secrets volume.
4. **Login items and launchd give ambient persistence.** Grux starts at login and stays resident as a first-class citizen of the user session. A container would still need a native agent on the Mac to do anything useful, at which point the container is overhead.
5. **Latency and privacy.** Screen frames and mic audio never cross the network for local features. Round-tripping them to a server adds latency and a data-handling liability we do not want.

## What we give up

- No horizontal scaling, no fleet orchestration, no `docker pull` upgrade path. Acceptable: Grux is single-user by design (your Mac, your iPhone).
- Updates require building, signing, and installing a new binary. Mitigated by `build.sh` and the deploy-freely rule for Grux.
- Frontier-model calls still go out over the network, but as outbound API calls from the app, not as an inference server we operate.

## Consequences

- All new Grux capabilities are designed Mac-first against native APIs (AVFoundation, ScreenCaptureKit, AXUIElement, AppKit), not against a containerizable abstraction.
- The iOS companion stays native SwiftUI per the global hard rule. No WebView shells.
- Any future "Grux for someone else's machine" is a new signed app install, not a tenant on a server. If that ever changes, it gets a new ADR.
