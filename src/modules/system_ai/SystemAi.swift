// oriel.system_ai on iOS (src/modules/system_ai.zig): Apple Foundation
// Models, the on-device model of Apple Intelligence (iOS 26+). Oriel's own
// app extension "oriel.system_ai", compiled by swiftc only with -Dsystem_ai
// (build.zig, orielExtensions). FoundationModels is weak-linked, and only
// when the SDK has it: with an older SDK (Xcode 16) this compiles to a
// backend that reports "unavailable".
//
// Methods (JSON replies; the wire format is in src/modules/system_ai/core.zig):
// "status", "capabilities", "download", "generate". Events: "token" (the
// reply's next piece, UTF-8). Failures are NSErrors whose domain is one of
// core.zig's codes (unavailable, not_ready, busy, cancelled, timeout,
// too_large, invalid_request); Zig sees "<domain>:<code>".

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@objc(OrielSystemAiExtension) // unmangled, for objc_getClass
final class OrielSystemAiExtension: NSObject, OrielAppExtension {
    /// One generate at a time; status answers meanwhile (two workers).
    private let busy = NSLock()

    func callMethod(_ method: String, input: Data, call: OrielCall) throws -> Data {
        let reply: [String: Any]
        switch method {
        case "status":
            reply = status()
        case "capabilities":
            // Text only in this first release; the context window is 4096 tokens.
            reply = ["images": false, "max_images": 0, "streaming": true, "structured_output": false, "max_input_tokens": hasModel() ? 4096 : 0]
        case "download":
            // Apple Intelligence downloads the model itself: nothing to start.
            let s = status()
            switch s["state"] as? String {
            case "available": reply = s
            case "downloading": throw failure("not_ready", s["reason"] as? String ?? "")
            default: throw failure("unavailable", s["reason"] as? String ?? "")
            }
        case "generate":
            guard busy.try() else { throw failure("busy", "System AI is already generating") }
            defer { busy.unlock() }
            reply = try generate(input, call: call)
        default:
            throw failure("invalid_request", "no method \(method)")
        }
        return try JSONSerialization.data(withJSONObject: reply)
    }

    private func failure(_ code: String, _ message: String) -> NSError {
        NSError(domain: code, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func hasModel() -> Bool {
        (status()["state"] as? String) == "available"
    }

    private func status() -> [String: Any] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return ["state": "available", "reason": "Apple Intelligence's model is ready on this device."]
            case .unavailable(.deviceNotEligible):
                return ["state": "unavailable", "reason": "This device can't run Apple Intelligence."]
            case .unavailable(.appleIntelligenceNotEnabled):
                return ["state": "unavailable", "reason": "Apple Intelligence is turned off: turn it on in Settings."]
            case .unavailable(.modelNotReady):
                return ["state": "downloading", "reason": "Apple Intelligence is getting its model ready: try again later."]
            case .unavailable(let other):
                return ["state": "unavailable", "reason": "Apple Intelligence's model is unavailable (\(other))."]
            }
        }
        return ["state": "unavailable", "reason": "System AI needs iOS 26 with Apple Intelligence."]
        #else
        return ["state": "unavailable", "reason": "This app was built without Foundation Models: it needs the iOS 26 SDK (Xcode 26)."]
        #endif
    }

    private func generate(_ input: Data, call: OrielCall) throws -> [String: Any] {
        let request = try WireRequest(input)
        if !request.images.isEmpty {
            throw failure("invalid_request", "Foundation Models takes text only: send the request without images (capabilities().images is false)")
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let s = status()
            switch s["state"] as? String {
            case "available": break
            case "downloading": throw failure("not_ready", s["reason"] as? String ?? "")
            default: throw failure("unavailable", s["reason"] as? String ?? "")
            }
            var instructions = request.system
            if let schema = request.schema {
                instructions += (instructions.isEmpty ? "" : "\n\n") + "Answer with JSON only, following this JSON schema:\n" + schema
            }
            let options = GenerationOptions(temperature: Double(request.temperature), maximumResponseTokens: request.maxTokens)
            let prompt = request.prompt
            let stream = request.stream
            let text: String = try blocking(call: call, timeout: 180) {
                let session = instructions.isEmpty ? LanguageModelSession() : LanguageModelSession(instructions: instructions)
                if !stream {
                    return try await session.respond(to: prompt, options: options).content
                }
                // Each snapshot is the reply so far: emit what's new.
                var sent = ""
                for try await snapshot in session.streamResponse(to: prompt, options: options) {
                    let now = snapshot.content
                    if now.count > sent.count, now.hasPrefix(sent) {
                        let piece = String(now.dropFirst(sent.count))
                        call.emit("token", data: Data(piece.utf8))
                    }
                    sent = now
                    if sent.utf8.count > 1 << 20 { break }
                }
                return sent
            }
            if text.utf8.count > 1 << 20 { throw failure("too_large", "the reply is over 1 MiB") }
            return ["text": text]
        }
        #endif
        throw failure("unavailable", (status()["reason"] as? String) ?? "System AI is unavailable")
    }

    /// Runs async `body` from this synchronous call: polls the Zig caller's
    /// cancel every 100 ms and gives up after `timeout` seconds.
    private func blocking<T>(call: OrielCall, timeout: TimeInterval, _ body: @escaping () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        let task = Task.detached {
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            done.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        // Ends: the task signals, or the caller cancels, or the deadline passes.
        while done.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            if call.cancelled {
                task.cancel()
                throw failure("cancelled", "cancelled")
            }
            if Date() >= deadline {
                task.cancel()
                throw failure("timeout", "System AI didn't finish within \(Int(timeout)) s")
            }
        }
        switch box.result {
        case .success(let value)?: return value
        case .failure(let error)?:
            if error is CancellationError { throw failure("cancelled", "cancelled") }
            throw failure("failed", error.localizedDescription)
        case nil: throw failure("failed", "no result")
        }
    }
}

/// The task's outcome, written once before the semaphore signals.
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// generate's input: u32 LE header length, the JSON header, the images' bytes.
private struct WireRequest {
    var system = ""
    var prompt = ""
    var images: [Data] = []
    var temperature: Float = 0.2
    var maxTokens = 1024
    var schema: String?
    var stream = false

    init(_ input: Data) throws {
        let bytes = [UInt8](input)
        guard bytes.count >= 4 else { throw Self.bad("a truncated request") }
        let n = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        guard n <= bytes.count - 4,
              let header = try JSONSerialization.jsonObject(with: Data(bytes[4..<(4 + n)])) as? [String: Any]
        else { throw Self.bad("a malformed request") }
        system = header["system"] as? String ?? ""
        prompt = header["prompt"] as? String ?? ""
        temperature = (header["temperature"] as? NSNumber)?.floatValue ?? 0.2
        maxTokens = (header["max_tokens"] as? NSNumber)?.intValue ?? 1024
        schema = header["schema"] as? String
        stream = header["stream"] as? Bool ?? false
        var at = 4 + n
        for image in (header["images"] as? [[String: Any]] ?? []).prefix(4) {
            let size = (image["size"] as? NSNumber)?.intValue ?? -1
            guard size >= 0, size <= bytes.count - at else { throw Self.bad("a truncated image") }
            images.append(Data(bytes[at..<(at + size)]))
            at += size
        }
    }

    static func bad(_ message: String) -> NSError {
        NSError(domain: "invalid_request", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
