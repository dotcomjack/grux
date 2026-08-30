# WS-G: fal.ai media routing (Creative engine)

fal.ai is now the DEFAULT provider for generated media in Grux's Creative
engine. The image service (the Mini `:3847`) stays authoritative for product-in-scene
renders. This file is the integration hand-off: the one UI snippet the owner of
`SettingsView.swift` needs to paste, plus how ops seeds the key at launch.

## What shipped

- `FalClient` (actor) speaks the fal queue API: submit `POST https://queue.fal.run/<model>`, poll status (1s interval, 120s ceiling), fetch the response, download every image URL to raw `Data`. Typed `FalError` (missingKey / http / timeout / decoding). Emits exactly one PostHog `$ai_generation` per call (provider `"fal"`, span `creative.fal-image`).
- `CreativeEngine.runDynamic` routes: a directive with **no sku and no reference** goes to fal first; **anything with a sku or reference** stays byte-identical on the Mini `:3847`. On any fal failure it logs a `WakeLog`, tracks `ai_fallback_used {feature, from:"fal", to:"image-service", brand}`, and degrades to the Mini path (today's behavior).
- The per-brand model bandit (`FeedbackStore`) now arbitrates across providers: `ModelLadder.image` gained `fal-ai/flux/dev` at about `$0.03` per image (estimated). The Mini path clamps to `ModelLadder.miniImage` so `:3847` only ever receives a qwen model.
- Model override: set `GRUX_FAL_IMAGE_MODEL` to point Grux at a different fal model (read at call time, no rebuild). Default is `fal-ai/flux/dev`.

## Owner action: fal key SecureField in SettingsView

Grux reads the fal key from the Keychain, never from a file on disk.
Add a fal key field alongside the ElevenLabs / Brave patterns. Drop a
`@State private var falKey = ""` and `@State private var showFalKey = false`
next to the other key state vars, load it in the settings loader with
`falKey = KeychainStore.get(.falApiKey)`, then add this Section (models the
Brave pattern at `SettingsView.swift:926`):

```swift
if sectionVisible("data.fal") {
    Section("fal.ai media") {
        HStack {
            Text("fal.ai API key").font(.caption).frame(width: 110, alignment: .leading)
            if showFalKey {
                TextField("fal-…", text: $falKey).textFieldStyle(.roundedBorder)
            } else {
                SecureField("fal-…", text: $falKey).textFieldStyle(.roundedBorder)
            }
            Button(showFalKey ? "Hide" : "Show") { showFalKey.toggle() }
                .buttonStyle(.borderless).font(.caption)
            Button("Save") {
                _ = KeychainStore.set(.falApiKey, falKey.trimmingCharacters(in: .whitespacesAndNewlines))
                savedAt = Date()
            }
            .buttonStyle(.borderless).font(.caption)
        }
        Text("Default provider for generated media in Creative Studio. Empty = the fal path degrades to the image service :3847.")
            .font(.caption).foregroundStyle(.secondary)
        Link("Get a fal.ai key →", destination: URL(string: "https://fal.ai/dashboard/keys")!)
            .font(.caption)
    }
    .id("data.fal")
}
```

If `SettingsView` uses a search registry (`SettingsSearchRegistry`), register a
`data.fal` entry so the section is reachable from settings search, matching how
`data.web` (Brave) is registered.

## Ops: seed the key at launch (no Settings round-trip)

Export `GRUX_FAL_KEY` before Grux launches. `KeychainMigrator.runOnce()` seeds
the Keychain from it once, best-effort, and `FalClient` also honors the env var
directly as a fallback, so a headless verification run works with only the env
set. The value is never logged and never written to source or config.

## Residual gaps

- **Video / motion via fal is DEFERRED.** `FalClient` implements the image path only. Video generation still routes through the Mini `/api/images/render-video` (`wan` i2v). Adding fal video is a follow-up: a `generateVideo` method on `FalClient` (same submit/poll/fetch shape, `result["video"]["url"]`), a `VideoLadder`, and a branch in the animate path. Left out to keep this workstream image-scoped and the diff bounded.
- **No live-network integration test.** Per the workstream gate, tests are pure parsing / mapping only. A live smoke (real key, one 1:1 image) should be run manually once the SettingsView field lands.
- The cross-provider bandit records fal ratings but the fal render path itself always uses `FalModels.imageModel()` (env or default), not the bandit's pick; provider selection is by sku/reference, not by the bandit. If future work wants the bandit to choose fal-vs-Mini, that routing lives in `runDynamic`.
