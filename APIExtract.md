# `swift package api experimental-extract` — design & implementation plan

Status: **implemented** (see §11 for what shipped and how it deviated from this plan)
Author: (draft)
Target: Swift Next (6.5)

## 1. Motivation

SwiftPM already ships `swift package diagnose-api-breaking-changes`, which is a *comparison*
tool: it builds a baseline revision, runs `swift-api-digester -diagnose-sdk`, and reports
breakages. It is designed for CI gating.

A second, frequently requested use case is *inspection*: a developer (or a reviewer) wants to
see the public API surface of a package's modules — to review an API proposal, to attach the
API surface to a PR, or to commit the API surface into the repository so that changes to it show
up as a reviewable diff.

Today the closest primitives are:

| Existing surface | Output | Suitable for review? |
| --- | --- | --- |
| `swift package dump-symbol-graph` | symbol-graph JSON | No — machine format, one file per module + extension blocks |
| `swift package diagnose-api-breaking-changes` | diagnostics only | No — requires a baseline, only reports deltas |
| `swift build -Xswiftc -emit-module-interface-path …` | `.swiftinterface` | Yes, but users must hand-roll paths per target |
| `swift package build --enable-parseable-module-interfaces` | `.swiftinterface` buried in `.build` | Only if you know where to look |

The last row is the interesting one: the compiler already produces exactly the artifact people
want (`.swiftinterface`), SwiftPM already knows how to ask for it
(`BuildParameters.Driver.enableParseableModuleInterfaces`, wired for both the native and
Swift Build build systems), but there is no ergonomic command that collects the artifacts for
the root package's library modules and puts them somewhere useful.

This proposal adds that command, and reorganises the existing one under a shared `api` verb:

```
swift package api experimental-extract        # new
swift package api diagnose-breaking-changes   # moved from `swift package diagnose-api-breaking-changes`
```

## 2. Decisions

Four questions were resolved with the project owner before implementation; recorded here so
reviewers don't relitigate them.

| Decision | Choice | Rationale |
| --- | --- | --- |
| **Output destination** | stdout by default; `-o/--output-dir <dir>` redirects to per-module files. No `--stdout` flag. | Matches `show-dependencies` (`ShowDependencies.swift:36-45`), which is the only comparable command and carries the comment *"command's result output goes on stdout"*. `describe`, `dump-package` and `dump-pif` are also stdout-only. `dump-symbol-graph` is the lone directory-writing outlier and its `--output-dir` is `visibility: .hidden`, so it is not a supported precedent. With stdout as the default there is no state left for a `--stdout` flag to express. |
| **Command naming** | `api experimental-extract`, promoted to `api extract` in a later release. The `api` group itself is stable. | Buys a release of freedom to change the flag surface (`--verify`, access levels, format naming) without a compatibility promise. The group has to be stable regardless, because it hosts the moved `diagnose-breaking-changes`. Follows the `experimental-install` / `experimental-uninstall` precedent. |
| **Deprecation of the old spelling** | Silent hidden alias now; warning in a later release; removal after that. | `diagnose-api-breaking-changes` is load-bearing in a lot of external CI. Docs and `--help` advertise only the new spelling immediately, but no warning is emitted yet — this avoids noise in build logs and avoids breaking CI that treats warnings as failures. |
| **Output format** | `.swiftinterface` by default, `--format json` for `swift-api-digester -dump-sdk` output. | See §3.1. |

Stdout-by-default is safe here specifically because of the rule documented at
`Sources/CoreCommands/SwiftCommandState.swift:384-388`: `swift package` subcommands are built
with `outputStream: TSCBasic.stderrStream`, so build and resolution logs already go to stderr.
`swift package api experimental-extract > Foo.swiftinterface` therefore yields a clean file.
**Implementation trap:** `DumpSymbolGraph` emits its `-- Emitting symbol graph for X` progress
line with a bare `print()`, which lands on stdout. Do not copy that; progress must go through
`observabilityScope.emit(info:)` or `swiftCommandState.outputStream`.

## 3. Research summary — what exists today

Relevant code, for implementers:

- `Sources/Commands/PackageCommands/APIDiff.swift`
  - `APIDiff` (`diagnose-api-breaking-changes`) and `DeprecatedAPIDiff` (`experimental-api-diff`,
    hidden, hard-fails with a rename message — the precedent for the *end state* of a rename,
    several releases after the warning phase).
  - `APIDiff.determineModulesToDiff(packageGraph:productNames:targetNames:observabilityScope:diagnoseMissingNames:)`
    — the module-selection logic for `--products` / `--targets`, including the
    "not a library product" / "not a Swift language target" diagnostics. **Directly reusable by
    `extract`; should be lifted out of `APIDiff`.**
  - Two execution paths, selected on `swiftCommandState.options.build.buildSystem`:
    - `swiftbuild` → `runWithIntegratedAPIDigesterSupport`, driven by
      `BuildParameters.apiDigesterMode` (`Sources/SPMBuildCore/BuildParameters/BuildParameters+APIDigester.swift`).
    - `native` → `runWithSwiftPMCoordinatedDiffing`, which needs a `BuildPlan`
      (`buildOutputs: [.buildPlan]`) and shells out to `swift-api-digester` directly.
