import Foundation
import XCTest

@MainActor
func waitUntil(
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)

    while !condition() {
        guard Date() < deadline else {
            XCTFail("Timed out after \(timeout) seconds waiting for condition", file: file, line: line)
            return
        }

        await Task.yield()
    }
}
