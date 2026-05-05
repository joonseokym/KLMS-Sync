import CoreImage
import Foundation
import Vision

if CommandLine.arguments.count != 2 {
    fputs("usage: swift decode_qr_image.swift /path/to/qr-image\n", stderr)
    exit(2)
}

let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = CIImage(contentsOf: imageURL) else {
    fputs("failed to load image\n", stderr)
    exit(1)
}

let request = VNDetectBarcodesRequest()
request.symbologies = [.qr]

let handler = VNImageRequestHandler(ciImage: image, options: [:])

do {
    try handler.perform([request])
} catch {
    fputs("barcode detection failed: \(error)\n", stderr)
    exit(1)
}

let payload = request.results?
    .compactMap { $0.payloadStringValue }
    .first { !$0.isEmpty }

guard let payload else {
    fputs("no QR payload found\n", stderr)
    exit(1)
}

print(payload)