- `Sources/Commands/Utilities/APIDigester.swift`
  - `SwiftAPIDigester.emitAPIBaseline(to:for:buildPlan:)` → `swift-api-digester -dump-sdk`,
    including validation that the resulting JSON has a non-empty `ABIRoot.children`.
  - `ModulesGraph.apiDigesterModules` — Swift modules of library products of root packages,
    by `c99name`.
  - `BuildParameters.apiDiff` — `<dataPath>/apidiff`.
- `Sources/Commands/PackageCommands/DumpCommands.swift`
  - `DumpSymbolGraph` is the closest structural precedent: request an extra build output, then
    either consume the build system's own result
    (`buildResult.symbolGraph.outputLocationForTarget`, Swift Build) or fall back to driving the
    tool from a `BuildPlan` (native). Copy this shape (but not its stdout handling — §2).
- `Sources/SPMBuildCore/BuildSystem/BuildSystem.swift`
  - `BuildOutput` (`.symbolGraph(SymbolGraphOptions)`, `.buildPlan`, …), `SymbolGraphResult`,
    `BuildResult`. New extra outputs are added here.
- `.swiftinterface` plumbing that already exists:
  - `Sources/CoreCommands/Options.swift:539` — `--enable-parseable-module-interfaces`.
  - `Sources/SPMBuildCore/BuildParameters/BuildParameters+Driver.swift:62` —
    `enableParseableModuleInterfaces`.
  - `Sources/Build/BuildDescription/SwiftModuleBuildDescription.swift:161,592` —
    `parseableModuleInterfaceOutputPath` = `<modulesPath>/<c99name>.swiftinterface`, passed as
    `-emit-module-interface-path`. Note: currently **internal**.
  - `Sources/SwiftBuildSupport/SwiftBuildSystem.swift:1295` — `SWIFT_EMIT_MODULE_INTERFACE=YES`.
    Swift Build emits `<Modules>/<Name>.swiftinterface` plus `.private.swiftinterface` and
    (when `SWIFT_PACKAGE_NAME` is set) `.package.swiftinterface`
    (`swift-build/Sources/SWBCore/SpecImplementations/Tools/SwiftCompiler.swift:1943`).
- Output-destination precedent: `ShowDependencies.swift:36-45` (stdout default, `-o` redirect),
  `ArchiveSource.swift:32-35` (`-o/--output` for a single artifact),
  `DumpCommands.swift:52-58` (`--output-dir`, hidden).
- Docs: one `.md` per command under
  `Sources/PackageManagerDocs/Documentation.docc/Package/`, indexed from
  `Sources/PackageManagerDocs/Documentation.docc/SwiftPackageCommands.md`, which already has an
  `### Experimental commands` topic group (`PackageExperimentalInstall.md`).
- Tests: `Tests/CommandsTests/APIDiffTests.swift` (swift-testing, parameterised over
  `SupportedBuildSystemOnAllPlatforms`, gated by a custom `.requiresAPIDigester`
  `ConditionTrait`), fixtures under `Fixtures/Miscellaneous/APIDiff/`, tags in
  `Sources/_InternalTestSupport/SwiftTesting+Tags.swift`.

### 3.1 Output-format evaluation

Three candidate representations were considered for "the public API of a module":

1. **`.swiftinterface` (chosen default).** Compiler-generated, authoritative, textual, stable
   enough to commit and diff, includes availability, generic constraints, conformances and
   attributes. SwiftPM already knows how to request it from both supported build systems.
   Zero new formatting code to own.
2. **`swift-api-digester -dump-sdk` JSON (chosen, secondary).** Already produced by
   `diagnose-api-breaking-changes` as its baseline format. Not human-readable, but it is
   *the* machine format for API comparison, and emitting it from the working tree lets people
   snapshot a baseline without a git revision. Reuses `SwiftAPIDigester.emitAPIBaseline` on
   native and the existing `APIDigesterMode.generateBaselines` on Swift Build — **no new build
   plumbing at all**.
3. **A hand-written pretty-printer over symbol graphs (rejected for v1).** Symbol graphs carry
   `declarationFragments`, so a nicer, fully controlled rendering is possible. Rejected because
   it means owning a Swift declaration printer and its fidelity bugs forever, when the compiler
   already ships one. `swift package dump-symbol-graph` remains available for anyone who wants
   the raw graph.

Known wrinkle with `.swiftinterface`: emitting an interface for a module built **without**
library evolution produces a compiler warning
(`module interfaces are only supported with -enable-library-evolution`), twice per module.
This is pre-existing behaviour of `--enable-parseable-module-interfaces` and is *not* fatal —
the interface is still written. We do **not** enable library evolution by default (it changes
codegen and can fail to build packages that build fine otherwise); we expose
`--enable-library-evolution` and document the warning. Suppressing the warning when the client
is a tool rather than a user is worth filing as a compiler-side follow-up. The warning goes to
stderr, so it does not corrupt piped output.

## 4. Command-line surface

### 4.1 The `api` command group

```swift
extension SwiftPackageCommand {
    struct API: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "api",
            abstract: "Inspect and compare the API of a package's modules.",
            subcommands: [ExperimentalExtract.self, DiagnoseBreakingChanges.self],
            helpNames: [.short, .long, .customLong("help", withSingleDash: true)]
        )
    }
}
```

No `defaultSubcommand`, so bare `swift package api` prints the group help. This mirrors
`SwiftPackageCommand.Config` (`swift package config set-mirror`) and `swift test list`.

The group name `api` is stable from day one — it has to be, since it hosts the moved
`diagnose-breaking-changes`. Only the `extract` subcommand carries the `experimental-` prefix.

