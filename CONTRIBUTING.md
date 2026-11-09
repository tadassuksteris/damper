# Contributing

Damper is meant to stay small. Bug reports with device details are the most useful help. Please open an issue before starting on a feature. Boost, EQ, per-app routing, per-tab browser control and profiles are out of scope.

## How it works

For each app you lower or mute, Damper creates a private Core Audio process tap on that app's processes, which silences its normal output while the tap is read. It also builds a private aggregate device with the tap and your output device. A C callback in `Sources/AudioRealtime` reads the tap, applies the gain and writes to the output. If the output or the buffer layout can't be validated, the app is left on ordinary playback.

## Build and test

```sh
swift test
./scripts/run.sh
```

Always run the app through `scripts/run.sh` or `scripts/build.sh`. Xcode's Run button and `swift run` start a bare executable with no bundle identity, sandbox or usage string, so permissions and saved settings behave differently. Builds are signed ad hoc unless you set `DAMPER_SIGNING_IDENTITY`.

`swift test` never starts audio processing or touches real settings. Keep it that way by using the existing seams: `AudioBackend`, `AudioAccessPermissionProviding`, `PreferenceStorage`, `LoginItemControlling`, `OutputRouteAccess` and `OutputVolumePropertyAccess`.

## Rules

- Code in the audio callback can't allocate, take locks, log, or call Swift or Objective-C.
- When unsure, leave the audio alone. Don't guess a channel mapping or which app a process belongs to.
- Sparkle is the only dependency and stays in `AppUpdater.swift`. Use public Apple APIs, apart from the one permission check described in the README, and keep to the macOS 26 SDK.
- The UI should look like the built-in macOS panels, with no custom tints or cards. Text appears only when the user has to do something, and it never claims more than the app knows: a running callback doesn't prove sound is audible.

## Checking with real audio

If you change the audio path, run this check and mention in the pull request which output you used. The two fixture apps play quiet tones through your current output for three minutes. The check lowers and mutes them through Damper and measures Damper's output. Keep other playback idle and quit Damper first.

```sh
./scripts/build.sh debug
./scripts/build-audio-fixtures.sh
open "build/audio-fixtures/Damper Test a.app"
open "build/audio-fixtures/Damper Test b.app"
build/Damper.app/Contents/MacOS/Damper --verify-test-audio
```

Started from a terminal, the check uses the terminal's audio permission, not Damper's. Allow your terminal under System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only. `pkill -x AudioFixture` stops the tones early.

`build/Damper.app/Contents/MacOS/Damper --diagnostics` lists the outputs and audio apps Damper sees, and why the current output isn't supported, if it isn't. Its output includes device and app names, so check it before posting it.
