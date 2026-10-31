import AVFoundation
import Combine
import Foundation
import Speech

enum VoiceAction: Equatable {
    case drive(DriveVector)
    case stop
    case emergencyStop
    case faster
    case slower
    case none
}

struct VoiceCommandParser {
    static func parse(_ source: String) -> VoiceAction {
        let text = source
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "！", with: "")
            .replacingOccurrences(of: "？", with: "")

        if containsAny(text, ["急停", "紧急停止", "锁死"]) { return .emergencyStop }
        if containsAny(text, ["不要", "别", "禁止", "不能", "不许", "取消"]) { return .stop }
        if exact(text, ["停车", "停止", "刹车", "别动", "站住", "stop"]) { return .stop }
        if exact(text, ["前进", "向前", "往前走", "直走"]) { return .drive(DriveVector(vx: 0, vy: 100, omega: 0)) }
        if exact(text, ["后退", "向后", "往后退", "倒车"]) { return .drive(DriveVector(vx: 0, vy: -100, omega: 0)) }
        if exact(text, ["左转", "向左转"]) { return .drive(DriveVector(vx: 0, vy: 0, omega: -100)) }
        if exact(text, ["右转", "向右转"]) { return .drive(DriveVector(vx: 0, vy: 0, omega: 100)) }
        if exact(text, ["向左平移", "左平移"]) { return .drive(DriveVector(vx: -100, vy: 0, omega: 0)) }
        if exact(text, ["向右平移", "右平移"]) { return .drive(DriveVector(vx: 100, vy: 0, omega: 0)) }
        if exact(text, ["快一点", "加速", "加档"]) { return .faster }
        if exact(text, ["慢一点", "减速", "降档"]) { return .slower }
        return .none
    }

    private static func exact(_ text: String, _ values: [String]) -> Bool {
        values.contains(text)
    }

    private static func containsAny(_ text: String, _ values: [String]) -> Bool {
        values.contains { text.contains($0) }
    }
}

final class SpeechController: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isListening = false
    @Published private(set) var status = "点击麦克风说一条指令"

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var timeoutTask: Task<Void, Never>?
    private var completion: ((String) -> Void)?
    private var generation: UInt = 0
    private var tapInstalled = false

    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speech else {
            await MainActor.run { self.status = "语音识别权限未开启" }
            return false
        }
        let microphone = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        if !microphone {
            await MainActor.run { self.status = "麦克风权限未开启" }
        }
        return microphone
    }

    @MainActor
    func start(onFinal: @escaping (String) -> Void) async {
        stop(keepStatus: true)
        let sessionGeneration = generation
        guard await requestPermissions(),
              !Task.isCancelled,
              generation == sessionGeneration else { return }
        guard let recognizer, recognizer.isAvailable else {
            status = "语音识别当前不可用，请使用快捷口令"
            return
        }

        completion = onFinal
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .confirmation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            if tapInstalled {
                input.removeTap(onBus: 0)
                tapInstalled = false
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            status = "麦克风启动失败：\(error.localizedDescription)"
            stop(keepStatus: true)
            return
        }

        isListening = true
        transcript = ""
        status = recognizer.supportsOnDeviceRecognition ? "正在设备端识别..." : "正在识别..."
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                guard self.generation == sessionGeneration else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        let finalText = self.transcript
                        let callback = self.completion
                        self.stop(keepStatus: true)
                        self.status = "识别到：\(finalText)"
                        callback?(finalText)
                    }
                } else if let error {
                    self.status = "识别失败：\(error.localizedDescription)"
                    self.stop(keepStatus: true)
                }
            }
        }

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.generation == sessionGeneration else { return }
                if self.isListening {
                    self.status = "未识别到指令，请重试或使用快捷口令"
                    self.stop(keepStatus: true)
                }
            }
        }
    }

    @MainActor
    func stop(keepStatus: Bool = false) {
        generation &+= 1
        completion = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if !keepStatus {
            status = "点击麦克风说一条指令"
        }
    }
}