### 4.2 `swift package api experimental-extract`

```
swift package api experimental-extract
  [--products <product> ...]
  [--targets <target> ...]
  [--format <swiftinterface|json>]
  [-o|--output-dir <dir>]
  [--strip-metadata]
  [--enable-library-evolution]
  <global options> <build options> <trait options>
```

| Flag | Type | Default | Rationale |
| --- | --- | --- | --- |
| `--products <p>...` | `[String]`, `.upToNextOption` | all library products of root packages | Verbatim parity with `diagnose-breaking-changes`, same diagnostics, same shared helper. |
| `--targets <t>...` | `[String]`, `.upToNextOption` | — | Same. Combines additively with `--products`. |
| `--format` | `swiftinterface \| json` | `swiftinterface` | See §3.1. `json` is `swift-api-digester -dump-sdk` output. |
| `-o`, `--output-dir <dir>` | `AbsolutePath?` | none — output goes to stdout | Declared as `@Option(name: [.long, .customShort("o")])`, matching `ShowDependencies`. When given, writes one file per module and reports `Files written to <path>`. |
| `--strip-metadata` | `Bool` | `false` | Drops the leading `// swift-interface-format-version:`, `// swift-compiler-version:`, `// swift-module-flags*:` comments. Those lines embed the compiler version and target triple, which makes an interface committed to a repository churn on every toolchain/host change — the exact workflow this command is meant to enable. Off by default because the flags are semantically meaningful. `swiftinterface` only. |
| `--enable-library-evolution` | `Bool` | `false` | Adds `-enable-library-evolution` to the extraction build so the emitted interface is the resilient one and the compiler stops warning. Opt-in because it changes codegen and can break packages that otherwise build. |

