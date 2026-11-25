import Foundation
import Testing

// Isolated queue proof only; never merge this test to main.
@Test func fleckQueueProtectionCanary() {
  guard let phase = ProcessInfo.processInfo.environment["FLECK_QUEUE_PROOF_PHASE"] else {
    // Only the ordinary complete graph exports the marker.
    return
  }
  print("FLECK_QUEUE_NATIVE case=negative phase=\(phase)")
  #expect(phase == "admission" || phase == "queue", "FLECK_QUEUE_PHASE_INVALID")
  #expect(phase != "queue", "FLECK_QUEUE_PLANTED_NATIVE_ASSERTION")
}
