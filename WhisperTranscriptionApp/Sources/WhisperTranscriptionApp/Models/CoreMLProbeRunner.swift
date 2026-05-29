import Foundation

struct CoreMLProbeResult: Sendable {
    let ok: Bool
    let elapsedMS: Int
    let requestedUnits: String
    let errorMessage: String

    var summary: String {
        "ok=\(ok) elapsed=\(elapsedMS)ms units=\(requestedUnits) error=\(errorMessage.isEmpty ? "none" : errorMessage)"
    }
}

enum CoreMLProbeRunner {
    static let slowProbeThresholdMS = 15_000

    static func run(encoderPath: String) async -> CoreMLProbeResult {
        let path = encoderPath
        return await Task.detached(priority: .utility) {
            path.withCString { cPath in
                let raw = whisper_coreml_probe(cPath)
                return CoreMLProbeResult(
                    ok: raw.ok != 0,
                    elapsedMS: Int(raw.elapsed_ms),
                    requestedUnits: Self.cString(from: raw.requested_units),
                    errorMessage: raw.ok == 0 ? Self.cString(from: raw.error_message) : ""
                )
            }
        }.value
    }

    private static func cString<T>(from buffer: T) -> String {
        withUnsafePointer(to: buffer) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { cPointer in
                String(cString: cPointer)
            }
        }
    }
}
