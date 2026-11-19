# BAPS Kitchen App

BAPS Kitchen is an iOS SwiftUI inventory app for managing kitchen and pantry stock. It loads inventory from Google Sheets, groups items by category, and supports updating stock from the app.

## Features

- Browse ingredients by category.
- Search inventory with fuzzy matching and autocomplete suggestions.
- View and edit item quantities.
- Support standard measurements as well as spreadsheet-defined units such as `bottles`, `packets`, or `containers`.
- Track inventory changes when stock is updated.
- Integrate with Google Sheets for inventory data and Firebase for app services.

## Requirements

- macOS with Xcode.
- An iOS Simulator or physical iOS device.
- Access to the configured Google Sheet and Firebase project for live inventory data.

## Run Locally

1. Open `Baps Kitchen App.xcodeproj` in Xcode.
2. Allow Swift Package Manager to resolve dependencies.
3. Select the **Baps Kitchen App** scheme and an iOS Simulator or device.
4. Build and run the app.

For command-line builds, use:

```sh
xcodebuild -project "Baps Kitchen App.xcodeproj" \
  -scheme "Baps Kitchen App" \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build
```

## Project Layout

- `Baps Kitchen App/` - SwiftUI app source, models, services, Firebase configuration, and assets.
- `Baps Kitchen App.xcodeproj/` - Xcode project and Swift Package Manager resolution data.
- `scripts/` - utility scripts for organizing and updating inventory data.
- `AppsScript.js` - Google Apps Script support for spreadsheet updates.

## Data Notes

Inventory categories and stock values are read from Google Sheets. When a stock cell includes a unit beside the number, such as `12 bottles`, the app treats that as a fixed custom unit rather than offering a standard-unit selector.

## Security

Please see [SECURITY.md](SECURITY.md) for vulnerability reporting guidance.
