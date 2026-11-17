//
//  CameraPipeline.swift
//  Wakie
//
//  Camera capture shared by Shaky-Shaky and Pickie-Picky, plus the Vision
//  detectors that run on each frame.
//

import AVFoundation
import SwiftUI
import UIKit
import Vision

enum CameraStatus: Equatable {
    case starting, running, denied, unavailable
}

/// Owns an `AVCaptureSession` and hands frames to `frameHandler` on a background queue.
/// Frames are rotated to match the on-screen preview (and mirrored for the selfie camera),
/// so Vision coordinates line up with what the person sees.
nonisolated final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "wakie.camera.session")
    private let videoQueue = DispatchQueue(label: "wakie.camera.frames")
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var isConfigured = false
    private var position: AVCaptureDevice.Position

    private let lock = NSLock()
    private var _frameHandler: (@Sendable (CVPixelBuffer) -> Void)?

    /// Called on a background queue for every frame. Late frames are dropped while it's busy.
    var frameHandler: (@Sendable (CVPixelBuffer) -> Void)? {
        get { lock.withLock { _frameHandler } }
        set { lock.withLock { _frameHandler = newValue } }
    }

    init(position: AVCaptureDevice.Position) {
        self.position = position
    }

    /// Whether both a front and a back camera exist, so switching makes sense.
    static var canSwitchCameras: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
            && AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    /// Requests access, configures the session and starts it.
    /// Returns the active camera so the preview can track its rotation.
    func start() async -> (CameraStatus, AVCaptureDevice?) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { return (.denied, nil) }
        case .denied, .restricted:
            return (.denied, nil)
        default:
            break
        }
        return await withCheckedContinuation { continuation in
            sessionQueue.async {
                guard self.configureIfNeeded(), let device = self.input?.device else {
                    continuation.resume(returning: (.unavailable, nil))
                    return
                }
                if !self.session.isRunning { self.session.startRunning() }
                continuation.resume(returning: (.running, device))
            }
        }
    }

    func stop() {
        frameHandler = nil
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Swaps between the front and back cameras. Returns the new camera, or `nil` on failure.
    func switchCamera() async -> AVCaptureDevice? {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                let newPosition: AVCaptureDevice.Position = self.position == .front ? .back : .front
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
                      let newInput = try? AVCaptureDeviceInput(device: device) else {
                    continuation.resume(returning: nil)
                    return
                }
                self.session.beginConfiguration()
                if let old = self.input { self.session.removeInput(old) }
                self.applyPreset(for: newPosition)
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.input = newInput
                    self.position = newPosition
                    if newPosition == .front { self.useWidestView(of: device) }
                } else if let old = self.input {
                    // Put the previous camera back if the new one can't be added.
                    self.applyPreset(for: self.position)
                    self.session.addInput(old)
                }
                self.applyMirroring()
                self.session.commitConfiguration()
                continuation.resume(returning: self.input?.device)
            }
        }
    }

    /// Rotates delivered frames to match the preview's angle.
    func setFrameRotation(_ angle: CGFloat) {
        sessionQueue.async {
            guard let connection = self.output.connection(with: .video),
                  connection.isVideoRotationAngleSupported(angle),
                  connection.videoRotationAngle != angle else { return }
            connection.videoRotationAngle = angle
        }
    }

    private func configureIfNeeded() -> Bool {
        if isConfigured { return true }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        applyPreset(for: position)
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        self.input = input
        if position == .front { useWidestView(of: device) }

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        applyMirroring()
        isConfigured = true
        return true
    }

    /// The back camera uses a 720p preset. The front camera picks its own format in
    /// `useWidestView(of:)`, because presets crop the sensor.
    private func applyPreset(for position: AVCaptureDevice.Position) {
        guard position == .back, session.canSetSessionPreset(.hd1280x720) else { return }
        session.sessionPreset = .hd1280x720
    }

    /// Shows as much of the room as the selfie camera can see, so a dancer fits in frame:
    /// the format with the widest field of view, Center Stage auto-framing off, and minimum zoom.
    private func useWidestView(of device: AVCaptureDevice) {
        // Center Stage crops in to follow faces, so turn it off for this app.
        if device.formats.contains(where: \.isCenterStageSupported) {
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled = false
        }

        // Among 30 fps video formats, prefer the widest view, then the smallest size of at
        // least 640 pixels so Vision stays fast.
        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            return [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(subtype)
                && min(dims.width, dims.height) >= 640
                && max(dims.width, dims.height) <= 1920
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        let best = candidates.max { a, b in
            if a.videoFieldOfView != b.videoFieldOfView { return a.videoFieldOfView < b.videoFieldOfView }
            let areaA = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let areaB = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(areaA.width) * Int(areaA.height) > Int(areaB.width) * Int(areaB.height)
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if let best { device.activeFormat = best }
            device.videoZoomFactor = device.minAvailableVideoZoomFactor
        } catch {
            print("Couldn't widen the front camera: \(error)")
        }
    }

    /// Mirrors frames from the selfie camera, matching the preview layer's default behaviour.
    private func applyMirroring() {
        guard let connection = output.connection(with: .video), connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = position == .front
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameHandler?(pixelBuffer)
    }
}

