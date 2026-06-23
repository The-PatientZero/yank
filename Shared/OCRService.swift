import Vision
import CoreGraphics
import os

private let ocrLog = Logger(subsystem: "com.thepatientzero.yank", category: "ocr")

/// On-device text recognition (Apple Vision), shared by macOS and iOS. Works on a
/// `CGImage` — Sendable, so callers convert their platform image on their own actor
/// and only the bitmap crosses into the recognition task.
final class OCRService: Sendable {
    static let shared = OCRService()

    private init() {}

    /// Recognise text in a `CGImage`. Returns the joined lines, or nil if none found.
    func recognizeText(from cgImage: CGImage) async -> String? {
        await Task.detached(priority: .userInitiated) {
            await withCheckedContinuation { continuation in
                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        ocrLog.error("Recognition error: \(error.localizedDescription, privacy: .public)")
                        continuation.resume(returning: nil)
                        return
                    }
                    guard let observations = request.results as? [VNRecognizedTextObservation] else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    ocrLog.error("Handler error: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: nil)
                }
            }
        }.value
    }
}

