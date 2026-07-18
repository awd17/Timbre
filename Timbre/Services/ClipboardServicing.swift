import Foundation

protocol ClipboardServicing {
    @MainActor
    func copy(_ string: String)
}
