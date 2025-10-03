import Foundation
import AVFoundation
import Photos
import SwiftUI
import YOLO
import CoreMedia

struct DetectionResult {
    let timestamp: CMTime
    let centers: [CGPoint]
}

// 1. 添加自定义通知名称
extension Notification.Name {
    static let videoRecordingFinished = Notification.Name("videoRecordingFinished")
}

class CameraManager: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.myapp.camera.sessionQueue")
    @Published var currentZoomFactor: CGFloat = 1.0
    let minZoomFactor: CGFloat = 1.0
    let maxZoomFactor: CGFloat = 5.0

    private var currentPosition: AVCaptureDevice.Position = .back
    private var videoInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private var assetWriter: AVAssetWriter?
    private var videoInputWriter: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var asset: AVAsset?
    private var recordingStartTime: CMTime?
    private var lastTimestamp: CMTime = .zero
    private var yolo = YOLO("yolo11s", task: .detect)
    private let inferenceQueue = DispatchQueue(label: "com.myapp.inferenceQueue", qos: .userInitiated)
    private var isModelBusy = false
    private var detectionResults: [DetectionResult] = []
    private var lastKnownCenters: [CGPoint] = []
    private let ciContext = CIContext()
    private var YOLOEnabled = false
    private var finishedProcessing = true
    
    private var audioInput: AVCaptureDeviceInput?
    private let audioOutput = AVCaptureAudioDataOutput()
    private var audioInputWriter: AVAssetWriterInput?

    @Published var isRecording = false
    @Published var cropping_ratio: CGFloat = 0.5
    @Published var selectedResolution: String = "4K"
    @Published var selectedFrameRate: String = "30"
    private let inferenceControl = InferenceControl()
    @Published var isSlowMotionEnabled = false
    private var slowMotionFrameCount = 0
    
    // 用于存储视频URL
    @Published var selectedVideoURL: URL? = nil
    @Published var originalVideoURL: URL? = nil
    @Published var processedVideoURL: URL? = nil
    
    
    actor InferenceControl {
        private var isBusy = false

        func checkAndSetBusy() -> Bool {
            if isBusy {
                return false
            } else {
                isBusy = true
                return true
            }
        }

        func resetBusy() {
            isBusy = false
        }
    }

    override init() {
        super.init()
        reconfigureSession()
        yolo.setConfidence(conf: 0.70)
    }

    public func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        print("Recording started.")
    }
    
    public func enablePersonTracking(enable: Bool){
        if enable{
            YOLOEnabled = true
        }
        else{
            YOLOEnabled = false
        }
        
    }
    

    public func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        // Stop accepting more buffers *before* marking finished.
        videoInputWriter?.markAsFinished()
        audioInputWriter?.markAsFinished()   // <-- add this

        // Optionally cap the session time at the last frame
        if lastTimestamp != .zero {
            assetWriter?.endSession(atSourceTime: lastTimestamp)
        }

        let outputURL = assetWriter?.outputURL
        assetWriter?.finishWriting { [weak self] in
            guard let self = self, let finalURL = outputURL else { return }

            // Inspect errors if writing failed
            if let error = self.assetWriter?.error {
                print("❌ AVAssetWriter error: \(error.localizedDescription)")
            }

            self.saveToPhotos(url: finalURL)

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .videoRecordingFinished,
                    object: nil,
                    userInfo: ["url": finalURL]
                )
            }

            // Clean up
            self.assetWriter = nil
            self.videoInputWriter = nil
            self.audioInputWriter = nil
            self.adaptor = nil
            self.recordingStartTime = nil
        }
    }
    
    private func saveToPhotos(url: URL) {
        PHPhotoLibrary.requestAuthorization { status in
            if status == .authorized || status == .limited {
                if self.YOLOEnabled{
                    let processor = GenerateVideo(cropFraction: self.cropping_ratio)
                    processor.setInput(videoURL: url, detectionResults: self.detectionResults)
//                    processor.startProcessing { processedURL in
//                        PHPhotoLibrary.shared().performChanges({
//                            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: processedURL!)
//                        }) { saved, err in
//                            if saved {
//                                print("✅ 处理后的视频已保存到相册")
//                                self.selectedVideoURL = processedURL
//                            } else {
//                                print("❌ 保存失败：\(String(describing: err))")
//                            }
//                        }
//                    }
                    processor.startProcessing { processedURL in
                        guard let processedURL else {
                            print("❌ Processing failed: processedURL is nil")
                            return
                        }
                        PHPhotoLibrary.shared().performChanges({
                            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: processedURL)
                        }) { saved, err in
                            if saved {
                                self.originalVideoURL = url
                                self.processedVideoURL = processedURL
                            } else {
                                print("❌ Save failed: \(String(describing: err))")
                            }
                        }
                    }
                }
                else{
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    }) { saved, err in
                        if saved {
                            print("✅ 视频已保存到相册")
                            self.originalVideoURL = url
                            self.processedVideoURL = url
                            print(self.detectionResults)
                        } else {
                            print("❌ 保存失败：\(String(describing: err))")
                        }
                    }
                }
                
            }
        }
    }
    
    


    // 配置视频捕捉
    public func configureSession() {
        session.beginConfiguration()

        switch selectedResolution {
        case "4K": session.sessionPreset = .hd4K3840x2160
        case "720p": session.sessionPreset = .hd1280x720
        default: session.sessionPreset = .hd1920x1080
        }

        if let input = videoInput {
            session.removeInput(input)
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentPosition) else {
            print("❌ Failed to get video device")
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                self.videoInput = input

                // 慢动作模式使用更高帧率
                let desiredFPS: Int
                if isSlowMotionEnabled {
                    desiredFPS = 120 // 慢动作使用120fps
                    print("🎬 配置慢动作相机：120fps")
                } else {
                    desiredFPS = Int(selectedFrameRate) ?? 30
                }
                let widthTarget: Int = {
                    switch selectedResolution {
                    case "4K": return 3840
                    case "720p": return 1280
                    default: return 1920
                    }
                }()
                let heightTarget: Int = widthTarget * 9 / 16

                try device.lockForConfiguration()
                let suitableFormat = device.formats.filter { format in
                    let desc = format.formatDescription
                    let dims = CMVideoFormatDescriptionGetDimensions(desc)
                    let range = format.videoSupportedFrameRateRanges.first
                    return dims.width == widthTarget && dims.height == heightTarget && (range?.maxFrameRate ?? 0) >= Double(desiredFPS)
                }.max(by: { lhs, rhs in
                    lhs.formatDescription.dimensions.width < rhs.formatDescription.dimensions.width
                })

                if let formatToSet = suitableFormat {
                    device.activeFormat = formatToSet
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(desiredFPS))
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(desiredFPS))
                    print("✅ Format set to: \(formatToSet)")
                } else {
                    print("⚠️ No matching format found for \(selectedResolution) @ \(desiredFPS)fps")
                }
                device.unlockForConfiguration()
            }
        } catch {
            print("❌ Error configuring device input: \(error)")
        }

        if session.canAddOutput(videoOutput) {
            videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = false
            session.addOutput(videoOutput)
        }
        
        if let existingAudioInput = audioInput {
            session.removeInput(existingAudioInput)
        }

        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            do {
                let newAudioInput = try AVCaptureDeviceInput(device: audioDevice)
                if session.canAddInput(newAudioInput) {
                    session.addInput(newAudioInput)
                    audioInput = newAudioInput
                }
            } catch {
                print("❌ Error setting up audio input: \(error)")
            }
        }

        // Audio output
        if session.canAddOutput(audioOutput) {
            audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            session.addOutput(audioOutput)
        }

        session.commitConfiguration()
        setZoomFactor(factor: 1.0)
    }

    public func reconfigureSession() {
        sessionQueue.async {
            self.configureSession()
            self.session.startRunning()
        }
    }
    
    public func setZoomFactor(factor: CGFloat) {
        let safeFactor = max(minZoomFactor, min(factor, maxZoomFactor))
        currentZoomFactor = safeFactor
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentPosition) {
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = safeFactor
                device.unlockForConfiguration()
            } catch {
                print("设置缩放失败: \(error)")
            }
        }
    }
    
    public func setCroppingRatio(factor: CGFloat){
        self.cropping_ratio = factor
    }

    public func switchCamera() {
        currentPosition = (currentPosition == .back) ? .front : .back
        reconfigureSession()
    }
    
    public func toggleSlowMotion() {
        isSlowMotionEnabled.toggle()
        print("🎬 慢动作模式: \(isSlowMotionEnabled ? "开启" : "关闭")")
        reconfigureSession()
    }

    public func startRecordingWithCountdown(delay: Double = 0, duration: Double = 10) {
        detectionResults = []
        lastKnownCenters = [CGPoint(x: 0, y: 0)]
        if isRecording { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startAssetWriter()
            self?.isRecording = true

            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                self?.stopRecording()
            }
        }
    }

    public func startAssetWriter() {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        do {
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

            guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentPosition) else {
                print("❌ Failed to get video device for encoder settings")
                return
            }

            let dimensions = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
            let width = Int(dimensions.width)
            let height = Int(dimensions.height)

            // 慢动作设置：使用更高的帧率
            let targetFrameRate: Int
            if isSlowMotionEnabled {
                targetFrameRate = 120 // 慢动作使用120fps
                print("🎬 启用慢动作模式：120fps")
            } else {
                targetFrameRate = 30 // 正常模式使用30fps
            }
            
            
            let codec: AVVideoCodecType = AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality)
                ? .hevc
                : .h264
            // or check device.supportsSessionPreset/availableVideoCodecTypes

            let outputSettings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 5_000_000,
                    AVVideoExpectedSourceFrameRateKey: targetFrameRate
                ]
            ]
        
            
            // 慢动作模式：设置播放帧率为正常速度的1/4
            if isSlowMotionEnabled {
                print("🎬 慢动作模式：录制帧率 \(targetFrameRate)fps，播放帧率 \(targetFrameRate/4)fps")
            }

            videoInputWriter = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