Explicitly **not** in v1 (rationale recorded so reviewers don't have to ask):

- `--minimum-access-level` / `--include-spi`. The private and package interfaces are separate
  compiler outputs (`-emit-private-module-interface-path`,
  `-emit-package-module-interface-path`); Swift Build already emits them, the native build
  system does not. Adding them means plumbing on both sides. Deferred to §9.
- `--format symbol-graph`. Already covered by `swift package dump-symbol-graph`.
- `--verify` / `--check` (fail if the emitted interface differs from a committed one). This is
  the natural next step for CI and is called out in §9; keeping it out of v1 keeps the
  command's contract "produce artifacts", not "gate builds". It is also the main reason the
  subcommand ships as `experimental-`.

Behaviours worth pinning down:

- Modules are selected exactly as `diagnose-breaking-changes` selects them: Swift modules of
  library products of **root** packages. Non-Swift targets and non-library targets named
  explicitly produce the same errors as today.
- If the selection is empty, emit an **error**
  (`"no Swift library modules found to extract; use --targets to select specific targets"`)
  and exit non-zero. Silently succeeding while writing nothing is a bad CI failure mode.
- **stdout shape.** Modules are emitted in sorted order.
  - `swiftinterface`: each module preceded by a `// MARK: - <Module>` banner. A single module
    still gets the banner, so output shape doesn't depend on module count.
  - `json`: a single document `{"modules": {"<Module>": <digest>, …}}`. JSON documents don't
    concatenate, and a shape that changes with module count is worse than a wrapper — so the
    wrapper is unconditional. Note this is deliberately *not* the raw baseline format; the
    baseline-compatible layout is what `-o` produces.
- **`-o` shape.** One file per module: `<c99name>.swiftinterface` / `<c99name>.json`, matching
  the naming `SwiftAPIDigester.emitAPIBaseline` already uses for baselines. The directory is
  created recursively; files for the selected modules are overwritten, unrelated files are left
  alone (unlike `dump-symbol-graph`, which deletes its output directory — hostile if someone
  points `-o` at a checked-in `API/` directory).
- Progress/diagnostics go to stderr (§2), so `-o` is only about the artifacts.

### 4.3 `swift package api diagnose-breaking-changes`

Identical arguments, options, semantics, exit codes and output to today's
`swift package diagnose-api-breaking-changes`. Nothing changes except where the command lives.
Ships without an `experimental-` prefix, since it is an existing stable command being rehomed.

### 4.4 Backward compatibility for the moved command

`swift package diagnose-api-breaking-changes` is widely wired into CI. It must keep working, and
per §2 it must keep working *quietly* for now.

- The top-level `diagnose-api-breaking-changes` command stays registered with
  `shouldDisplay: false`, and delegates to the same implementation. **No deprecation warning is
  emitted in this release.** Docs and `--help` advertise only the new spelling.
- A later release adds the warning
  (`warning: 'swift package diagnose-api-breaking-changes' is deprecated; use 'swift package api diagnose-breaking-changes' instead`,
  same shape as `Resolve.swift:83`'s `fetch` deprecation). Removal comes after that, at which
  point it may become a hard error in the style of `DeprecatedAPIDiff`.
- The schedule is recorded in the CHANGELOG entry so the next person doesn't have to guess.
- `experimental-api-diff` is untouched.

To avoid two divergent copies of the options, the option set is factored into a shared
`ParsableArguments` struct and the implementation into a shared type:

```swift
// Sources/Commands/PackageCommands/APIDiff.swift
struct APIBreakingChangesOptions: ParsableArguments {
    @Option(help: "...") var breakageAllowlistPath: Basics.AbsolutePath?
    @Argument(help: "...") var treeish: String
    @Option(parsing: .upToNextOption, help: "...") var products: [String] = []
    @Option(parsing: .upToNextOption, help: "...") var targets: [String] = []
    @Option(name: .customLong("baseline-dir"), help: "...") var overrideBaselineDir: Basics.AbsolutePath?
    @Flag(help: "...") var regenerateBaseline: Bool = false
}

/// The implementation, shared by the current and deprecated spellings.
struct APIBreakingChangesRunner {
    let options: APIBreakingChangesOptions
    let globalOptions: GlobalOptions
    func run(_ swiftCommandState: SwiftCommandState) async throws { /* today's APIDiff.run body */ }
}

extension SwiftPackageCommand.API {
    struct DiagnoseBreakingChanges: AsyncSwiftCommand {
        static let configuration = CommandConfiguration(
            commandName: "diagnose-breaking-changes", abstract: "...", discussion: "...", ...)
        @OptionGroup(visibility: .hidden) var globalOptions: GlobalOptions
        @OptionGroup var options: APIBreakingChangesOptions
        func run(_ state: SwiftCommandState) async throws {
            try await APIBreakingChangesRunner(options: options, globalOptions: globalOptions).run(state)
        }
    }
}

struct APIDiff: AsyncSwiftCommand {  // old spelling: hidden, silent alias for now
    static let configuration = CommandConfiguration(
        commandName: "diagnose-api-breaking-changes", shouldDisplay: false, ...)
    @OptionGroup(visibility: .hidden) var globalOptions: GlobalOptions
    @OptionGroup var options: APIBreakingChangesOptions
    func run(_ state: SwiftCommandState) async throws {
        // TODO(<release>): emit a deprecation warning here, then remove in the release after.
        try await APIBreakingChangesRunner(options: options, globalOptions: globalOptions).run(state)
    }
}
```

Note the argument order in `--help` shifts slightly when options move into an `@OptionGroup`; the
generated docs (§7) are regenerated anyway.

## 5. Implementation

### 5.1 New and changed files

| File | Change |
| --- | --- |
| `Sources/Commands/PackageCommands/APICommand.swift` | **New.** The `api` group (§4.1). |
| `Sources/Commands/PackageCommands/APIExtract.swift` | **New.** `SwiftPackageCommand.API.ExperimentalExtract`. |
| `Sources/Commands/PackageCommands/APIDiff.swift` | Refactor into `APIBreakingChangesOptions` + `APIBreakingChangesRunner` + two thin commands (§4.4). Move `determineModulesToDiff` out. |
| `Sources/Commands/Utilities/APIDigester.swift` | Host the shared module selection as `ModulesGraph.selectAPIModules(products:targets:observabilityScope:diagnoseMissingNames:)`. Add `BuildParameters.apiExtract` (`<dataPath>/api`) if a scratch location is needed for intermediate artifacts. |
| `Sources/SPMBuildCore/BuildSystem/BuildSystem.swift` | Add `BuildOutput.moduleInterface`, `ModuleInterfaceResult`, `BuildResult.moduleInterface`. |
| `Sources/Build/BuildDescription/SwiftModuleBuildDescription.swift` | Make `parseableModuleInterfaceOutputPath` `public`. |
| `Sources/Build/BuildOperation.swift` | Recognise `.moduleInterface` in `buildOutputs`: force `driverParameters.enableParseableModuleInterfaces` for the build. (Locations come from the `BuildPlan`, so `BuildResult.moduleInterface` stays `nil`, exactly like `symbolGraph` today.) |
| `Sources/SwiftBuildSupport/SwiftBuildSystem.swift` | Recognise `.moduleInterface`: set `SWIFT_EMIT_MODULE_INTERFACE=YES` and return a `ModuleInterfaceResult` describing the output location. |
| `Sources/XCBuildSupport/*` | Nothing; the `xcode` build system takes the "unsupported" path (§5.4). |
| `Sources/Commands/PackageCommands/SwiftPackageCommand.swift` | Register `API.self`; keep `APIDiff.self` and `DeprecatedAPIDiff.self`. |
| `Sources/_InternalTestSupport/SwiftTesting+Tags.swift` | Add `Tag.Feature.Command.Package.APIExtract` and `.APIDiagnoseBreakingChanges`. Name the first one **without** "Experimental" so the tag survives promotion (unlike the existing `ExperimentalApiDiff` tag, which will need renaming one day). |
| `Tests/CommandsTests/APIExtractTests.swift` | **New.** §6. |
| `Tests/CommandsTests/APIDiffTests.swift` | Parameterise over both command spellings; assert the old spelling stays silent. |
| `Fixtures/Miscellaneous/APIExtract/` | Only if the existing `APIDiff` fixtures prove insufficient (§6.1). |
| `Sources/PackageManagerDocs/Documentation.docc/…` | §7. |
| `CHANGELOG.md` | §7. |

### 5.2 Build-output plumbing for `.swiftinterface`

Mirror `symbolGraph` exactly, so each build system reports its own on-disk layout instead of the
command guessing:

```swift
// Sources/SPMBuildCore/BuildSystem/BuildSystem.swift
public enum BuildOutput: Equatable {
    ...
    case moduleInterface
}

public struct ModuleInterfaceResult {
    /// Build-products-relative path components of the `.swiftinterface` for a module
    /// (identified by its `c99name`). The file may not exist if the module produced no interface.
    public let outputLocationForTarget: (String, BuildParameters) -> [String]
    public init(outputLocationForTarget: @escaping (String, BuildParameters) -> [String]) { ... }
}
```

The two build systems use **different layouts**, verified empirically (§6.4) — which is exactly
why the location must be reported by the build system rather than hardcoded in the command:

- Native: flat, `<products>/Modules/<Name>.swiftinterface`. No `ModuleInterfaceResult` needed;
  `ExperimentalExtract` takes the `BuildPlan` branch and reads
  `SwiftModuleBuildDescription.parseableModuleInterfaceOutputPath`.
- Swift Build: **nested**, `<products>/<Name>.swiftmodule/<module-triple>.swiftinterface` —
  e.g. `Alpha.swiftmodule/arm64-apple-macos.swiftinterface`. Two details matter:
  1. It is a directory named `<Name>.swiftmodule`, not a flat `Modules/` directory.
  2. The filename is the **version-stripped target triple** (`arm64-apple-macos`), *not*
     `buildParameters.triple.archName` (`arm64`), which is what the existing `symbolGraph`
     closure uses. `ModuleInterfaceResult`'s closure needs to derive the module triple, so this
     cannot be copy-pasted from `SymbolGraphResult`.

  Swift Build also leaves a flat-named copy under
  `Intermediates.noindex/<Package>.build/<Config>/<Target>-t.build/Objects-normal/<arch>/<Name>.swiftinterface`.
  Use the `Products` copy; the intermediates path is not a supported output location.

Still to confirm while implementing: what `SwiftBuildSystem.buildProductsPath(for:)` returns
relative to the observed `.build/out/Products/Debug/`. The existing `symbolGraph` closure returns
`["<archName>", "<target>.symbolgraphs"]`, which does not obviously sit under `Products/Debug`, so
the base path needs checking rather than assuming.

### 5.3 `ExperimentalExtract` control flow

```swift
func run(_ state: SwiftCommandState) async throws {
    // 1. Validate flag combinations (--strip-metadata with --format json, etc.).
    // 2. Select modules from the root package graph (shared helper).
    let graph = try await state.loadPackageGraph()
    let modules = try graph.selectAPIModules(products: products, targets: targets,
                                             observabilityScope: state.observabilityScope,
                                             diagnoseMissingNames: true)
    guard !modules.isEmpty else { /* error, exit 1 */ }

    switch format {
    case .swiftinterface: try await extractModuleInterfaces(state, modules: modules)
    case .json:           try await extractDigesterJSON(state, modules: modules)
    }
}
```

**`swiftinterface`:**

1. Copy `productsBuildParameters`; set `driverParameters.enableParseableModuleInterfaces = true`
   and, if `--enable-library-evolution`, append `-enable-library-evolution` to
   `swiftCompilerFlags`.
2. `createBuildSystem(cacheBuildManifest: false, productsBuildParameters: …)`, then
   `build(subset: .allExcludingTests, buildOutputs: [.moduleInterface, .buildPlan])`.
   `cacheBuildManifest: false` because the manifest depends on the mutated flags, matching
   `DumpSymbolGraph`.
3. Resolve each selected module's interface path:
   - `buildResult.moduleInterface` present → `buildProductsPath` + `outputLocationForTarget`;
   - else `buildResult.buildPlan` → iterate `buildModules`, match `case .swift(let d)` where
     `d.module.c99name` is selected, use `d.parseableModuleInterfaceOutputPath`;
   - else `throw InternalError("Build system \(buildSystem) cannot produce module interfaces.")`
     (same wording pattern as `DumpSymbolGraph`).
4. For each module in sorted order: read, optionally `--strip-metadata`, then either `print()` to
   stdout with a `// MARK: - <module>` banner, or write to `<output-dir>/<module>.swiftinterface`.
   A module whose interface file is missing is an error naming the module, not a silent skip.

**`json`:** reuses the existing digester machinery, so there is nothing new to build.

- `swiftbuild` (`buildSystem.hasIntegratedAPIDigesterSupport`): set
  `productsBuildParameters.apiDigesterMode = .generateBaselines(baselinesDirectory: dir, modulesRequestingBaselines: modules)`
  and build; Swift Build writes `<dir>/<module>.json` itself. `dir` is `--output-dir` when given,
  otherwise a scratch directory whose contents are then assembled into the stdout wrapper.
- `native`: build with `buildOutputs: [.buildPlan]`, then
  `SwiftAPIDigester(fileSystem:tool:).emitAPIBaseline(to: dir/"\(module).json", for: module, buildPlan: buildPlan)`
  concurrently in a `TaskGroup`, exactly as `APIDigesterBaselineDumper` does — including its
  `ABIRoot`/empty-symbols validation and its `SwiftAPIDigester.Error` reporting.
- Requires `swift-api-digester` in the toolchain
  (`getTargetToolchain().getSwiftAPIDigester()`); the thrown error already reads well.

Because the `-o` file naming matches the baseline layout, `--format json -o X` produces files a
future `--baseline-dir` improvement can consume directly (§9; today `diagnose-breaking-changes`
appends a revision component to `--baseline-dir`, so it is not yet a drop-in).

### 5.4 Build-system support matrix

| Build system | `swiftinterface` | `json` |
| --- | --- | --- |
| `native` | via `BuildPlan` | via `SwiftAPIDigester` + `BuildPlan` |
| `swiftbuild` (default) | via `ModuleInterfaceResult` | via `APIDigesterMode.generateBaselines` |
| `xcode` (deprecated) | `InternalError`, "cannot produce module interfaces" | not supported |

## 6. Testing

### 6.1 Fixtures

Reuse `Fixtures/Miscellaneous/APIDiff/`:

- `Foo/` — single Swift library module `Foo`; the happy path.
- `Bar/` — multiple modules (`Baz`, `Qux`) across products; multi-module output, `--products` /
  `--targets` filtering.
- `NonAPILibraryTargets/` — has an executable and non-library targets; asserts they are excluded
  and that naming them errors.
- `CTargetDep/` — a C target dependency; asserts C targets are skipped and that naming one
  errors with "is not a Swift language target".

`createGitRepo` is unnecessary for `extract` (no baseline revision), which makes these tests
meaningfully cheaper than the `APIDiff` ones.

A new fixture is only needed if we want richer declarations (generics, `@available`, protocol
conformances) to assert against — see the stability caveat in §6.2.

### 6.2 `Tests/CommandsTests/APIExtractTests.swift`

Same skeleton as `APIDiffTests`: a private `execute(_:packagePath:env:buildSystem:)` wrapper over
`executeSwiftPackage`, `@Suite(.serializedIfOnWindows, .tags(.FunctionalArea.APIDiff))`, tests
parameterised `arguments: SupportedBuildSystemOnAllPlatforms`, tagged
`.Feature.Command.Package.APIExtract`.

`swiftinterface` cases (no digester needed, so these run everywhere):

1. Default invocation on `Foo` prints the interface **to stdout**, containing the public
   declaration and not an internal one, with the `// MARK: - Foo` banner.
2. **Stdout cleanliness** — the highest-value test given the destination decision: assert that
   stdout parses as a plausible interface and contains no build-log lines
   (`Compiling`, `Building for`, `warning:`), while `stderr` is non-empty. This is the
   regression guard for anyone later adding a `print()` to the progress path.
3. `-o <tmp>` writes `Foo.swiftinterface` there, prints `Files written to …`, and emits nothing
   else on stdout. A pre-existing unrelated file in that directory survives.
4. `--output-dir` long spelling is equivalent to `-o`.
5. Multi-module `Bar`: both modules appear on stdout in sorted order with banners; with `-o`,
   both files exist.
6. `--targets Baz` restricts output to `Baz`; `--products` restricts to that product's modules.
7. `--strip-metadata` removes the `// swift-compiler-version:` line while keeping declarations,
   and two runs produce byte-identical output.
8. `--enable-library-evolution` succeeds and stderr no longer contains
   "only supported with -enable-library-evolution".
9. Error cases: unknown target, unknown product, executable target, C target, package with no
   Swift library modules — assert the exact diagnostic and a non-zero exit
   (`expectThrowsCommandExecutionError`).

`json` cases, gated on `.requiresAPIDigester`:

10. `--format json -o <tmp>` writes `Foo.json` whose top level has a non-empty
    `ABIRoot.children`.
11. `--format json` to stdout emits `{"modules": {"Foo": …}}`, parseable by `JSONSerialization`,
    and the wrapper is present for both single- and multi-module packages.

Assertion strategy: assert on *presence of specific declarations* and on stable structural
properties, never on whole-file equality. The `.swiftinterface` text is owned by the compiler and
will change across toolchains; golden-file tests here would be a permanent source of CI
breakage. Same reason there is no snapshot test of the digester JSON.

### 6.3 Changes to existing tests

- `APIDiffTests`: parameterise the invocation prefix over
  `[["diagnose-api-breaking-changes"], ["api", "diagnose-breaking-changes"]]` so both spellings
  are covered by the whole existing suite. This is the main guard against the §4.4 refactor
  regressing behaviour.
- Add a test asserting the old spelling still succeeds/fails identically **and emits no
  deprecation warning** — this pins the "silent alias" decision, so that when someone later adds
  the warning they have to consciously update this test (that's the reminder mechanism for the
  next phase).
- Add a test that `swift package api --help` lists `experimental-extract` and
  `diagnose-breaking-changes`, and that `swift package --help` no longer advertises
  `diagnose-api-breaking-changes`.

### 6.4 Layout verification (done)

The one thing the test suite couldn't tell us up front was each build system's `.swiftinterface`
layout. Verified with a two-module package (`Alpha`, `Beta`) on the Swift 6.4 toolchain,
`swift build --enable-parseable-module-interfaces` under both build systems:

```
native      .build/arm64-apple-macosx/debug/Modules/Alpha.swiftinterface
                                                   /Alpha.private.swiftinterface
                                                   /Alpha.package.swiftinterface

swiftbuild  .build/out/Products/Debug/Alpha.swiftmodule/arm64-apple-macos.swiftinterface
                                                      /arm64-apple-macos.private.swiftinterface
                                                      /arm64-apple-macos.package.swiftinterface
```

Two findings fed back into the plan: the layouts differ structurally (§5.2), and all three access
levels are emitted for free on both build systems (§9). The `-enable-library-evolution` warning
appears on both, three times for two modules, and goes to stderr.

## 7. Documentation and changelog

- `Sources/PackageManagerDocs/Documentation.docc/Package/PackageAPIExperimentalExtract.md` —
  new page, same generated shape as existing command pages (usage block, prose, `- term` list per
  option). Naming follows `PackageExperimentalInstall.md`.
- `Sources/PackageManagerDocs/Documentation.docc/Package/PackageAPIDiagnoseBreakingChanges.md` —
  new page for the new spelling.
- `Sources/PackageManagerDocs/Documentation.docc/Package/PackageDiagnoseAPIBreakingChange.md` —
  keep (deep links exist), add a note that the command has moved to
  `swift package api diagnose-breaking-changes`. No "deprecated" wording yet, matching the
  silent-alias decision.
- `Sources/PackageManagerDocs/Documentation.docc/SwiftPackageCommands.md`:
  - add `### Inspecting and comparing API` listing `PackageAPIDiagnoseBreakingChanges`, and move
    `PackageDiagnoseAPIBreakingChange` out of "Using package manager plugins" (where it
    currently, oddly, lives);
  - list `PackageAPIExperimentalExtract` under the existing `### Experimental commands` group.
- `CHANGELOG.md`, under `Swift Next`: announce `swift package api experimental-extract`, the move
  of `diagnose-api-breaking-changes` under `swift package api`, and — explicitly — the plan to
  start warning on the old spelling in a later release and remove it after that.
- Regenerate shell completions if they are checked in for these commands.

## 8. Rollout / PR breakdown

Each step is independently reviewable and shippable:

1. **Refactor only, no behaviour change.** Lift `determineModulesToDiff` into
   `Sources/Commands/Utilities/APIDigester.swift`; split `APIDiff` into
   `APIBreakingChangesOptions` + `APIBreakingChangesRunner`. Existing tests pass unchanged.
2. **Add the `api` group and rehome the command.** New `api diagnose-breaking-changes`, old
   spelling hidden and silent, `APIDiffTests` parameterised over both. Docs + CHANGELOG.
3. **`api experimental-extract` with the `.swiftinterface` format** — the
   `BuildOutput.moduleInterface` plumbing, stdout default, `-o`, `--strip-metadata`,
   `--enable-library-evolution`.
4. **`--format json`** — reuses `generateBaselines` and `SwiftAPIDigester`, no new build
   plumbing.

Steps 3 and 4 are ordered this way because `swiftinterface` is the default format and the
headline use case; landing `json` first would mean shipping a command whose default format
doesn't exist yet, or making `--format` temporarily required. If step 4 slips a release, the
command is still coherent without it.

## 9. Future work

- **Promote `experimental-extract` to `extract`.** Criteria: the destination/format flags have
  survived a release without change, the `--verify` design is settled, and the access-level
  question below is decided. Keep `experimental-extract` as a hidden alias for one release after
  promotion.
- **Start warning on `diagnose-api-breaking-changes`**, then remove it (§4.4). The test in §6.3
  that asserts silence is the tripwire that makes this deliberate.
- **`swift package api extract --verify <dir>`** — re-extract and fail if the result differs from
  a committed set of interfaces. This turns the "commit the API surface" workflow into a CI gate
  and is the most obvious follow-up. Needs `--strip-metadata`-style normalisation to be robust
  across toolchains, which is why that flag is in v1.
- **`--minimum-access-level package|private`** — cheaper than expected, and a candidate for v1.
  Verified (§6.4): **both** build systems already emit all three interfaces
  (`.swiftinterface`, `.private.swiftinterface`, `.package.swiftinterface`) when
  `--enable-parseable-module-interfaces` is on. On the native side this happens even though
  `SwiftModuleBuildDescription.swift:593` only passes `-emit-module-interface-path` — swift-driver
  derives the private and package interface paths from it as supplementary outputs. So no compiler
  or build-system plumbing is needed at all; the flag reduces to choosing which of three
  already-written files to read. Reconsider pulling this into v1.
- **Make `diagnose-breaking-changes --baseline-dir` consume `api extract --format json -o` output
  directly.** Today `--baseline-dir` is treated as the parent of a per-revision directory
  (`APIDiff.run` appends `baselineRevision.identifier`, and `emitAPIBaseline` appends it again).
  Accepting a flat directory of `<Module>.json` would let users check in a baseline and diff
  against it without a git revision at all — arguably the single most requested variant of the CI
  workflow.
- **Markdown or `--format text` rendering** over symbol graphs, if the `.swiftinterface` noise
  (`@_hasInitialValue`, fully-qualified `Swift::Int`, module-flag headers) turns out to be a real
  complaint from reviewers.
- **Upstream**: suppress the "module interfaces are only supported with
  `-enable-library-evolution`" warning when the interface is requested by a build tool (§3.1).
- **Non-root packages** (`--package <identity>`), for reviewing a dependency's API surface.

## 10. Remaining open items

Small enough to settle in code review rather than up front:

1. Whether `-o` should also accept a *file* path when exactly one module is selected
   (`-o Foo.swiftinterface`). Proposed: no — `-o` means directory, single-module users pipe
   stdout. Revisit if it comes up.
2. Whether the `json` stdout wrapper key should be `modules` (proposed) or the digest objects
   should be keyed at the top level. Only matters if anything ever consumes it programmatically,
   which `-o` serves better anyway.
3. Whether `--strip-metadata` should be the default once `--verify` exists, since `--verify`
   is unusable without it.

## 11. What was actually implemented

Scope was narrowed to the default (Swift Build) build system only, since that is now the default.
Steps 1–3 of §8 are done; step 4 (`--format json`) is not.

### Deviations from the plan, and why

1. **No `BuildOutput.moduleInterface` / `ModuleInterfaceResult` plumbing.** §5.2 designed this to
   abstract over both build systems. It turned out to be unnecessary: Swift Build already sets
   `SWIFT_EMIT_MODULE_INTERFACE=YES` from `driverParameters.enableParseableModuleInterfaces`
   (`SwiftBuildSystem.swift:1295`), so the command only has to *locate* the output. It does that by
   searching `<buildProductsPath>/<Module>.swiftmodule/` for a `*.swiftinterface` that is not a
   `.private.` or `.package.` variant, falling back to a flat `<Module>.swiftinterface`.
   Net effect: **zero changes to `SPMBuildCore`, `Build`, `SwiftBuildSupport`, or
   `XCBuildSupport`.** Searching the directory also avoids reconstructing the module triple, which
   §5.2 correctly identified as a trap.
2. **`--format` is not implemented.** Only `.swiftinterface` is emitted. `--format json` was
   deferred because the Swift Build baseline layout is awkward: `generateBaselines` writes
   `<dir>/<Module>/ABI/<arch>-<platform>.json`
   (`SWIFT_ABI_GENERATION_TOOL_OUTPUT_DIR`, and `getBaselineFileName` in swift-build's
   `SwiftFrameworkABICheckerTaskProducer.swift`), not the `<Module>.json` this document assumed.
   Supporting it means discovering and renaming those files. Since the flag doesn't exist yet, it
   can be added later without a compatibility concern.
3. **`--products`/`--targets` errors exit 1 via the observability scope**, as designed; verified.

### Newly discovered compatibility issue (needs a decision)

**Global options must precede the `api` subcommand.** With two levels of nesting, ArgumentParser
does not accept global options after the subcommand path:

```
swift package api diagnose-breaking-changes --package-path X 1.2.3   # error: Unknown option
swift package --package-path X api diagnose-breaking-changes 1.2.3   # works
```

This is **pre-existing SwiftPM behaviour**, not new — `swift package config get-mirror
--package-path X` fails the same way on unmodified `main`, and `_InternalTestSupport`'s
`swiftArgs` already places global arguments before `extraArgs`. But it means rehoming
`diagnose-api-breaking-changes` changes the accepted argument order for anyone who adopts the new
spelling: `--package-path`, `--scratch-path`, `--configuration`, `--build-system`, `-Xswiftc` and
friends all have to move before `api`.

Because the old spelling is preserved verbatim, nothing breaks today. But this is worth resolving
before the deprecation warning phase, otherwise the warning will tell people to migrate to a
spelling that silently rejects their existing flags. Options: accept it and document it (currently
done — noted in the docs and CHANGELOG), or give `SwiftPackageCommand.API` its own
`@OptionGroup var globalOptions` and thread it down, or keep `diagnose-breaking-changes` at the
top level and only nest `extract`.

### Verified behaviour

Run against a two-module package with the locally built `swift-package`:

| Check | Result |
| --- | --- |
| Default run extracts all library modules to stdout, sorted, with `// MARK: - <Module>` banners | pass |
| Internal declarations excluded | pass |
| Build log and compiler warnings on stderr; stdout contains only interface text | pass |
| `-o <dir>` writes `<Module>.swiftinterface` per module, nothing on stdout | pass |
| `Files written to <dir>` goes to stderr | pass |
| `--targets` scopes the selection | pass |
| `--strip-metadata` drops `// swift-*` comments, keeps declarations, byte-identical across runs | pass |
| `--enable-library-evolution` silences the library-evolution warning | pass |
| Unknown target / unknown product / non-Swift target / non-library target error, exit 1 | pass |
| Package with no Swift library modules errors, exit 1 | pass |
| `--build-system native` rejected with a clear message, exit 1 | pass |
| `swift package api --help` lists both subcommands | pass |
| `swift package --help` no longer advertises `diagnose-api-breaking-changes` | pass |

Not yet run: the new automated test suites (`APIExtractTests`, and the three added
`APIDiffTests` cases). See §12.

## 12. Known blocker for CI verification

This working tree cannot build as checked out, for reasons unrelated to this change:

- `.swift-version` pins toolchain 6.2.3, which is not installed locally (6.2.0 / 6.3.0 are), so
  `swift` via swiftly refuses to run. Building requires bypassing it (`/usr/bin/swift`).
- More importantly, `Package.resolved` pins `swift-build` at `e6c5bd5` (2025-10-08), which predates
  build settings that `main`'s own `Sources/SwiftBuildSupport` references
  (`TARGET_TEMP_DIR_SUFFIX`, `TAPI_EXTRACT_API_OUTPUT_DIR`,
  `DOCC_EXTRACT_PROJECT_HEADERS_DOCUMENTATION`). Since the dependency tracks branch `main`, the
  pin is simply stale and the build fails in `PackagePIFProjectBuilder.swift` and `PIFBuilder.swift`.

`swift package update swift-build` (to `4d21e30`) fixes it. That update was used to verify this
work and then **reverted**, to keep the branch diff focused — so a fresh `swift build` on this
branch will still fail until the pin is refreshed separately.

Running the locally built binary against a package additionally needs
`SWIFTPM_CUSTOM_LIBS_DIR` pointing at an *installed-style* layout
(`<root>/ManifestAPI/{libPackageDescription.dylib,PackageDescription.swiftmodule}`), not a raw
`.build` directory.
