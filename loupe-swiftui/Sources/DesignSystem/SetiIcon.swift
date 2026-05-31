import SwiftUI

// MARK: - Seti file icons (VS Code Seti theme, light variants only)
// Icons live in Resources/Assets.xcassets; associations in seti-associations.json.
// Regenerate assets: Scripts/sync-seti-icons.sh

enum SetiIcon {
    /// Cursor's exported JSON omits common single-segment extensions (.ts, .js, …);
    /// VS Code resolves those via language IDs. We mirror that here.
    private static let supplementalExtensions: [String: String] = [
        "ts": "_typescript", "mts": "_typescript", "cts": "_typescript",
        "tsx": "_react",
        "js": "_javascript", "mjs": "_javascript", "cjs": "_javascript",
        "jsx": "_react",
        "py": "_python", "pyw": "_python", "pyi": "_python",
        "swift": "_swift",
        "sql": "_db",
        "html": "_html_3", "htm": "_html_3",
        "css": "_css",
        "scss": "_sass", "sass": "_sass", "less": "_less",
        "json": "_json", "jsonc": "_json",
        "md": "_markdown", "mdx": "_markdown",
        "yaml": "_yml", "yml": "_yml",
        "xml": "_xml",
        "sh": "_shell", "bash": "_shell", "zsh": "_shell",
        "rs": "_rust",
        "go": "_go2",
        "rb": "_ruby",
        "java": "_java",
        "kt": "_kotlin", "kts": "_kotlin",
        "php": "_php",
        "vue": "_vue",
        "svelte": "_svelte",
        "cs": "_c-sharp",
        "cpp": "_cpp", "cc": "_cpp", "cxx": "_cpp",
        "c": "_c", "h": "_c_1",
        "dockerfile": "_docker",
        "r": "_R", "rmd": "_R",
        "zig": "_zig",
        "wasm": "_wasm",
        "toml": "_config",
        "graphql": "_graphql", "gql": "_graphql",
        "pl": "_perl", "pm": "_perl",
        "lua": "_lua",
        "ex": "_elixir", "exs": "_elixir_script",
        "hs": "_haskell", "lhs": "_haskell",
        "dart": "_dart",
        "tf": "_terraform", "tfvars": "_terraform",
        "gradle": "_gradle",
        "bat": "_windows", "cmd": "_windows",
        "ini": "_config", "cfg": "_config", "conf": "_config",
    ]

    private static let associations: SetiAssociations? = {
        guard let url = Bundle.main.url(forResource: "seti-associations", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SetiAssociations.self, from: data)
    }()

    private static let extensionsByLength: [(String, String)] = {
        var merged = supplementalExtensions
        if let map = associations?.fileExtensions {
            for (ext, key) in map { merged[ext] = key }
        }
        return merged.sorted { $0.key.count > $1.key.count }
    }()

    /// Asset catalog name for a repo file path (e.g. `src/App.tsx` → `seti-react`).
    static func assetName(forPath path: String) -> String {
        let fullName = (path as NSString).lastPathComponent.lowercased()

        if let key = associations?.fileNames[fullName] {
            return assetName(forIconKey: key)
        }

        for (ext, key) in extensionsByLength {
            let suffix = ".\(ext)"
            if fullName.hasSuffix(suffix) || fullName == ext {
                return assetName(forIconKey: key)
            }
        }

        return assetName(forIconKey: "_default")
    }

    static func assetName(forIconKey key: String) -> String {
        let stem = key.hasPrefix("_") ? String(key.dropFirst()) : key
        return "seti-\(stem)"
    }
}

// MARK: - SwiftUI

struct SetiIconView: View {
    let path: String
    var size: CGFloat = LoupeSize.fileIcon

    private var asset: String { SetiIcon.assetName(forPath: path) }

    var body: some View {
        Image(asset)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Associations JSON

private struct SetiAssociations: Decodable {
    let fileExtensions: [String: String]
    let fileNames: [String: String]
}
