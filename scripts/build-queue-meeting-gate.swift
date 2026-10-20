// Read-only builder gate: CoreAudio activity flags only, never audio or UI.
import CoreAudio
import Foundation

struct AudioActivity {
    let input: Bool
    let output: Bool
    let bundle: String?
}
struct Gate: Codable, Equatable {
    let status: String
    let reason: String
}
func classify(_ rows: [AudioActivity], complete: Bool) -> Gate {
    // Any microphone user may be an unrecognized call or a manual Notes take.
    if rows.contains(where: { $0.input }) {
        return Gate(status: "busy", reason: "microphone_in_use")
    }
    guard complete else { return Gate(status: "unknown", reason: "incomplete_audio_snapshot") }
    let callApps = ["us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap", "com.apple.facetime", "com.hnc.discord",
        "ru.keepcoder.telegram", "org.telegram.desktop", "net.whatsapp.whatsapp",
        "com.cisco.webexmeetingsapp", "ru.yandex.telemost"]
    let browsers = ["com.google.chrome", "com.apple.safari", "com.apple.webkit",
        "com.brave.browser", "com.microsoft.edgemac", "company.thebrowser.browser",
        "company.thebrowser.dia", "org.mozilla.firefox"]
    func matches(_ bid: String, _ prefix: String) -> Bool {
        bid == prefix || bid.hasPrefix(prefix + ".")
    }
    for row in rows where row.output {
        guard let bid = row.bundle?.lowercased(), !bid.isEmpty else {
            return Gate(status: "unknown", reason: "unidentified_audio_output")
        }
        if callApps.contains(where: { matches(bid, $0) }) {
            return Gate(status: "busy", reason: "call_app_output_active")
        }
        if browsers.contains(where: { matches(bid, $0) }) ||
            (bid.hasPrefix("company.thebrowser.") && bid.contains(".browser.helper")) {
            return Gate(status: "unknown", reason: "browser_audio_may_be_a_muted_call")
        }
    }
    return Gate(status: "clear", reason: "no_call_audio_observed")
}
func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<UInt32>.size), value: UInt32 = 0
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}
func bundle(_ object: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString = "" as CFString
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
    }
    guard status == noErr else { return nil }
    return value as String
}
func snapshot() -> Gate {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
        Int(size) % MemoryLayout<AudioObjectID>.size == 0 else {
        return Gate(status: "unknown", reason: "audio_process_list_unavailable")
    }
    if size == 0 { return classify([], complete: true) }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let status = objects.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
    }
    guard status == noErr else { return Gate(status: "unknown", reason: "audio_process_list_unavailable") }
    var complete = true
    var rows: [AudioActivity] = []
    for object in objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size) {
        guard let input = number(object, kAudioProcessPropertyIsRunningInput),
            let output = number(object, kAudioProcessPropertyIsRunningOutput) else {
            complete = false; continue
        }
        rows.append(AudioActivity(input: input != 0, output: output != 0,
            bundle: output == 0 ? nil : bundle(object)))
    }
    return classify(rows, complete: complete)
}
if CommandLine.arguments.dropFirst() == ["--self-test"] {
    func expect(_ rows: [AudioActivity], _ complete: Bool, _ status: String) {
        precondition(classify(rows, complete: complete).status == status)
    }
    expect([], true, "clear")
    expect([], false, "unknown")
    expect([AudioActivity(input: true, output: false, bundle: nil)], false, "busy")
    expect([AudioActivity(input: true, output: false, bundle: "com.rootwise.sidekey")], true, "busy")
    expect([AudioActivity(input: false, output: true, bundle: "com.microsoft.teams2.modulehost")], true, "busy")
    expect([AudioActivity(input: false, output: true, bundle: "company.thebrowser.browser.helper")], true, "unknown")
    expect([AudioActivity(input: false, output: true, bundle: "com.apple.WebKit.GPU")], true, "unknown")
    expect([AudioActivity(input: false, output: true, bundle: nil)], true, "unknown")
    expect([AudioActivity(input: false, output: true, bundle: "com.apple.Music")], true, "clear")
    expect([AudioActivity(input: false, output: false, bundle: "us.zoom.xos")], true, "clear")
    print("{\"self_test\":\"passed\",\"cases\":10}")
} else if CommandLine.arguments.count == 1 {
    var samples: [Gate] = []
    for index in 0..<3 {
        if index > 0 { Thread.sleep(forTimeInterval: 1) }
        samples.append(snapshot())
    }
    struct Report: Codable { let samples: [Gate]; let observed_at: String }
    let report = Report(samples: samples, observed_at: ISO8601DateFormatter().string(from: Date()))
    print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
} else {
    fputs("Unsupported arguments\n", stderr); exit(2)
}
