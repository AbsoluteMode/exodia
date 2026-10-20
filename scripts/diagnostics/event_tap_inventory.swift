import CoreGraphics
import Foundation

// Inventory only: never creates a tap or reads an event or its key contents.
var capacity: UInt32 = 0
var result = CGGetEventTapList(0, nil, &capacity)
guard result == .success else { exit(1) }
var taps: [CGEventTapInformation] = []
var actual: UInt32 = 0
for _ in 0..<3 {
    capacity = max(capacity, 16)
    taps = Array(repeating: CGEventTapInformation(), count: Int(capacity))
    result = CGGetEventTapList(capacity, &taps, &actual)
    if result == .success && actual <= capacity { break }
    capacity = max(actual, capacity * 2)
}
guard result == .success, actual <= capacity else { exit(1) }
let inventory: [[String: Any]] = taps.prefix(Int(actual)).map {
    [
        "id": $0.eventTapID,
        "owner_pid": $0.tappingProcess,
        "target_pid": $0.processBeingTapped,
        "location": $0.tapPoint.rawValue,
        "options": $0.options.rawValue,
        "enabled": $0.enabled,
        "mask": $0.eventsOfInterest,
    ]
}
let data = try JSONSerialization.data(withJSONObject: inventory, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
