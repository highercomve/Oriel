// The showcase's Swift platform hooks (build.zig, -Dswift_example), for iOS
// and macOS: an @objc class conforming to OrielPlatformHooks (oriel_swift.h
// is the bridging header); @objc(Name) keeps the class name Oriel looks up
// unmangled. It only logs: the Objective-C ShowcaseHooks, declared first,
// owns the example.com navigation. The log lines start with
// "showcase.swift_hooks:".
//
// It also imports CoreML, CoreGraphics and Metal: their Swift overlays and
// frameworks must link without being declared anywhere (build/swift.zig:
// linkRuntime, linkImportedFrameworks).

import CoreGraphics
import CoreML
import Foundation
import Metal
import WebKit

@objc(ShowcaseSwiftHooks)
final class ShowcaseSwiftHooks: NSObject, OrielPlatformHooks {
    func registered(_ context: OrielHooksContext) {
        NSLog("showcase.swift_hooks: registered %@", context.name)
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let rect = CGRect(x: 0, y: 0, width: 16, height: 9).insetBy(dx: 1, dy: 1)
        let gpu = MTLCreateSystemDefaultDevice()?.name ?? "none"
        NSLog("showcase.swift_hooks: overlays linked (CoreML compute units %ld, CGRect %@, Metal %@)",
              config.computeUnits.rawValue, rectText(rect), gpu)
    }

    func webViewCreated(_ webView: WKWebView, window label: String) {
        NSLog("showcase.swift_hooks: webViewCreated window=%@", label)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) -> Bool {
        NSLog("showcase.swift_hooks: navigation to %@ (left to the next hook)", action.request.url?.absoluteString ?? "?")
        return false
    }
}

/// "{{x, y}, {w, h}}" on iOS and macOS alike.
private func rectText(_ r: CGRect) -> String {
    "{{\(r.origin.x), \(r.origin.y)}, {\(r.size.width), \(r.size.height)}}"
}
