#!/bin/bash
set -euo pipefail

VERSION="${1:-${VERSION:-}}"
if [ -z "$VERSION" ]; then
  echo "Usage: make release VERSION=x.y.z  (e.g., make release VERSION=0.7.0)"
  exit 1
fi

VERSION="${VERSION#v}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Preparing to release fleecr v$VERSION..."

# 1. Check CHANGELOG.md
if ! grep -q "^## \[$VERSION\]" CHANGELOG.md; then
  echo "Error: CHANGELOG.md has no section for [$VERSION]."
  echo "Please add '## [$VERSION] - YYYY-MM-DD' with release notes before releasing."
  exit 1
fi

# 2. Extract release notes
python3 - "$VERSION" <<'PYEOF'
import re, sys
version = sys.argv[1]
text = open("CHANGELOG.md").read()
m = re.search(rf"## \[{re.escape(version)}\][^\n]*\n(.*?)(?=\n## \[|\Z)", text, re.S)
if not m or not m.group(1).strip():
    sys.exit(f"CHANGELOG.md has no notes for {version}")
open("notes.md", "w").write(m.group(1).strip())
PYEOF

# 3. XcodeGen and Build
echo "==> Generating project with XcodeGen..."
xcodegen generate

echo "==> Building Release universal binary with local Xcode..."
rm -rf build-rel
xcodebuild -quiet -project fleecr.xcodeproj -scheme fleecr -configuration Release \
  -derivedDataPath build-rel build -skipPackagePluginValidation \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="1" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual

APP="build-rel/Build/Products/Release/Fleecr.app"
ZIP="fleecr-$VERSION.zip"

if [ ! -d "$APP" ]; then
  echo "Error: Build output $APP not found!"
  exit 1
fi

# 4. Package zip
echo "==> Packaging $ZIP..."
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "==> Built $ZIP with SHA256: $SHA"

# 5. Git tag & push
echo "==> Pushing git changes and tag v$VERSION..."
git add -A
if ! git diff-index --quiet HEAD --; then
  git commit -m "chore: release v$VERSION"
fi
git push origin main
git tag -f "v$VERSION"
git push origin "v$VERSION" --force

# 6. Publish to GitHub Release
echo "==> Publishing GitHub Release v$VERSION..."
if gh release view "v$VERSION" -R voidyuu/fleecr >/dev/null 2>&1; then
  gh release upload "v$VERSION" "$ZIP" --clobber -R voidyuu/fleecr
  gh release edit "v$VERSION" --title "fleecr $VERSION" --notes-file notes.md -R voidyuu/fleecr
else
  gh release create "v$VERSION" "$ZIP" --title "fleecr $VERSION" --notes-file notes.md -R voidyuu/fleecr
fi
rm -f notes.md

# 7. Update Homebrew Tap
echo "==> Updating Homebrew Tap..."
TAP_DIR="$HOME/Developer/homebrew-tap"
if [ -d "$TAP_DIR" ]; then
  (
    cd "$TAP_DIR"
    git pull --rebase
    sed -i '' -E "s|^  version \".*\"|  version \"$VERSION\"|" Casks/fleecr.rb
    sed -i '' -E "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" Casks/fleecr.rb
    git add Casks/fleecr.rb
    if ! git diff-index --quiet HEAD --; then
      git commit -m "chore(fleecr): bump to $VERSION"
      git push origin main
    fi
    echo "==> Successfully updated voidyuu/homebrew-tap to v$VERSION!"
  )
else
  echo "Warning: $TAP_DIR not found. Please manually update Casks/fleecr.rb with SHA256: $SHA"
fi

echo "=========================================="
echo "🎉 fleecr v$VERSION released successfully!"
echo "Download: https://github.com/voidyuu/fleecr/releases/tag/v$VERSION"
echo "Homebrew: brew install voidyuu/tap/fleecr"
echo "=========================================="
