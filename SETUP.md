# ControlBooth Setup

ControlBooth is the unsandboxed companion to AntennaHead. It runs user-defined
process pipelines (tool → tool via stdin/stdout, e.g. `nrsc5 → sox`) and always
appends `PCMUDPSender --host <h> --port <p> --exit-with-parent` as the final
stage, delivering raw S16LE PCM to AntennaHead over UDP. On the AntennaHead
side, a custom task (`PCMUDPReceiver --port 6019` → sox) receives the audio and
forwards it to LiveAudioServer — the same pattern used for nrsc5 today, minus
the manual terminal work.

Because ControlBooth is **not sandboxed** (`ENABLE_APP_SANDBOX = NO`), pipeline
stages can be any executable on disk — unsigned Homebrew tools included.

## One-time Xcode wiring (manual)

The Swift sources live in buildable folders and are picked up automatically.
Two package dependencies and one build phase must be added by hand:

1. **GRDB** — Project → ControlBooth → Package Dependencies → **+** →
   search `https://github.com/groue/GRDB.swift` → Add Package → add the
   **GRDB** library product to the ControlBooth target.

2. **PipelineHelpers (local package)** — Package Dependencies → **+** →
   **Add Local…** → select
   `…/Claude working directory/PipelineHelpers`.
   When prompted for products, add the **PipelineRunner** library to the
   ControlBooth target (it provides `TaskPipelineManager`/`TaskItem`, which
   are no longer copied into this repo). The executable products need no
   target membership — the Copy Files phase below builds and embeds them.

3. **Copy Files phase** — ControlBooth target → Build Phases → **+** →
   New Copy Files Phase:
   - Destination: **Wrapper**
   - Subpath: `Contents/Helpers`
   - **+** → add the **PCMUDPSender** product (from the local package).

That's it — build and run.

## Audio contract

Every path into AntennaHead's LiveAudioServer is 48 kHz / 2-channel S16LE.
ControlBooth pipelines should end (before the auto-appended sender) with a sox
stage producing `-r 48000 -e signed-integer -b 16 -c 2 -t raw -`, and the
receiving AntennaHead custom task should be configured for 48000 Hz / 2 ch.

Sources with no real-time clock (file readers, generators) will flood UDP —
use a self-pacing source such as `PCMSpeechSynth` for testing, or a real-time
decoder (nrsc5, rtl_fm) for production.

## Receiving side (AntennaHead)

Create a custom task in AntennaHead's web UI with stages:

| Stage | Tool             | Arguments                                                                                              |
|-------|------------------|--------------------------------------------------------------------------------------------------------|
| 1     | `PCMUDPReceiver` | `--port 6019`                                                                                            |

with the custom task's sample rate set to 48000 and channels to 2 (AntennaHead
appends its own sox normalization and PCMUDPSender → LiveAudioServer stages).

## AppleEvents control channel

ControlBooth and AntennaHead talk to each other over AppleEvents.

### ControlBooth receives (implemented)

`ControlBooth.sdef` declares a "ControlBooth Suite" (event class `CBth`),
handled by the `NSScriptCommand` subclasses in
`Services/ScriptingCommands.swift`:

| Command              | Code       | Direct parameter | Reply          |
|----------------------|------------|------------------|----------------|
| `start pipeline`     | `CBthStrt` | pipeline name    | —              |
| `stop pipeline`      | `CBthStop` | pipeline name    | —              |
| `stop all pipelines` | `CBthStpA` | —                | —              |
| `list pipelines`     | `CBthList` | —                | list of text   |
| `running pipelines`  | `CBthRuns` | —                | list of text   |

Testable from Script Editor:

```applescript
tell application "ControlBooth"
    start pipeline "Speech Test"
    running pipelines
end tell
```

Every command carries the access group `com.dsward.ControlBooth.pipelines`,
so the sandboxed AntennaHead can send them with either entitlement:

- `com.apple.security.automation.apple-events` = YES (plus an
  `NSAppleEventsUsageDescription` string; user consent prompt), or
- `com.apple.security.scripting-targets` =
  `{ "com.dsward.ControlBooth": ["com.dsward.ControlBooth.pipelines"] }`
  (no prompt).

### ControlBooth sends (implemented here, pending AntennaHead handlers)

`Services/AntennaHeadClient.swift` sends custom events (class `AntH`) to
`com.dsward.AntennaHead`:

| Event ID | Meaning                | Direct parameter | Reply          |
|----------|------------------------|------------------|----------------|
| `Strt`   | start listening task   | task name        | —              |
| `Stop`   | stop listening task    | task name        | —              |
| `Runs`   | listening task names   | —                | list of text   |

AntennaHead's side does not exist yet — it needs `NSAppleEventManager`
handlers (or its own sdef) for class `AntH` with those IDs. Sending requires
the `com.apple.security.automation.apple-events` entitlement
(`ControlBooth.entitlements`, needed under hardened runtime) and the
`NSAppleEventsUsageDescription` in `ControlBooth-Info.plist`; the first send
shows a one-time Automation consent prompt.

### One-time Xcode wiring for AppleEvents (manual)

ControlBooth target → Build Settings:

1. **Code Signing Entitlements** (`CODE_SIGN_ENTITLEMENTS`) =
   `ControlBooth.entitlements`
2. **Info.plist File** (`INFOPLIST_FILE`) = `ControlBooth-Info.plist`
   (merged into the generated Info.plist; adds `NSAppleScriptEnabled`,
   `OSAScriptingDefinition`, and the usage description)

The sdef and Swift sources live in the buildable folder and are picked up
automatically.

## Smoke tests

- **Without AntennaHead:** point a pipeline's destination port at a scratch
  port and run `nc -ul 6019 | xxd | head` — datagrams of ≤ 2048 bytes of S16LE
  should appear when the pipeline starts.
- **End to end:** start the AntennaHead custom task's Listen, start the
  "Speech Test" example pipeline in ControlBooth, and listen at the
  LiveAudioServer page (http://localhost:8080).
- **Orphan check:** Stop ControlBooth from Xcode while a pipeline runs;
  `pgrep PCMUDPSender` should come up empty within a second (the
  `--exit-with-parent` watchdog collapses the chain via SIGPIPE).
