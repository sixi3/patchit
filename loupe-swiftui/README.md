# Loupe SwiftUI

Separate native iOS prototype for Loupe. This app is intentionally independent
from the React Native/Expo build and currently contains only the homescreen.

## Generate

```bash
cd /Users/anandmenon/Documents/Dash/loupe-swiftui
xcodegen generate
```

## Build

```bash
xcodebuild \
  -project LoupeSwiftUI.xcodeproj \
  -scheme LoupeSwiftUI \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ./DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Run

Open `LoupeSwiftUI.xcodeproj` in Xcode, choose an iPhone simulator, and run the
`LoupeSwiftUI` scheme. Bundle id: `com.sixi3.loupe.swiftui`.