/// Live camera preview filling its frame, kept upright with a rotation coordinator.
struct CameraPreview: UIViewRepresentable {
    let camera: CameraPipeline
    let device: AVCaptureDevice?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onAngleChange = { [camera] angle in camera.setFrameRotation(angle) }
        view.device = device
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.device = device
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as? AVCaptureVideoPreviewLayer ?? AVCaptureVideoPreviewLayer()
        }

        /// Reports the preview angle so captured frames can be rotated the same way.
        var onAngleChange: ((CGFloat) -> Void)?

        /// A coordinator is bound to one camera, so a new one is made whenever it changes.
        var device: AVCaptureDevice? {
            didSet {
                if device !== oldValue { startObserving() }
            }
        }

        private var coordinator: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // The coordinator measures the layer's place in the window, which only exists now.
            if window != nil { startObserving() }
        }

        private func startObserving() {
            observation?.invalidate()
            observation = nil
            guard let device, window != nil else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            self.coordinator = coordinator
            apply(coordinator.videoRotationAngleForHorizonLevelPreview)
            observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: .new) { [weak self] _, change in
                guard let angle = change.newValue else { return }
                MainActor.assumeIsolated { self?.apply(angle) }
            }
        }

        private func apply(_ angle: CGFloat) {
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            onAngleChange?(angle)
        }
    }
}

// MARK: - Body pose

/// The joints Shaky-Shaky tracks and draws.
nonisolated enum PoseJoint: CaseIterable, Hashable, Sendable {
    case nose, neck
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case root, leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle

    var visionName: VNHumanBodyPoseObservation.JointName {
        switch self {
        case .nose: .nose
        case .neck: .neck
        case .leftShoulder: .leftShoulder
        case .rightShoulder: .rightShoulder
        case .leftElbow: .leftElbow
        case .rightElbow: .rightElbow
        case .leftWrist: .leftWrist
        case .rightWrist: .rightWrist
        case .root: .root
        case .leftHip: .leftHip
        case .rightHip: .rightHip
        case .leftKnee: .leftKnee
        case .rightKnee: .rightKnee
        case .leftAnkle: .leftAnkle
        case .rightAnkle: .rightAnkle
        }
    }

    /// Bones drawn between joints for the skeleton overlay.
    static let bones: [(PoseJoint, PoseJoint)] = [
        (.nose, .neck),
        (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.neck, .root), (.root, .leftHip), (.root, .rightHip),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]
}

/// One analysed frame: normalized joint positions (Vision's lower-left origin).
nonisolated struct PoseFrame: Sendable {
    let joints: [PoseJoint: CGPoint]
    let imageSize: CGSize
    let time: TimeInterval
}

/// Runs Vision's body-pose request on frames, throttled to ~15 fps.
nonisolated final class PoseDetector: @unchecked Sendable {
    private let request = VNDetectHumanBodyPoseRequest()
    private var lastRun: CFTimeInterval = 0

    func process(_ pixelBuffer: CVPixelBuffer) -> PoseFrame? {
        let now = CACurrentMediaTime()
        guard now - lastRun >= 1.0 / 15.0 else { return nil }
        lastRun = now

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])

        var joints: [PoseJoint: CGPoint] = [:]
        if let observation = request.results?.first,
           let points = try? observation.recognizedPoints(.all) {
            for joint in PoseJoint.allCases {
                if let point = points[joint.visionName], point.confidence > 0.3 {
                    joints[joint] = point.location
                }
            }
        }
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        return PoseFrame(joints: joints, imageSize: size, time: now)
    }
}

// MARK: - Object classification

/// Runs Vision's built-in image classifier on frames, throttled to ~4 fps.
nonisolated final class ObjectClassifier: @unchecked Sendable {
    private let request = VNClassifyImageRequest()
    private var lastRun: CFTimeInterval = 0

    /// Returns label → confidence for every label above a small threshold.
    func process(_ pixelBuffer: CVPixelBuffer) -> [String: Float]? {
        let now = CACurrentMediaTime()
        guard now - lastRun >= 0.25 else { return nil }
        lastRun = now

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
        var labels: [String: Float] = [:]
        for observation in request.results ?? [] where observation.confidence > 0.05 {
            labels[observation.identifier] = observation.confidence
        }
        return labels
    }
}

// MARK: - Shared camera UI

/// Rounded camera card with permission / availability fallbacks.
struct CameraCard<Overlay: View>: View {
    let camera: CameraPipeline
    let device: AVCaptureDevice?
    let status: CameraStatus
    var onFallback: (() -> Void)?
    @ViewBuilder var overlay: Overlay

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
            switch status {
            case .running:
                CameraPreview(camera: camera, device: device)
                overlay
            case .starting:
                ProgressView().tint(.white)
            case .denied, .unavailable:
                VStack(spacing: 12) {
                    Image(systemName: status == .denied ? "video.slash.fill" : "camera.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(status == .denied
                         ? "Wakie needs the camera for this mission. You can allow it in Settings."
                         : "No camera is available on this device.")
                        .font(.wakie(15, .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    if status == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Open Settings", destination: url)
                            .font(.wakie(15, .bold))
                            .foregroundStyle(Theme.yellow)
                    }
                    if let onFallback {
                        Button("Do Blah-Blah instead", action: onFallback)
                            .font(.wakie(15, .bold))
                            .foregroundStyle(Color(hex: 0x1E1A3C))
                            .padding(.horizontal, 18)
                            .frame(height: 40)
                            .background(Capsule().fill(Theme.yellow))
                    }
                }
                .padding(24)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(.white.opacity(0.9), lineWidth: 4))
        .shadow(color: Theme.shadow, radius: 16, y: 10)
    }
}
