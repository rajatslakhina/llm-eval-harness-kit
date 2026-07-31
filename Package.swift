// swift-tools-version: 6.0
import PackageDescription

// NOTE: This package deliberately declares NO executable product and NO app target.
// The runnable demo lives in a completely separate repository
// (llm-eval-harness-kit-demo-app) which consumes this package by its git URL,
// exactly the way any external consumer would.
let package = Package(
    name: "llm-eval-harness-kit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "EvalHarness", targets: ["EvalHarness"]),
        .library(name: "EvalHarnessUI", targets: ["EvalHarnessUI"]),
    ],
    targets: [
        // Platform-agnostic core. Foundation only — no UI, no networking — so it
        // is intended to build and test on Linux as well as Apple platforms.
        // Untested: CI runs macOS only. See the README's Verification section.
        .target(name: "EvalHarness"),

        // SwiftUI presentation layer, guarded with `#if canImport(SwiftUI)` so
        // the package is expected to still build where SwiftUI does not exist.
        .target(name: "EvalHarnessUI", dependencies: ["EvalHarness"]),

        .testTarget(name: "EvalHarnessTests", dependencies: ["EvalHarness"]),

        // Pins the demo scenarios themselves, so the outcomes the demo app's
        // README claims are asserted rather than asserted-about.
        .testTarget(name: "EvalHarnessUITests", dependencies: ["EvalHarnessUI", "EvalHarness"]),
    ]
)
