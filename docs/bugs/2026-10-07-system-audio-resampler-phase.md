# Preserve resampling phase across capture callbacks

System-audio capture converts the source sample rate to the meeting pipeline's
16 kHz format. Each callback continues the previous callback's fractional sample
position and boundary sample. Restarting that interpolation state for every
buffer introduced discontinuities in captured audio.

`SystemAudioStreamingResampler` resets its state on a source-rate change or a
new audio-tap generation, rather than each callback. The regression tests feed
the same input using different callback splits and compare the resulting audio.
This verifies conversion continuity; it does not establish end-to-end reliability
for an hour-long meeting or a particular transcription provider.

Source: `Sources/Sidekey/Meetings/CoreAudioSystemAudioSource.swift`.
Verification: `Tests/SidekeyTests/Meetings/CoreAudioSystemAudioSourceTests.swift`.
