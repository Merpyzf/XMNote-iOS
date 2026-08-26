import Foundation
import XMNoteUILintCore

struct Arguments {
    let root: URL
    let fileList: URL
    let policy: URL

    init?(_ values: [String]) {
        guard let rootIndex = values.firstIndex(of: "--root"),
              values.indices.contains(rootIndex + 1),
              let listIndex = values.firstIndex(of: "--file-list"),
              values.indices.contains(listIndex + 1),
              let policyIndex = values.firstIndex(of: "--policy"),
              values.indices.contains(policyIndex + 1) else {
            return nil
        }
        root = URL(fileURLWithPath: values[rootIndex + 1], isDirectory: true)
        fileList = URL(fileURLWithPath: values[listIndex + 1])
        policy = URL(fileURLWithPath: values[policyIndex + 1])
    }
}

guard let arguments = Arguments(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(
        Data("Usage: XMNoteUILint --root <path> --file-list <path> --policy <path>\n".utf8)
    )
    exit(2)
}

do {
    let listedFiles = try String(contentsOf: arguments.fileList, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map(String.init)
    let policyData = try Data(contentsOf: arguments.policy)
    let policy = try JSONDecoder().decode(LintPolicy.self, from: policyData)
    let engine = RuleEngine(policy: policy)
    var diagnostics: [LintDiagnostic] = []

    for relativePath in listedFiles {
        let fileURL = arguments.root.appending(path: relativePath)
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        diagnostics.append(contentsOf: engine.lint(source: source, path: relativePath))
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(diagnostics), as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data("XMNoteUILint failed: \(error)\n".utf8))
    exit(1)
}
