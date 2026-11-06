import Foundation
@main struct Checks {
 static func main() async {
  let provider = CoreGraphicsProvider()
  let stream = await provider.changes()
  for _ in 0..<100 { await provider.handleReconfiguration(rawFlags: 0) }
  let consumer = Task { var count = 0; for await _ in stream { count += 1 }; return count }
  try? await Task.sleep(for: .milliseconds(100))
  consumer.cancel()
  let count = await consumer.value
  await provider.stopObserving()
  precondition(count == 1, "A burst of invalidations must refresh the latest state once, got \(count)")
  print("PASS: topology burst coalesced")
 }
}
