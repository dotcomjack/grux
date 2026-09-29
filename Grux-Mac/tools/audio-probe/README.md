# Audio probe rig

Six small programs that answer one question with a number instead of a
comment: **what does holding the microphone actually cost the rest of the
Mac?**

They live in the repository for the same reason the UI verification harness
does. They spent one session in `/tmp`, produced the measurements that
overturned a claim this codebase had repeated for months, and `/tmp` does not
survive a reboot. A measurement tool that evaporates gets rewritten from
memory, and the memory loses the traps.

Everything is stdlib and system frameworks. Nothing here is built by
`swift build`; compile a probe when you need it:

```
swiftc -O tonetest.swift -o tonetest
```

## What each one is for

| Probe | Question it answers |
|---|---|
| `holdvpio.swift` | Holds VoiceProcessingIO for N seconds. The thing under test. Prints frames delivered, so a run that proves nothing says so. |
| `tonetest.swift` | Plays tones through the default output, captures them, and reports per-frequency power with a Goertzel. `--tone=low\|high\|both\|none`. |
| `playback.swift` | Plays a tone and NEVER opens the microphone. Counts `AVAudioEngineConfigurationChange`. Answers "is a playback-only app disturbed". |
| `dropout.swift` | Captures continuously and prints a 250ms RMS envelope, so a capture that dies shows the moment it died. |
| `arm.sh` | The real-app A/B. Records the microphone with `ffmpeg` while Grux launches, then reports what the recorder captured. |
| `wavstat.py` | Reads a WAV and prints its envelope and silent-window count. |
| `latency.sh` | Speaks commands and measures last syllable to command executed, from Grux's own log. |

## The measurements these produced, 2026-09-23

Run on macOS 26, built-in speakers and microphone. Reproduce before quoting.

**Output fidelity is NOT affected by voice processing.** The claim that it
drops system output to a narrow-band call codec was repeated in this app's
settings, in its consent dialog and in its own source comments, and had never
been measured:

- A high tone played while a separate process held VPIO came back far above
  the silence floor, and the output device's format did not change.
- Controls: playing the low tone alone left the high bin at the noise floor,
  which proves the bins are independent; and the holder reported its delivered
  frame count, which proves VPIO was genuinely running.
- `playback.swift` saw zero configuration changes and ran its buffer to
  completion while VPIO came up and went away underneath it.

**What it DOES cost is another app's microphone.** `arm.sh` with `ffmpeg`
recording, across two builds of the real app:

| | VPIO enabled | VPIO bypassed |
|---|---|---|
| silent 250ms windows | 37 of 82 | 0 of 81 |
| behaviour | died part way and never recovered | steady for the whole take |

**NOT TESTED: Bluetooth output.** The classic narrow-band downgrade is the
A2DP to HFP switch on a Bluetooth link and it needs the headphones connected
to reproduce. Do not extend the conclusion above to Bluetooth.

## Two traps

**A probe that returns nothing is broken until proven otherwise.** Every probe
here reports how much data it received, because an early version reported "0
frames" and read as a dead audio system when it was a missing permission.

**Read the hottest channel, not channel 0.** A multichannel input routes the
real microphone to one channel and leaves the rest silent, so a naive channel-0
read measures silence and reports a bug that is not there. `tonetest` and
`dropout` both pick the highest-energy channel, the same way the ambient
listener does.
