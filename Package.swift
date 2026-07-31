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
        // Platform-agnostic core. Foundation only — no UI, no networking,
        // so it compiles and tests on Linux CI as well as Apple platforms.
        .target(name: "EvalHarness"),

        // SwiftUI presentation layer. Guarded with `#if canImport(SwiftUI)`
        // so the package still builds on Linux, where SwiftUI does not exist.
        .target(name: "EvalHarnessUI", dependencies: ["EvalHarness"]),

        .testTarget(name: "EvalHarnessTests", dependencies: ["EvalHarness"]),
    ]
)
