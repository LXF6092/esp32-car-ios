import AVFoundation
import Combine
import Foundation
import ImageIO
import Vision

enum FollowTargetKind: String {
    case object = "物件"
    case person = "人物"
}

final class CameraInspectionController: NSObject, ObservableObject {
    @Published private(set) var permissionDenied = false
    @Published private(set) var isRunning = false
    @Published private(set) var lineOffset: Double?
    @Published private(set) var lineConfidence: Double = 0
    @Published private(set) var lastFrameAt: Date?
    @Published private(set) var lastMarkerText: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var targetBoundingBox: CGRect?
    @Published private(set) var targetConfidence: Float = 0
    @Published private(set) var targetKind: FollowTargetKind?
    @Published private(set) var targetStatus = "尚未选择目标"
    @Published private(set) var lastTargetAt: Date?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "esp32car.camera.session")
    private let frameQueue = DispatchQueue(label: "esp32car.camera.frames")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var configured = false
    private var frameNumber = 0
    private var smoothedOffset: Double?
    private var sequenceHandler = VNSequenceRequestHandler()
    private var trackedObservation: VNDetectedObjectObservation?
    private var desiredTargetKind: FollowTargetKind?
    private var reacquisitionBlocked = false

    var frameIsFresh: Bool {
        guard let lastFrameAt else { return false }
        return Date().timeIntervalSince(lastFrameAt) < 0.45
    }

    var targetIsFresh: Bool {
        guard let lastTargetAt else { return false }
        return Date().timeIntervalSince(lastTargetAt) < 0.35
    }

    func lockObject(at point: CGPoint) {
        let size = 0.22
        let originX = max(0, min(1 - size, point.x - size / 2))
        let originY = max(0, min(1 - size, point.y - size / 2))
        let box = CGRect(x: originX, y: originY, width: size, height: size)
        frameQueue.async { [weak self] in
            guard let self else { return }
            self.sequenceHandler = VNSequenceRequestHandler()
            self.desiredTargetKind = .object
            self.reacquisitionBlocked = false
            self.trackedObservation = VNDetectedObjectObservation(boundingBox: box)
            self.publishTarget(box: box, confidence: 1, kind: .object, status: "物件已锁定")
        }
    }

    func startPersonDetection() {
        frameQueue.async { [weak self] in
            guard let self else { return }
            self.sequenceHandler = VNSequenceRequestHandler()
            self.trackedObservation = nil
            self.desiredTargetKind = .person
            self.reacquisitionBlocked = false
            self.publishTarget(box: nil, confidence: 0, kind: .person, status: "正在寻找单个人物")
        }
    }

    func clearTarget() {
        frameQueue.async { [weak self] in
            guard let self else { return }
            self.sequenceHandler = VNSequenceRequestHandler()
            self.trackedObservation = nil
            self.desiredTargetKind = nil
            self.reacquisitionBlocked = false
            self.publishTarget(box: nil, confidence: 0, kind: nil, status: "尚未选择目标")
        }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.permissionDenied = !granted
                }
                if granted { self?.configureAndStart() }
            }
        default:
            permissionDenied = true
            errorMessage = "请在系统设置中允许相机权限"
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async {
                self.isRunning = false
                self.lineOffset = nil
                self.lineConfidence = 0
                self.lastFrameAt = nil
                self.targetBoundingBox = nil
                self.targetConfidence = 0
                self.lastTargetAt = nil
            }
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .vga640x480
                defer { self.session.commitConfiguration() }
                guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: camera),
                      self.session.canAddInput(input) else {
                    DispatchQueue.main.async { self.errorMessage = "无法打开后置摄像头" }
                    return
                }
                self.session.addInput(input)
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                self.videoOutput.setSampleBufferDelegate(self, queue: self.frameQueue)
                guard self.session.canAddOutput(self.videoOutput) else {
                    DispatchQueue.main.async { self.errorMessage = "无法建立相机分析输出" }
                    return
                }
                self.session.addOutput(self.videoOutput)
                if let connection = self.videoOutput.connection(with: .video), connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async {
                self.permissionDenied = false
                self.isRunning = true
                self.errorMessage = nil
            }
        }
    }

    private func analyzeLine(_ pixelBuffer: CVPixelBuffer) -> (Double?, Double) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return (nil, 0) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width >= 80, height >= 80 else { return (nil, 0) }

        let bins = 24
        var sums = Array(repeating: 0.0, count: bins)
        var counts = Array(repeating: 0, count: bins)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let startY = Int(Double(height) * 0.58)
        let endY = Int(Double(height) * 0.92)
        for y in stride(from: startY, to: endY, by: 4) {
            let row = pointer.advanced(by: y * bytesPerRow)
            for x in stride(from: 0, to: width, by: 4) {
                let offset = x * 4
                let blue = Double(row[offset])
                let green = Double(row[offset + 1])
                let red = Double(row[offset + 2])
                let luminance = 0.114 * blue + 0.587 * green + 0.299 * red
                let bin = min(bins - 1, x * bins / width)
                sums[bin] += luminance
                counts[bin] += 1
            }
        }
        let averages = zip(sums, counts).map { pair in
            pair.0 / Double(max(1, pair.1))
        }
        guard let darkest = averages.enumerated().min(by: { $0.element < $1.element }) else { return (nil, 0) }
        let global = averages.reduce(0, +) / Double(averages.count)
        let confidence = max(0, min(1, (global - darkest.element) / 70.0))
        guard confidence >= 0.12 else { return (nil, confidence) }
        let center = (Double(darkest.offset) + 0.5) / Double(bins)
        return ((center - 0.5) * 2.0, confidence)
    }

    private func detectMarker(_ pixelBuffer: CVPixelBuffer) {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        guard (try? handler.perform([request])) != nil,
              let payload = request.results?.first?.payloadStringValue else { return }
        DispatchQueue.main.async { [weak self] in self?.lastMarkerText = payload }
    }

    private func updateTargetTracking(_ pixelBuffer: CVPixelBuffer) {
        guard let kind = desiredTargetKind else { return }

        if let observation = trackedObservation {
            if kind == .person, frameNumber % 10 == 0 {
                let peopleRequest = VNDetectHumanRectanglesRequest()
                peopleRequest.upperBodyOnly = false
                let peopleHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
                if (try? peopleHandler.perform([peopleRequest])) != nil,
                   (peopleRequest.results?.count ?? 0) != 1 {
                    trackedObservation = nil
                    reacquisitionBlocked = true
                    sequenceHandler = VNSequenceRequestHandler()
                    let count = peopleRequest.results?.count ?? 0
                    let status = count > 1 ? "检测到多人：已停车" : "人物丢失：已停车"
                    publishTarget(box: nil, confidence: 0, kind: .person, status: status)
                    return
                }
            }
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .accurate
            do {
                try sequenceHandler.perform([request], on: pixelBuffer, orientation: .up)
                guard let result = request.results?.first as? VNDetectedObjectObservation,
                      !request.isLastFrame,
                      result.confidence >= 0.30 else {
                    loseTarget(kind)
                    return
                }
                trackedObservation = result
                publishTarget(
                    box: result.boundingBox,
                    confidence: result.confidence,
                    kind: kind,
                    status: "\(kind.rawValue)跟踪中"
                )
            } catch {
                loseTarget(kind)
            }
            return
        }

        guard kind == .person, !reacquisitionBlocked, frameNumber % 5 == 0 else { return }
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil else { return }
        let people = request.results ?? []
        if people.count == 1, let person = people.first {
            sequenceHandler = VNSequenceRequestHandler()
            trackedObservation = person
            publishTarget(box: person.boundingBox, confidence: person.confidence, kind: .person, status: "人物已锁定")
        } else if people.count > 1 {
            publishTarget(box: nil, confidence: 0, kind: .person, status: "检测到多人：请仅保留一人")
        } else {
            publishTarget(box: nil, confidence: 0, kind: .person, status: "未检测到人物")
        }
    }

    private func loseTarget(_ kind: FollowTargetKind) {
        trackedObservation = nil
        reacquisitionBlocked = true
        sequenceHandler = VNSequenceRequestHandler()
        publishTarget(box: nil, confidence: 0, kind: kind, status: "目标丢失：已停车，请重新选择")
    }

    private func publishTarget(
        box: CGRect?,
        confidence: Float,
        kind: FollowTargetKind?,
        status: String
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.targetBoundingBox = box
            self?.targetConfidence = confidence
            self?.targetKind = kind
            self?.targetStatus = status
            self?.lastTargetAt = box == nil ? nil : Date()
        }
    }
}
extension CameraInspectionController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameNumber += 1
        updateTargetTracking(pixelBuffer)
        let analysis = analyzeLine(pixelBuffer)
        if let offset = analysis.0 {
            smoothedOffset = smoothedOffset.map { $0 * 0.68 + offset * 0.32 } ?? offset
        } else {
            smoothedOffset = nil
        }
        let publishedOffset = smoothedOffset
        DispatchQueue.main.async { [weak self] in
            self?.lineOffset = publishedOffset
            self?.lineConfidence = analysis.1
            self?.lastFrameAt = Date()
        }
        if frameNumber % 6 == 0 { detectMarker(pixelBuffer) }
    }
}
