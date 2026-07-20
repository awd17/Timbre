import AppKit
import Foundation

struct ClipboardService: ClipboardServicing {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    @MainActor
    @discardableResult
    func copy(_ string: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(string, forType: .string)
            && pasteboard.string(forType: .string) == string
    }
}
