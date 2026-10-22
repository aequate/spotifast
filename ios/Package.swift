// swift-tools-version: 5.9
import PackageDescription

// Compile the very same production sources on Linux. Apple audio, security,
// QR and UI integrations are exercised by the Xcode target instead.
let package = Package(
    name: "SpotifastLogic",
    products: [.library(name: "SpotifastLogic", targets: ["SpotifastLogic"])],
    targets: [
        .target(name: "SpotifastLogic", path: "Spotifast", exclude: [
            "AppStore.swift", "Artwork.swift", "Assets.xcassets", "AudioOutput.swift",
            "Authentication.swift", "BrowseViews.swift", "CollectionView.swift", "Components.swift",
            "JamInvite.swift", "JamView.swift", "PlayerView.swift", "PlaylistItemsEditor.swift",
            "PrivacyInfo.xcprivacy", "RustBridge.swift", "SettingsView.swift", "SpotifastApp.swift"
        ], sources: ["Models.swift", "AudioInterruptionGate.swift", "RequestGate.swift", "OAuthModels.swift", "CacheStore.swift", "Preferences.swift", "PlaylistEdits.swift", "NetworkTransport.swift", "SpotifyAPI.swift"]),
        .testTarget(name: "SpotifastLogicTests", dependencies: ["SpotifastLogic"], path: "PortableTests")
    ]
)
