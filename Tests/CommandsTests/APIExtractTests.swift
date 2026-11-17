//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Commands
import Foundation
import SPMBuildCore
import _InternalTestSupport
import Testing

/// `swift package api experimental-extract` currently only supports the default build system,
/// which reports where it wrote the module interfaces.
private let extractBuildSystem: BuildSystemProvider.Kind = .swiftbuild

@Suite(
    .serializedIfOnWindows,
    .tags(
        .FunctionalArea.APIDiff,
    ),
)
struct APIExtractTests {
    @discardableResult
    private func execute(
        _ args: [String],
        packagePath: AbsolutePath? = nil,
        env: Environment? = nil,
    ) async throws -> (stdout: String, stderr: String) {
        var environment = env ?? [:]
        // don't ignore local packages when caching
        environment["SWIFTPM_TESTS_PACKAGECACHE"] = "1"
        return try await executeSwiftPackage(
            packagePath,
            extraArgs: ["api", "experimental-extract"] + args,
            env: environment,
            buildSystem: extractBuildSystem
        )
    }

    @Test(
        .tags(.Feature.Command.Package.APIExtract),
    )
    func extractsPublicAPIToStdout() async throws {
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Foo")
            try localFileSystem.writeFileContents(
                packageRoot.appending("Foo.swift"),
                string: "public func foo() {}\ninternal func hidden() {}\n"
            )

            let (stdout, _) = try await execute([], packagePath: packageRoot)

            #expect(stdout.contains("// MARK: - Foo"))
            #expect(stdout.contains("public func foo()"))
            #expect(!stdout.contains("hidden"))
        }
    }

    /// Standard output must be safe to redirect into a file, so build logs and diagnostics have
    /// to stay on standard error. This is the regression guard for anyone adding a `print()` to
    /// the progress path.
    @Test(
        .tags(.Feature.Command.Package.APIExtract),
    )
    func stdoutContainsOnlyTheInterface() async throws {
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Foo")

            let (stdout, stderr) = try await execute([], packagePath: packageRoot)

            #expect(!stdout.contains("Building for"))
            #expect(!stdout.contains("Compiling"))
            #expect(!stdout.contains("Build complete"))
            #expect(!stdout.contains("warning:"))
            // The build log itself has to have gone somewhere.
            #expect(!stderr.isEmpty)
        }
    }

    @Test(
        .tags(.Feature.Command.Package.APIExtract),
    )
    func extractsMultipleModulesInSortedOrder() async throws {
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")

            let (stdout, _) = try await execute([], packagePath: packageRoot)

            let bazBanner = try #require(stdout.range(of: "// MARK: - Baz"))
            let quxBanner = try #require(stdout.range(of: "// MARK: - Qux"))
            #expect(bazBanner.lowerBound < quxBanner.lowerBound)
        }
    }

    @Test(
        .tags(.Feature.Command.Package.APIExtract),
    )
    func targetsOptionRestrictsScope() async throws {
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")

            let (stdout, _) = try await execute(["--targets", "Baz"], packagePath: packageRoot)

            #expect(stdout.contains("// MARK: - Baz"))
            #expect(!stdout.contains("// MARK: - Qux"))
        }
    }

    /// The extraction build enables library evolution so that the emitted interface is the
    /// resilient form clients program against. Without it the compiler leaks implementation
    /// details such as `@_hasInitialValue` and `__derived_enum_equals`.
    @Test(
        .tags(.Feature.Command.Package.APIExtract),
    )
    func extractsResilientInterfaceWithoutCompilerInternals() async throws {
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Foo")
            try localFileSystem.writeFileContents(
                packageRoot.appending("Foo.swift"),
                string: """
                public struct Point {
                    public var x: Int = 0
                    public init() {}
                }

                public enum Direction {
                    case north
                    case south
                }
                """
            )

            let (stdout, stderr) = try await execute([], packagePath: packageRoot)

            // The public API is present...
            #expect(stdout.contains("public struct Point"))
            #expect(stdout.contains("public var x"))
            // ...in its resilient form, without compiler implementation details.
            #expect(!stdout.contains("@_hasInitialValue"))
            #expect(!stdout.contains("__derived_enum_equals"))
            #expect(!stdout.contains("@_semantics"))
            // And without the warning that the interface needs library evolution.
            #expect(!stderr.contains("only supported with -enable-library-evolution"))
        }
    }

    /// Types are printed the way the package author wrote them, rather than resolved and fully
    /// qualified with module selectors.
    @Test(
        .tags(.Feature.Command.Package.APIExtract),
    )
    func printsTypesAsWritten() async throws {
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Foo")
            try localFileSystem.writeFileContents(
                packageRoot.appending("Foo.swift"),
                string: """
                public typealias Meters = Double

                public struct Box {
                    public var size: Meters = 0
                    public init() {}
                }
                """
            )

            let (stdout, _) = try await execute([], packagePath: packageRoot)

            // No module selectors.
            #expect(!stdout.contains("::"))
            // The author's own spelling survives instead of the resolved type.
            #expect(stdout.contains("public var size: Meters"))
        }
    }

    /// The metadata header embeds the compiler version, target triple and build flags, so it is
    /// always omitted to keep the output stable across toolchains, hosts and configurations.
    @Test(
        .tags(.Feature.Command.Package.APIExtract),
    )
    func omitsToolchainSpecificMetadataComments() async throws {
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Foo")

            let (stdout, _) = try await execute([], packagePath: packageRoot)

            #expect(!stdout.contains("// swift-interface-format-version:"))
            #expect(!stdout.contains("// swift-compiler-version:"))
            #expect(!stdout.contains("// swift-module-flags:"))
            // The declarations themselves must survive.
            #expect(stdout.contains("public func foo()"))

            // Output must be reproducible.
            let (stdoutAgain, _) = try await execute([], packagePath: packageRoot)
            #expect(stdout == stdoutAgain)
        }
    }

    @Test(
        .tags(.Feature.Command.Package.APIExtract),
    )
    func diagnosesUnknownTarget() async throws {
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Foo")
            await expectThrowsCommandExecutionError(
                try await execute(["--targets", "NotATarget"], packagePath: packageRoot)
            ) { error in
                #expect(error.stderr.contains("no such target 'NotATarget'"))
            }
        }
    }

    @Test(
        .tags(.Feature.Command.Package.APIExtract),
    )
    func diagnosesUnknownProduct() async throws {
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Foo")
            await expectThrowsCommandExecutionError(
                try await execute(["--products", "NotAProduct"], packagePath: packageRoot)
            ) { error in
                #expect(error.stderr.contains("no such product 'NotAProduct'"))
            }
        }
    }

    @Test(
        .tags(.Feature.Command.Package.APIExtract),
    )
    func diagnosesNonSwiftTarget() async throws {
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("CTargetDep")
            await expectThrowsCommandExecutionError(
                try await execute(["--targets", "Foo"], packagePath: packageRoot)
            ) { error in
                #expect(error.stderr.contains("'Foo' is not a Swift language target"))
            }
        }
    }

    @Test(
        .tags(.Feature.Command.Package.APIExtract),
    )
    func diagnosesNonLibraryTarget() async throws {
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("NonAPILibraryTargets")
            await expectThrowsCommandExecutionError(
                try await execute(["--targets", "Exec"], packagePath: packageRoot)
            ) { error in
                #expect(error.stderr.contains("'Exec' is not a library target"))
            }
        }
    }

    @Test(
        .tags(.Feature.Command.Package.APIExtract),
    )
    func unsupportedBuildSystemIsRejected() async throws {
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Foo")
            await expectThrowsCommandExecutionError(
                try await executeSwiftPackage(
                    packageRoot,
                    extraArgs: ["api", "experimental-extract"],
                    buildSystem: .native
                )
            ) { error in
                #expect(error.stderr.contains("requires the default build system"))
            }
        }
    }

    @Test(
        .tags(.Feature.Command.Package.APIExtract),
    )
    func groupHelpListsBothSubcommands() async throws {
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Foo")
            let (stdout, _) = try await executeSwiftPackage(
                packageRoot,
                extraArgs: ["api", "--help"],
                buildSystem: extractBuildSystem
            )

            #expect(stdout.contains("experimental-extract"))
            #expect(stdout.contains("diagnose-breaking-changes"))
        }
    }
}
