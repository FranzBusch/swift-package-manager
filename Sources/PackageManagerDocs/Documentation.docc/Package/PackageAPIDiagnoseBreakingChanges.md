# swift package api diagnose-breaking-changes

@Metadata {
    @PageImage(purpose: icon, source: command-icon)
}

Diagnose API-breaking changes to Swift modules in a package.

```
package api diagnose-breaking-changes
  [--breakage-allowlist-path=<breakage-allowlist-path>]
  <treeish> [--products=<products>...]
  [--targets=<targets>...]
  [--baseline-dir=<baseline-dir>] [--regenerate-baseline]
  [--version] [--help]
```

The `api diagnose-breaking-changes` command compares the Swift API of a package to a baseline revision, diagnosing any breaking changes which have been introduced. By default, it compares every Swift module from the baseline revision which is part of a library product. For packages with many targets, this behavior may be undesirable as the comparison can be slow. The `--products` and `--targets` options may be used to restrict the scope of the comparison.

> Note: This command was previously spelled `swift package diagnose-api-breaking-changes`. The old spelling continues to work for compatibility with existing continuous integration configurations, but new uses should prefer `swift package api diagnose-breaking-changes`.

- term **--breakage-allowlist-path=\<breakage-allowlist-path\>**:

*The path to a text file containing breaking changes that the API comparison should ignore. Each ignored breaking change in the file should appear on its own line and contain the exact message to ignore (for example, 'API breakage: func foo() has been removed').*


- term **treeish**:

*The baseline treeish to compare to (for example, a commit hash, branch name, tag, and so on).*


- term **--products=\<products\>**:

*One or more products to include in the API comparison. If present, only the specified products (and any targets specified using `--targets`) will be compared.*


- term **--targets=\<targets\>**:

*One or more targets to include in the API comparison. If present, only the specified targets (and any products specified using `--products`) will be compared.*


- term **--baseline-dir=\<baseline-dir\>**:

*The path to a directory used to store API baseline files. If unspecified, a temporary directory will be used.*


- term **--regenerate-baseline**:

*Regenerate the API baseline, even if an existing one is available.*


- term **--version**:

*Show the version.*


- term **--help**:

*Show help information.*

## See Also

- <doc:PackageAPIExperimentalExtract>
