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
    @Published private(set) var targetIdentityDistance: Float?

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
    private var lastKnownTargetBox: CGRect?
    private var reacquisitionAttempts = 0
    private var objectReferenceFeature: VNFeaturePrintObservation?

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
            self.lastKnownTargetBox = box
            self.reacquisitionAttempts = 0
            self.objectReferenceFeature = nil
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
            self.lastKnownTargetBox = nil
            self.reacquisitionAttempts = 0
            self.objectReferenceFeature = nil
            self.publishTarget(box: nil, confidence: 0, kind: .person, status: "正在寻找单个人物")
        }
    }

    func clearTarget() {
        frameQueue.async { [weak self] in
            guard let self else { return }
            self.sequenceHandler = VNSequenceRequestHandler()
            self.trackedObservation = nil
            self.desiredTargetKind = nil
            self.lastKnownTargetBox = nil
            self.reacquisitionAttempts = 0
            self.objectReferenceFeature = nil
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
                if kind == .object {
                    if objectReferenceFeature == nil {
                        objectReferenceFeature = featurePrint(for: pixelBuffer, region: result.boundingBox)
                    } else if frameNumber % 8 == 0,
                              let matchDistance = identityDistance(for: pixelBuffer, region: result.boundingBox) {
                        publishIdentityDistance(matchDistance)
                        guard matchDistance <= 22 else {
                            loseTarget(kind)
                            return
                        }
                    }
                }
                trackedObservation = result
                lastKnownTargetBox = result.boundingBox
                reacquisitionAttempts = 0
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

        if kind == .object {
            guard frameNumber % 4 == 0, let lastBox = lastKnownTargetBox else { return }
            sequenceHandler = VNSequenceRequestHandler()
            if let candidate = bestObjectCandidate(in: pixelBuffer, around: lastBox) {
                trackedObservation = VNDetectedObjectObservation(boundingBox: candidate.box)
                publishIdentityDistance(candidate.distance)
            } else if objectReferenceFeature == nil {
                let factor = 1 + min(0.6, Double(reacquisitionAttempts) * 0.1)
                trackedObservation = VNDetectedObjectObservation(boundingBox: expandedBox(lastBox, factor: factor))
            }
            publishTarget(box: nil, confidence: 0, kind: .object, status: "物件暂时丢失：正在重新锁定")
            return
        }

        guard frameNumber % 5 == 0 else { return }
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil else { return }
        let people = request.results ?? []
        if let person = preferredPerson(from: people) {
            sequenceHandler = VNSequenceRequestHandler()
            trackedObservation = person
            lastKnownTargetBox = person.boundingBox
            reacquisitionAttempts = 0
            publishTarget(box: person.boundingBox, confidence: person.confidence, kind: .person, status: "人物已重新锁定")
        } else {
            publishTarget(box: nil, confidence: 0, kind: .person, status: "人物暂时丢失：正在持续搜索")
        }
    }

    private func loseTarget(_ kind: FollowTargetKind) {
        trackedObservation = nil
        reacquisitionAttempts += 1
        sequenceHandler = VNSequenceRequestHandler()
        publishTarget(box: nil, confidence: 0, kind: kind, status: "目标暂时丢失：停车并重新搜索")
    }

    private func preferredPerson(from people: [VNHumanObservation]) -> VNHumanObservation? {
        guard let lastBox = lastKnownTargetBox else {
            return people.max { lhs, rhs in
                lhs.boundingBox.width * lhs.boundingBox.height < rhs.boundingBox.width * rhs.boundingBox.height
            }
        }
        return people.min { lhs, rhs in
            distance(from: lhs.boundingBox, to: lastBox) < distance(from: rhs.boundingBox, to: lastBox)
        }
    }

    private func distance(from lhs: CGRect, to rhs: CGRect) -> Double {
        let dx = lhs.midX - rhs.midX
        let dy = lhs.midY - rhs.midY
        return sqrt(dx * dx + dy * dy)
    }

    private func expandedBox(_ box: CGRect, factor: Double) -> CGRect {
        let width = min(1, box.width * factor)
        let height = min(1, box.height * factor)
        return CGRect(
            x: max(0, min(1 - width, box.midX - width / 2)),
            y: max(0, min(1 - height, box.midY - height / 2)),
            width: width,
            height: height
        )
    }

    private func bestObjectCandidate(
        in pixelBuffer: CVPixelBuffer,
        around box: CGRect
    ) -> (box: CGRect, distance: Float)? {
        guard objectReferenceFeature != nil else { return nil }
        let radius = min(0.36, 0.05 + Double(reacquisitionAttempts) * 0.035)
        let offsets = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: -radius, y: 0), CGPoint(x: radius, y: 0),
            CGPoint(x: 0, y: -radius), CGPoint(x: 0, y: radius),
            CGPoint(x: -radius, y: -radius), CGPoint(x: radius, y: -radius),
            CGPoint(x: -radius, y: radius), CGPoint(x: radius, y: radius)
        ]
        var best: (box: CGRect, distance: Float)?
        for offset in offsets {
            let candidate = movedBox(box, dx: offset.x, dy: offset.y)
            guard let distance = identityDistance(for: pixelBuffer, region: candidate) else { continue }
            if best == nil || distance < best!.distance {
                best = (candidate, distance)
            }
        }
        guard let best, best.distance <= 22 else { return nil }
        return best
    }

    private func movedBox(_ box: CGRect, dx: Double, dy: Double) -> CGRect {
        CGRect(
            x: max(0, min(1 - box.width, box.origin.x + dx)),
            y: max(0, min(1 - box.height, box.origin.y + dy)),
            width: box.width,
            height: box.height
        )
    }

    private func featurePrint(
        for pixelBuffer: CVPixelBuffer,
        region: CGRect
    ) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.regionOfInterest = region
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first as? VNFeaturePrintObservation
    }

    private func identityDistance(
        for pixelBuffer: CVPixelBuffer,
        region: CGRect
    ) -> Float? {
        guard let reference = objectReferenceFeature,
              let candidate = featurePrint(for: pixelBuffer, region: region) else { return nil }
        var distance: Float = 0
        guard (try? reference.computeDistance(&distance, to: candidate)) != nil else { return nil }
        return distance
    }

    private func publishIdentityDistance(_ distance: Float) {
        DispatchQueue.main.async { [weak self] in self?.targetIdentityDistance = distance }
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
