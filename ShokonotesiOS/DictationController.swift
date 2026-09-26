import Foundation
import AVFoundation
import Speech

/// On-device dictation into the bottom bar's search field. A convenience
/// control: any permission denial hides the mic instead of nagging or
/// crashing. Not `@MainActor` — every mutation is dispatched to main
/// explicitly, matching the rest of the iOS target's UIKit bridging code
/// (see `PreviewHostView`).
final class DictationController: ObservableObject {
    @Published private(set) var isRecording = false
    /// False once either permission is known-denied/restricted, or a start
    /// attempt fails. The bottom bar hides the mic entirely when false.
    @Published private(set) var isAvailable: Bool

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    init() {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let micStatus = AVAudioApplication.shared.recordPermission
        // `Info.plist` promises on-device recognition. A recognizer that
        // cannot work offline would send audio to Apple's servers, so the
        // mic is hidden on that device.
        let onDevice = SFSpeechRecognizer(locale: Locale.current)?.supportsOnDeviceRecognition ?? false
        isAvailable = onDevice
            && speechStatus != .denied && speechStatus != .restricted
            && micStatus != .denied
    }

    /// Tap: start listening, transcribing live into `onTranscript` as speech
    /// is recognized. Tap again: stop. The caller also stops on the first
    /// manual keystroke: `IOSSearchCapsule`'s binding setter fires only for
    /// a real keypress, never for the programmatic writes dictation makes.
    func toggle(into onTranscript: @escaping (String) -> Void) {
        if isRecording {
            stop()
        } else {
            start(into: onTranscript)
        }
    }

    private func start(into onTranscript: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            isAvailable = false
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.isAvailable = false
                    return
                }
                self.requestMicrophone(onTranscript)
            }
        }
    }

    private func requestMicrophone(_ onTranscript: @escaping (String) -> Void) {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.isAvailable = false
                    return
                }
                self.beginRecording(onTranscript)
            }
        }
    }

    private func beginRecording(_ onTranscript: @escaping (String) -> Void) {
        guard let recognizer else { return }
        // Checked again here: the two permission prompts are asynchronous, and
        // nothing may start a request that could leave the device.
        guard recognizer.supportsOnDeviceRecognition else {
            isAvailable = false
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            isAvailable = false
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Default is false, which streams the audio to Apple. Not here.
        request.requiresOnDeviceRecognition = true

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            isAvailable = false
            return
        }

        audioEngine = engine
        self.request = request
        isRecording = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                DispatchQueue.main.async {
                    onTranscript(result.bestTranscription.formattedString)
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                DispatchQueue.main.async {
                    self?.stop()
                }
            }
        }
    }

    func stop() {
        guard isRecording || audioEngine != nil else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        request?.endAudio()
        task?.cancel()
        audioEngine = nil
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
