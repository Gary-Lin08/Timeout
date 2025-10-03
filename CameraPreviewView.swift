//
//  CameraPreviewView.swift
//  Timeout
//
//  Created by KaiJun Lin on 2025/6/17.
//

import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    @EnvironmentObject var appState: AppState
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        
        // Your original preview layer setup
        let preview = ModernCameraPreviewUIView()
        preview.session = session
        preview.frame = container.bounds
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(preview)
        
        // Add PhoneID overlay label with auto font size adjustment
        let phoneIDLabel = UILabel()
        phoneIDLabel.textAlignment = .center
        phoneIDLabel.font = .boldSystemFont(ofSize: 240) // large initial font size
        phoneIDLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        phoneIDLabel.adjustsFontSizeToFitWidth = true
        phoneIDLabel.minimumScaleFactor = 0.1  // scale down to 10% if needed
        phoneIDLabel.numberOfLines = 1
        phoneIDLabel.lineBreakMode = .byClipping
        phoneIDLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(phoneIDLabel)
        
        NSLayoutConstraint.activate([
            phoneIDLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            phoneIDLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            phoneIDLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            phoneIDLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20)
        ])
        
        // Store in context for updates
        context.coordinator.phoneIDLabel = phoneIDLabel
        
        return container
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // Update the label every time SwiftUI refreshes
        if let label = context.coordinator.phoneIDLabel {
            label.text = appState.showID ? "\(appState.phoneID)" : ""
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var phoneIDLabel: UILabel?
    }
}

class ModernCameraPreviewUIView: UIView {
    var session: AVCaptureSession? {
        didSet {
            setupPreviewLayer()
        }
    }
    
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupPreviewLayer() {
        guard let session = session else { return }
        
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        
        // 添加现代视觉效果
        layer.cornerRadius = 0
        layer.masksToBounds = true
        
        // 添加阴影效果
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 8
        
        self.layer.addSublayer(layer)
        self.previewLayer = layer
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}

// MARK: - 现代相机网格覆盖
struct ModernCameraGridOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 网格线
                Path { path in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    
                    // 垂直线
                    for i in 1...2 {
                        let x = width / 3 * CGFloat(i)
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: height))
                    }
                    
                    // 水平线
                    for i in 1...2 {
                        let y = height / 3 * CGFloat(i)
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: width, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                
                // 中心焦点框
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.6), lineWidth: 2)
                    .frame(width: 80, height: 80)
                    .scaleEffect(1.2)
            }
        }
    }
}

// MARK: - 现代相机状态指示器
struct ModernCameraStatusIndicator: View {
    let isRecording: Bool
    let recordingDuration: TimeInterval
    
    var body: some View {
        HStack(spacing: 8) {
            // 录制指示器
            Circle()
                .fill(isRecording ? .red : .clear)
                .frame(width: 8, height: 8)
                .scaleEffect(isRecording ? 1.2 : 1.0)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: isRecording)
            
            // 录制时长
            if isRecording {
                Text(formatDuration(recordingDuration))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - 现代相机控制覆盖
struct ModernCameraControlOverlay: View {
    let zoomLevel: CGFloat
    let focusPoint: CGPoint?
    let exposurePoint: CGPoint?
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 缩放指示器
                VStack {
                    HStack {
                        Text("\(String(format: "%.1f", zoomLevel))x")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                        
                        Spacer()
                    }
                    .padding(.top, 60)
                    .padding(.leading, 20)
                    
                    Spacer()
                }
                
                // 焦点指示器
                if let focusPoint = focusPoint {
                    Circle()
                        .stroke(Color.yellow, lineWidth: 2)
                        .frame(width: 60, height: 60)
                        .position(
                            x: focusPoint.x * geometry.size.width,
                            y: focusPoint.y * geometry.size.height
                        )
                        .animation(.easeInOut(duration: 0.3), value: focusPoint)
                }
                
                // 曝光指示器
                if let exposurePoint = exposurePoint {
                    Circle()
                        .stroke(Color.blue, lineWidth: 2)
                        .frame(width: 40, height: 40)
                        .position(
                            x: exposurePoint.x * geometry.size.width,
                            y: exposurePoint.y * geometry.size.height
                        )
                        .animation(.easeInOut(duration: 0.3), value: exposurePoint)
                }
            }
        }
    }
}