//            videoInputWriter?.transform = CGAffineTransform(rotationAngle: .pi / 2)
            if currentPosition == .front {
                // Rotate 90 degrees + horizontal flip
                let rotation = CGAffineTransform(rotationAngle: .pi / 2)
                let mirror = CGAffineTransform(scaleX: -1, y: 1) // flip horizontally
                videoInputWriter?.transform = rotation.concatenating(mirror)
            } else {
                // Only rotate 90 degrees for back camera
                videoInputWriter?.transform = CGAffineTransform(rotationAngle: .pi / 2)
            }
            videoInputWriter?.expectsMediaDataInRealTime = true

            if let videoInputWriter = videoInputWriter, assetWriter!.canAdd(videoInputWriter) {
                assetWriter!.add(videoInputWriter)
                adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInputWriter, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                ])
                
            }
        } catch {
            print("❌ 初始化 AVAssetWriter 失败: \(error)")
        }
        
        // 慢动作音频设置：降低音频采样率以匹配慢动作效果
        let audioSampleRate: Int
        if isSlowMotionEnabled {
            audioSampleRate = 22050 // 慢动作使用较低的音频采样率
        } else {
            audioSampleRate = 44100 // 正常模式
        }
        
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000
        ]

        audioInputWriter = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInputWriter?.expectsMediaDataInRealTime = true

        if let audioInputWriter = audioInputWriter, assetWriter!.canAdd(audioInputWriter) {
            assetWriter!.add(audioInputWriter)
        }
        assetWriter!.startWriting()
        recordingStartTime = nil
    }
    
    
    private func runYOLO(on pixelBuffer: CVPixelBuffer, at timestamp: CMTime, completion: @escaping () -> Void) {
        defer { completion() }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            print("❌ Could not create CGImage from pixel buffer")
            self.detectionResults.append(DetectionResult(timestamp: timestamp, centers: self.lastKnownCenters))
            return
        }

        let uiImage = UIImage(cgImage: cgImage)
        let result = yolo(uiImage)  // Run your YOLO model

        print("🟡 Detections at \(CMTimeGetSeconds(timestamp)):")
        for box in result.boxes {
            print("    class: \(box.cls), rect: \(box.xywh)")
        }

        // Collect all 'person' detections
        let personCenters: [CGPoint] = result.boxes
            .filter { $0.cls == "person" }
            .map { box in
                let rect = box.xywh
                return CGPoint(x: rect.midX, y: rect.midY)
            }

        // If no detections, use last known
        let centersToUse: [CGPoint] = personCenters.isEmpty ? lastKnownCenters : personCenters

        // Update last known if detections exist
        if !personCenters.isEmpty {
            lastKnownCenters = personCenters
        }

        detectionResults.append(DetectionResult(timestamp: timestamp, centers: centersToUse))

        DispatchQueue.main.async {
            print("Time: \(CMTimeGetSeconds(timestamp))")
            print("Centers: \(centersToUse)")
        }
    }
    
    func pixelBufferToUIImage(_ pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        
        if let cgImage = context.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: width, height: height)) {
            return UIImage(cgImage: cgImage)
        } else {
            print("❌ Failed to convert pixel buffer to UIImage")
            return nil
        }
    }
    
    func filterCumulativeJumps(centers: [CGPoint?], windowSize: Int, maxDeviation: CGFloat) -> [CGPoint?] {
        var filtered: [CGPoint?] = []
        var buffer: [CGPoint?] = []
        
        for pt in centers {
            if let pt = pt {
                let validBuffer = buffer.suffix(windowSize).compactMap { $0 }
                if !validBuffer.isEmpty {
                    let meanX = validBuffer.map { $0.x }.reduce(0, +) / CGFloat(validBuffer.count)
                    let meanY = validBuffer.map { $0.y }.reduce(0, +) / CGFloat(validBuffer.count)
                    let dist = hypot(pt.x - meanX, pt.y - meanY)
                    if dist > maxDeviation {
                        filtered.append(nil)
                        buffer.append(nil)
                        continue
                    }
                }
                filtered.append(pt)
                buffer.append(pt)
            } else {
                filtered.append(nil)
                buffer.append(nil)
            }
        }
        return filtered
    }
    
    func medianFilterCenters(centers: [CGPoint?], kernelSize: Int) -> [CGPoint] {
        func interpolate(_ arr: [CGFloat?]) -> [CGFloat] {
            var filled = arr.map { $0 ?? .nan }
            let indices = filled.indices
            let validIndices = indices.filter { !filled[$0].isNaN }
            for i in filled.indices where filled[i].isNaN {
                if let prev = validIndices.last(where: { $0 < i }),
                   let next = validIndices.first(where: { $0 > i }) {
                    let interp = filled[prev] + (filled[next] - filled[prev]) * CGFloat(i - prev) / CGFloat(next - prev)
                    filled[i] = interp
                }
            }
            return filled.map { $0.isNaN ? 0 : $0 }
        }
        
        let xs: [CGFloat?] = centers.map { $0?.x }
        let ys: [CGFloat?] = centers.map { $0?.y }
        let ix = interpolate(xs)
        let iy = interpolate(ys)
        
        func medianSmooth(_ data: [CGFloat], kernel: Int) -> [CGFloat] {
            let radius = kernel / 2
            return data.indices.map { i in
                let lower = max(0, i - radius)
                let upper = min(data.count - 1, i + radius)
                let window = Array(data[lower...upper]).sorted()
                return window[window.count / 2]
            }
        }
        
        let sx = medianSmooth(ix, kernel: kernelSize)
        let sy = medianSmooth(iy, kernel: kernelSize)
        
        return zip(sx, sy).map { CGPoint(x: $0.0, y: $0.1) }
    }
    
    public func processVideoURL(_ videoURL: URL) -> [CGPoint?]?{
        finishedProcessing = false
        self.asset = AVURLAsset(url: videoURL)
        var centers: [CGPoint?] = []
        
        guard let asset = asset,
              let track = asset.tracks(withMediaType: .video).first else {
            print("❌ Asset or track not set.")
            finishedProcessing = true
            return nil
        }
        
        do {
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            
            guard reader.canAdd(output) else {
                print("❌ Cannot add output to reader.")
                return nil
            }
            
            reader.add(output)
            reader.startReading()  // ✅ make sure this is called before reading samples
            
            let frameSkip = 20
            var frameCount = 0
            var center = CGPoint(x: 0, y: 0)
            
            while reader.status == .reading {
                autoreleasepool {
                    guard let sampleBuffer = output.copyNextSampleBuffer() else { return }
                    
                    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        if frameCount % (frameSkip + 1) == 0 {
                            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                            if let image = pixelBufferToUIImage(pixelBuffer) {
                                let result = yolo(image)
                                if let personBox = result.boxes.first(where: { $0.cls == "person" }) {
                                    let bbox = personBox.xywh
                                    center = CGPoint(x: bbox.midX, y: bbox.midY)
                                    centers.append(center)
                                } else {
                                    centers.append(center)
                                }
                            } else {
                                centers.append(nil)
                            }
                            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                        } else {
                            centers.append(nil) // skipped frame
                        }
                        
                        frameCount += 1
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
            }
            
            let filteredCenters = filterCumulativeJumps(centers: centers, windowSize: 10, maxDeviation: 40)
            let smoothedCenters = medianFilterCenters(centers: filteredCenters, kernelSize: 5)
            
            return smoothedCenters;
            
        } catch {
            finishedProcessing = true
            print("❌ Error during processing: \(error)")
            return nil
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording, let writer = assetWriter else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if recordingStartTime == nil {
            writer.startSession(atSourceTime: timestamp)
            recordingStartTime = timestamp
        }
        
        // 慢动作模式：调整时间戳以实现慢动作效果
        let adjustedTimestamp: CMTime
        if isSlowMotionEnabled {
            // 将时间戳延长4倍，实现4倍慢动作
            let timeOffset = CMTimeSubtract(timestamp, recordingStartTime!)
            let slowMotionTime = CMTimeMultiplyByFloat64(timeOffset, multiplier: 4.0)
            adjustedTimestamp = CMTimeAdd(recordingStartTime!, slowMotionTime)
            
            // 调试信息：每100帧打印一次时间戳信息
            slowMotionFrameCount += 1
            if slowMotionFrameCount % 100 == 0 {
                print("🎬 慢动作时间戳调整: 原始=\(CMTimeGetSeconds(timestamp)), 调整后=\(CMTimeGetSeconds(adjustedTimestamp))")
            }
        } else {
            adjustedTimestamp = timestamp
        }

        if output == videoOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let adaptor = adaptor,
                  videoInputWriter?.isReadyForMoreMediaData == true else { return }
            

            if lastTimestamp != .zero {
                let delta = CMTimeSubtract(timestamp, lastTimestamp)
                let fps = 1.0 / CMTimeGetSeconds(delta)
                print("📸 Instantaneous FPS: \(fps)")
            }
            lastTimestamp = timestamp
            

            adaptor.append(pixelBuffer, withPresentationTime: adjustedTimestamp)
            if writer.status == .failed || writer.status == .cancelled {
                print("Writer failed/cancelled: \(writer.error?.localizedDescription ?? "unknown")")
            }
            
            Task {
                    let canRun = await inferenceControl.checkAndSetBusy()
                    if canRun && YOLOEnabled {
                        let bufferCopy = pixelBuffer
                        let frameTimestamp = timestamp

                        inferenceQueue.async { [weak self] in
                            self?.runYOLO(on: bufferCopy, at: frameTimestamp) {
                                Task {
                                    await self?.inferenceControl.resetBusy()
                                }
                            }
                        }
                    }
                }
            
        } else if output == audioOutput {
            guard audioInputWriter?.isReadyForMoreMediaData == true else { return }
            
            // 慢动作模式：暂时跳过音频处理，专注于视频慢动作效果
            if !isSlowMotionEnabled {
                audioInputWriter?.append(sampleBuffer)
            }
        }
    }
}
