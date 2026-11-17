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

import ArgumentParser

extension SwiftPackageCommand {
    struct API: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "api",
            abstract: "Inspect and compare the API of a package's modules.",
            subcommands: [
                ExperimentalExtract.self,
                DiagnoseBreakingChanges.self,
            ],
            helpNames: [.short, .long, .customLong("help", withSingleDash: true)]
        )
    }
}
