import Foundation

// Bounded diagnostic capture while the gesture settings tab is visible only.
// Contains sensor data and aggregate input activity, never key/touch contents.
struct GestureTrace:Codable {
    let capturedAt:Date
    let hardware:String
    let modelID:String
    let recording:GestureRecording
    let evidence:[SideEvidence]
    let lastNavigationAt:Double?
}
