import Foundation

protocol ClipboardServicing {
    @MainActor
    @discardableResult
    func copy(_ string: String) -> Bool
}
