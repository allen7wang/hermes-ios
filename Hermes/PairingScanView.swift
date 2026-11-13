import AVFoundation
import SwiftUI
import UIKit

struct PairingScanView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var errorText: String?
    @State private var unavailableText: String?
    @State private var saved = false
    @State private var resetToken = 0

    var body: some View {
        ZStack {
            HermesTheme.background.ignoresSafeArea()
            if unavailableText == nil {
                PairingScanner(resetToken: resetToken, onUnavailable: { unavailableText = $0 }) { raw in
                    accept(raw)
                }
                .ignoresSafeArea()
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(HermesTheme.accent, lineWidth: 2)
                    .frame(width: 240, height: 240)
                    .allowsHitTesting(false)
            }
            VStack {
                Spacer()
                scanStatus
            }
        }
        .navigationTitle("扫码添加连接")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var scanStatus: some View {
        if unavailableText != nil {
            ContentUnavailableView(unavailableText ?? "无法使用相机", systemImage: "camera.slash")
        } else {
            VStack(spacing: 12) {
                if errorText != nil {
                    Text(errorText ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
                    Button("重新扫描") {
                        errorText = nil
                        resetToken += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HermesTheme.accent)
                }
                Text("将配对码放入取景框")
                    .font(.footnote).foregroundStyle(.white)
                Text("相机画面只在设备上处理，不会上传。")
                    .font(.caption).foregroundStyle(HermesTheme.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private func accept(_ raw: String) -> Bool {
        guard !saved else { return true }
        do {
            let payload = try PairingPayload.decode(raw)
            let connection = ConnectionSettings(
                serverURL: payload.url,
                model: "hermes-agent",
                apiKey: payload.key
            )
            let id = try model.saveProfile(id: nil, name: payload.name, connection: connection)
            guard model.selectProfile(id) else {
                errorText = "已保存，但无法切换到该连接。"
                return false
            }
            saved = true
            errorText = nil
            dismiss()
            return true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "配对码无效。"
            return false
        }
    }
}

private struct PairingScanner: UIViewControllerRepresentable {
    var resetToken: Int
    var onUnavailable: (String) -> Void
    var onCode: (String) -> Bool

    func makeUIViewController(context: Context) -> PairingScanController {
        let controller = PairingScanController()
        controller.onUnavailable = onUnavailable
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: PairingScanController, context: Context) {
        controller.onUnavailable = onUnavailable
        controller.onCode = onCode
        if context.coordinator.token != resetToken {
            context.coordinator.token = resetToken
            controller.reset()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var token = -1
    }
}

final class PairingScanController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Bool)?
    var onUnavailable: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.a7w.hermes.pairing-scan")
    private var preview: AVCaptureVideoPreviewLayer?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var delivered: String?
    private var latest: String?
    private var configured = false
    private var isVisible = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard self?.isVisible == true else { return }
                    if granted { self?.configure() }
                    else { self?.onUnavailable?("需要相机权限才能扫描配对码。请在系统设置中允许 Hermes 使用相机。") }
                }
            }
        default:
            fail("需要相机权限才能扫描配对码。请在系统设置中允许 Hermes 使用相机。")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        updateOrientation()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        if !configured && AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            configure()
        } else {
            start()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        stop()
    }

    deinit {
        let session = session
        if session.isRunning { queue.async { session.stopRunning() } }
    }

    func reset() {
        delivered = nil
        latest = nil
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue,
              !value.isEmpty else { return }
        latest = value
        deliver(value)
    }

    private func deliver(_ value: String) {
        guard value != delivered else { return }
        delivered = value
        if onCode?(value) == true { stop() }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onUnavailable?(message) }
    }

    private func configure() {
        guard isVisible else { return }
        guard !configured else { start(); return }
        let discovered = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
        guard let device = discovered else {
            fail("此设备没有相机，无法扫码。")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                fail("无法打开相机。")
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                fail("无法读取二维码。")
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            session.commitConfiguration()
            metadataOutput = output
            enableQR(output)
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.insertSublayer(layer, at: 0)
            preview = layer
            configured = true
            start()
        } catch {
            fail("无法打开相机。")
        }
    }

    private func enableQR(_ output: AVCaptureMetadataOutput) {
        guard output.availableMetadataObjectTypes.contains(.qr) else { return }
        output.metadataObjectTypes = [.qr]
    }

    private func start() {
        guard configured, isVisible else { return }
        queue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async { [weak self] in
                guard let self, let output = self.metadataOutput else { return }
                self.enableQR(output)
            }
        }
    }

    private func stop() {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func updateOrientation() {
        guard let connection = preview?.connection else { return }
        let angle: CGFloat
        switch view.window?.windowScene?.interfaceOrientation {
        case .landscapeLeft: angle = 180
        case .landscapeRight: angle = 0
        case .portraitUpsideDown: angle = 270
        default: angle = 90
        }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }
}
