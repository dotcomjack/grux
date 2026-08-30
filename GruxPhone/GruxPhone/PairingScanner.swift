import SwiftUI
import AVFoundation

// AVFoundation QR scanner. Wraps AVCaptureVideoPreviewLayer in a SwiftUI
// view and emits parsed pairing info back via the `onScanned` callback.
//
// Not fancy. Uses the back camera at its native resolution, continuous auto-
// focus, emits one decode, stops. Scanning a Mac screen from ~40 cm works
// reliably because AVCaptureMetadataOutput decodes even at small QR sizes.
struct PairingScannerView: UIViewControllerRepresentable {
    let onScanned: (PhonePairingURL.Info) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> PairingScannerVC {
        let vc = PairingScannerVC()
        vc.onScanned = { raw in
            guard let info = PhonePairingURL.parse(raw) else {
                onError("Not a valid Grux pairing QR")
                return
            }
            onScanned(info)
        }
        vc.onError = onError
        return vc
    }

    func updateUIViewController(_ uiViewController: PairingScannerVC, context: Context) {}
}

final class PairingScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var didEmit = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted { self.startSession() } else {
                    self.onError?("Camera access denied")
                }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.stopRunning()
        }
    }

    private func startSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            onError?("No camera device found")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                onError?("Cannot add camera input"); return
            }
            session.addInput(input)
        } catch {
            onError?("Camera init failed: \(error.localizedDescription)")
            return
        }

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onError?("Cannot add metadata output"); return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.preview = preview

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didEmit else { return }
        for obj in metadataObjects {
            if let r = obj as? AVMetadataMachineReadableCodeObject, r.type == .qr, let s = r.stringValue {
                didEmit = true
                onScanned?(s)
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.session.stopRunning()
                }
                break
            }
        }
    }
}
