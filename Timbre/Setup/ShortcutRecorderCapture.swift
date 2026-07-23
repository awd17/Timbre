import KeyboardShortcuts
import SwiftUI

/// Keeps KeyboardShortcuts' validation and conflict handling without exposing its
/// native search-field UI. The onboarding button controls when this view takes focus.
struct ShortcutRecorderCapture: NSViewRepresentable {
    let name: KeyboardShortcuts.Name
    @Binding var isRecording: Bool
    let onChange: (KeyboardShortcuts.Shortcut?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isRecording: $isRecording, onChange: onChange)
    }

    func makeNSView(context: Context) -> KeyboardShortcuts.RecorderCocoa {
        let recorder = KeyboardShortcuts.RecorderCocoa(for: name) { shortcut in
            context.coordinator.finishRecording(with: shortcut)
        }
        recorder.alphaValue = 0.001
        recorder.focusRingType = .none
        recorder.setAccessibilityElement(false)
        context.coordinator.observeRecorderStatus()
        return recorder
    }

    func updateNSView(
        _ recorder: KeyboardShortcuts.RecorderCocoa,
        context: Context
    ) {
        context.coordinator.isRecording = $isRecording
        context.coordinator.onChange = onChange
        recorder.shortcutName = name

        guard isRecording else {
            context.coordinator.focusRequested = false
            return
        }
        guard !context.coordinator.focusRequested else { return }

        context.coordinator.requestFocus(for: recorder)
    }

    static func dismantleNSView(
        _ recorder: KeyboardShortcuts.RecorderCocoa,
        coordinator: Coordinator
    ) {
        recorder.window?.makeFirstResponder(nil)
        coordinator.stopObservingRecorderStatus()
    }

    @MainActor
    final class Coordinator {
        var isRecording: Binding<Bool>
        var onChange: (KeyboardShortcuts.Shortcut?) -> Void
        var focusRequested = false
        private var focusAttemptCount = 0
        private var recorderStatusObserver: NSObjectProtocol?

        init(
            isRecording: Binding<Bool>,
            onChange: @escaping (KeyboardShortcuts.Shortcut?) -> Void
        ) {
            self.isRecording = isRecording
            self.onChange = onChange
        }

        func finishRecording(with shortcut: KeyboardShortcuts.Shortcut?) {
            focusRequested = false
            focusAttemptCount = 0
            isRecording.wrappedValue = false
            onChange(shortcut)
        }

        func requestFocus(for recorder: KeyboardShortcuts.RecorderCocoa) {
            focusRequested = true
            focusAttemptCount = 0
            attemptFocus(for: recorder)
        }

        private func attemptFocus(for recorder: KeyboardShortcuts.RecorderCocoa) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak recorder] in
                guard
                    let self,
                    self.isRecording.wrappedValue,
                    let recorder
                else {
                    return
                }

                self.focusAttemptCount += 1
                if recorder.window?.makeFirstResponder(recorder) == true {
                    return
                }

                if self.focusAttemptCount < 5 {
                    self.attemptFocus(for: recorder)
                } else {
                    self.focusRequested = false
                    self.focusAttemptCount = 0
                    self.isRecording.wrappedValue = false
                }
            }
        }

        func observeRecorderStatus() {
            guard recorderStatusObserver == nil else { return }
            recorderStatusObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("KeyboardShortcuts_recorderActiveStatusDidChange"),
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard
                    let isActive = notification.userInfo?["isActive"] as? Bool,
                    let self
                else {
                    return
                }
                Task { @MainActor in
                    self.isRecording.wrappedValue = isActive
                    if !isActive {
                        self.focusRequested = false
                        self.focusAttemptCount = 0
                    }
                }
            }
        }

        func stopObservingRecorderStatus() {
            guard let recorderStatusObserver else { return }
            NotificationCenter.default.removeObserver(recorderStatusObserver)
            self.recorderStatusObserver = nil
        }

        deinit {
            if let recorderStatusObserver {
                NotificationCenter.default.removeObserver(recorderStatusObserver)
            }
        }
    }
}
