# Translation and system-audio subtitles

Open **Translate** or **Subtitles** from the island's tool search. Add either
button in **Settings → Toolbox** if you want it pinned. Each tool can have its
own shortcut in **Settings → Hotkeys**; no existing shortcut or layout changes.
Both tools open the same floating, resizable window, including over full-screen
apps. Escape or the close button closes it and cancels translation/capture.

## Setup

In **Settings → API & Models**, choose:

- **Translation**: an OpenRouter text model or your own OpenAI-compatible text
  endpoint. This model translates both typed text and subtitle phrases.
- **Subtitles audio**: a Soniox, Deepgram, ElevenLabs or your own compatible
  realtime speech endpoint. This model transcribes system audio for subtitles.

Keys stay in Whytap's existing Keychain store. These new routes start **Not
set**, including on an upgraded installation. The app never borrows another
feature's model or chooses a replacement provider after a failure.

## Text

Type or paste text, choose a target and press **Translate** or **Command Return**.
**Auto · RU ↔ EN** translates Cyrillic input to English and other input to Russian.
An explicit target overrides that direction. Language choices are remembered
locally for the next launch and included in settings backups; submitted text
and subtitle content are excluded. Copy copies the result only when
you click it; the translator does not read the clipboard automatically.

Editing the input or changing the target cancels the old request and clears
its result. Late responses cannot replace a newer translation. Inputs are
limited to 12,000 characters per request. A request has a 30-second resource
budget; failures retain the input for another attempt.

## Subtitles

Choose the spoken language (or Auto-detect), a target, then **Start subtitles**.
Play a video or join a call. The window floats over other apps and full-screen
content; you can move or resize it. **Original** shows source phrases above the
translation. **Follow** follows the latest line; turn it off to read older lines.
Copy copies the completed translations retained in this window.

Only system audio is captured. The microphone is not opened, no recording is
saved, and no meeting note is created. Starting may request macOS **System
Audio Recording** permission. If the Mac is playing audio but no signal arrives,
check that permission in **System Settings → Privacy & Security**. Silence and
a denied grant cannot be reliably distinguished by the capture API.

The selected speech provider receives system audio. Its committed phrases go
to the selected Translation model. Interim speech is shown but never translated
or billed as an LLM request. This is a speech-to-text → LLM pipeline; latency
depends on phrase finalization, the network and the chosen model. It does not
use the standalone app's OpenAI translation endpoint or its credential files.

**Stop** stops capture, drains queued audio, waits up to ten seconds for speech
finals and completes queued translations. Audio already captured at Stop is sent
before the speech provider receives its end-of-input signal. **Cancel**, closing the window or
Mac sleep cancels immediately. Switching to Text leaves subtitles running;
a waveform button beside the target reopens them. Updates defer app-initiated
restart while this window is open or a translation session is active, preserving
unsent text as well. Close the window before choosing Restart.

At most eight phrases wait for translation and forty recent lines remain in
memory. Audio also crosses a bounded queue. If the connection or model cannot
keep up, capture stops with an actionable error instead of accumulating delay
or silently dropping speech. Choose a faster model and start again. Starting a
new subtitle session clears the previous lines.

## Verification

Automated checks use fake speech, fake system audio and fake translation; they
never use personal audio, clipboard content, keys or paid requests. Offscreen
renders cover normal and narrow windows, empty/result/setup states. Live
permission prompting, full-screen focus, actual translation quality and latency
must be checked in the shared installed app after integration.
