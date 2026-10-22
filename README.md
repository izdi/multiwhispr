# MultiWhispr

A macOS menu-bar app that records both sides of a call: your microphone on the left channel and the other participants, taken straight from the meeting app's audio, on the right. Each recording ships with a `session.json` that marks when you spoke and when others did, ready for a transcription step.

Works with Zoom, Microsoft Teams, Slack huddles, Webex, FaceTime, and any browser running Google Meet. Other apps' audio is captured with a Core Audio process tap, so macOS asks only for System Audio Recording. The screen is never recorded.

Requires macOS 14.2 or later.

## Build

```bash
make check                                   # type-check, tests, plist validation
make CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
open build/MultiWhispr.app
```

`CODESIGN_IDENTITY` defaults to ad-hoc signing, which re-triggers permission prompts after every rebuild. Use a real identity for repeated testing.

## Use

1. Menu bar → Settings… → check the apps you'll be in the call with, or pick "All apps".
2. Join the call. In "Selected apps" mode at least one checked app must already be playing audio.
3. Menu bar → "Start Meeting Recording". Allow Microphone and System Audio Recording when asked.
4. Menu bar → "Stop Recording". Recordings are saved under `~/Library/Application Support/MultiWhispr/Meetings/`.

Each recording folder holds `recording.wav` (16 kHz stereo PCM) and `session.json` (start time, duration, captured apps, and `me` / `others` segments with start and end seconds).

## Layout

- `Sources/MeetingCore/`: dependency-free timeline aligner, speaker-activity detector, process matcher, metadata model, and selection preferences. Covered by `Tests/`.
- `Sources/ProcessAudioTap.swift`: Core Audio process tap and aggregate device.
- `Sources/MeetingRecorder.swift`: microphone capture, alignment, WAV and metadata writing.
- `Sources/MeetingRecordingController.swift`: UI state.
- `Sources/App.swift`, `AppDelegate.swift`, `SettingsView.swift`: menu bar and settings window.

Recordings stay on your Mac. Nothing is uploaded.

## License

MIT, see `LICENSE`.
