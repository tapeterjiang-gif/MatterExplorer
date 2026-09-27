import SwiftUI
import VisionKit

/// VisionKit DataScanner 桥接：扫描 Matter QR 码并回传 onboarding payload 字符串。
/// 模拟器不支持 DataScanner，调用前需检查 `DataScannerViewController.isSupported`。
struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .fast,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: QRScannerView
        init(parent: QRScannerView) { self.parent = parent }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard case let .barcode(barcode) = addedItems.first,
                  let text = barcode.payloadStringValue else { return }
            parent.onScan(text)
        }
    }
}
