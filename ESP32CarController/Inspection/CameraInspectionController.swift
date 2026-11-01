import AVFoundation
import Combine
import Foundation
import ImageIO
import Vision

final class CameraInspectionController: NSObject, ObservableObject {
    @Published private(set) var permissionDenied = false
    @Published private(set) var isRunning = false
    @Published private(set) var lineOffset: Double?
    @Published private(set) var lineConfidence: Double = 0
    @Published private(set) var lastFrameAt: Date?
    @Published private(set) var lastMarkerText: String?
    @Published private(set) var errorMessage: String?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "esp32car.camera.session")
    private let frameQueue = DispatchQueue(label: "esp32car.camera.frames")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var configured = false
    private var frameNumber = 0
    private var smoothedOffset: Double?

    var frameIsFresh: Bool {
        guard let lastFrameAt else { return false }
        return Date().timeIntervalSince(lastFrameAt) < 0.45
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
}
extension CameraInspectionController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameNumber += 1
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
