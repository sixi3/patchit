#!/usr/bin/env bash
# Copies Seti *_light.svg icons into Assets.xcassets for the Loupe iOS app.
# Usage: ./Scripts/sync-seti-icons.sh [/path/to/vscode-seti-file-icons]

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HOME/Downloads/vscode-seti-file-icons}"
ASSETS="$ROOT/Sources/Resources/Assets.xcassets"

if [[ ! -d "$SRC" ]]; then
  echo "Seti icon folder not found: $SRC" >&2
  exit 1
fi

python3 - "$SRC" "$ASSETS" "$ROOT/Sources/Resources/seti-associations.json" <<'PY'
import json, shutil, sys
from pathlib import Path

src_icons, assets, out_json = map(Path, sys.argv[1:4])
assoc = json.loads((src_icons / "file-associations.json").read_text())

# VS Code language-mode extensions missing from the export (see SetiIcon.swift).
SUPPLEMENTAL = {
    "ts": "_typescript", "mts": "_typescript", "cts": "_typescript",
    "tsx": "_react", "js": "_javascript", "mjs": "_javascript", "cjs": "_javascript",
    "jsx": "_react", "py": "_python", "pyw": "_python", "pyi": "_python",
    "swift": "_swift", "sql": "_db", "html": "_html_3", "htm": "_html_3",
    "css": "_css", "scss": "_sass", "sass": "_sass", "less": "_less",
    "json": "_json", "jsonc": "_json", "md": "_markdown", "mdx": "_markdown",
    "yaml": "_yml", "yml": "_yml", "xml": "_xml", "sh": "_shell", "bash": "_shell",
    "zsh": "_shell", "rs": "_rust", "go": "_go2", "rb": "_ruby", "java": "_java",
    "kt": "_kotlin", "kts": "_kotlin", "php": "_php", "vue": "_vue", "svelte": "_svelte",
    "cs": "_c-sharp", "cpp": "_cpp", "cc": "_cpp", "cxx": "_cpp", "c": "_c", "h": "_c_1",
    "dockerfile": "_docker", "r": "_R", "rmd": "_R", "zig": "_zig", "wasm": "_wasm",
    "toml": "_config", "graphql": "_graphql", "gql": "_graphql", "pl": "_perl", "pm": "_perl",
    "lua": "_lua", "ex": "_elixir", "exs": "_elixir_script", "hs": "_haskell", "lhs": "_haskell",
    "dart": "_dart", "tf": "_terraform", "tfvars": "_terraform", "gradle": "_gradle",
    "bat": "_windows", "cmd": "_windows", "ini": "_config", "cfg": "_config", "conf": "_config",
}
merged_ext = {**SUPPLEMENTAL, **assoc.get("fileExtensions", {})}
assoc["fileExtensions"] = merged_ext
out_json.write_text(json.dumps(assoc, indent=2) + "\n")

keys = set(assoc.get("fileExtensions", {}).values())
keys.update(assoc.get("fileNames", {}).values())
keys.update(assoc.get("languageIds", {}).values())
keys.add("_default")

def icon_key_to_svg(icon_key: str) -> str:
    stem = icon_key[1:] if icon_key.startswith("_") else icon_key
    return f"{stem}_light.svg"

def asset_name(icon_key: str) -> str:
    stem = icon_key[1:] if icon_key.startswith("_") else icon_key
    return f"seti-{stem}"

fallback = src_icons / "default_light.svg"
assets.mkdir(parents=True, exist_ok=True)

# Remove prior Seti imagesets only
for d in list(assets.glob("seti-*.imageset")):
    shutil.rmtree(d)

(assets / "Contents.json").write_text(
    json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2)
)

copied, used_fallback = 0, 0
for key in sorted(keys):
    svg_name = icon_key_to_svg(key)
    src = src_icons / svg_name
    if not src.exists():
        if not fallback.exists():
            continue
        src = fallback
        used_fallback += 1
    name = asset_name(key)
    imageset = assets / f"{name}.imageset"
    imageset.mkdir(exist_ok=True)
    shutil.copy2(src, imageset / "icon.svg")
    (imageset / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "icon.svg", "idiom": "universal"}],
        "properties": {"preserves-vector-representation": True},
        "info": {"author": "xcode", "version": 1},
    }, indent=2))
    copied += 1

print(f"Wrote {copied} Seti imagesets to {assets}")
if used_fallback:
    print(f"Used default_light.svg for {used_fallback} missing variants")
PY

# Minimal AppIcon placeholder (required by ASSETCATALOG_COMPILER_APPICON_NAME)
APPICON="$ASSETS/AppIcon.appiconset"
if [[ ! -d "$APPICON" ]]; then
  mkdir -p "$APPICON"
  cat > "$APPICON/Contents.json" <<'JSON'
{
  "images": [],
  "info": { "author": "xcode", "version": 1 }
}
JSON
fi

echo "Done."
