// "showcase.swift" (build.zig, -Dswift_example): the echo extension in
// Swift, for iOS. An @objc class conforming to OrielAppExtension
// (oriel_extension.h is the bridging header); @objc(Name) keeps the class
// name Oriel looks up unmangled.

import Foundation

@objc(ShowcaseSwiftExtension)
final class ShowcaseSwiftExtension: NSObject, OrielAppExtension {
    func callMethod(_ method: String, input: Data, call: OrielCall) throws -> Data {
        guard method == "reverse" else {
            throw NSError(domain: "unknown_method", code: 1, userInfo: [NSLocalizedDescriptionKey: "showcase.swift has no method \(method)"])
        }
        guard let args = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let text = args["text"] as? String else {
            throw NSError(domain: "bad_input", code: 1, userInfo: [NSLocalizedDescriptionKey: "expected {\"text\": \"...\"}"])
        }
        // Characters are grapheme clusters: emoji stay whole.
        let reply = try JSONSerialization.data(withJSONObject: [
            "text": String(text.reversed()),
            "platform": "Swift on iOS",
            "device": ProcessInfo.processInfo.operatingSystemVersionString,
        ])
        call.emit("reversed", data: reply)
        return reply
    }
}
