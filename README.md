<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/Brand/fleck-lockup-white.png">
    <img src="Assets/Brand/fleck-lockup-black.png" alt="Fleck" width="240">
  </picture>
</h1>

<p align="center">Local-first notes for the macOS menu bar.</p>

<p align="center">
  <a href="#try-the-developer-preview"><img alt="macOS 14+ deployment target" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&amp;logoColor=white"></a>
  <a href="Package.swift"><img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&amp;logoColor=white"></a>
  <a href="https://github.com/elevatesoft/Fleck/actions/workflows/ci.yml?query=branch%3Amain"><img alt="CI status for main" src="https://github.com/elevatesoft/Fleck/actions/workflows/ci.yml/badge.svg?branch=main"></a>
  <a href="LICENSE"><img alt="License: MPL-2.0" src="https://img.shields.io/badge/license-MPL--2.0-6355a6"></a>
</p>

Fleck is a place to catch a thought without leaving what you're doing. Open it
from the menu bar, type or dictate a note, then come back to edit it, file it in
a folder, or link it to another note. Fleck saves your notes as readable
Markdown with rich-text formatting stored separately on your Mac. You don't
need a Fleck account, and Fleck doesn't sync your notes to the cloud.

You can also give an AI tool access to a note without handing it your whole
workspace. The optional **Agent Connector** connects a compatible Model Context
Protocol (MCP) client through a local helper. You choose which notes or folders
the client can access and whether it can edit them. You can see its changes in
Activity and undo eligible edits. Fleck's connection is local; the client you
choose may use an online service.

## Try the Developer Preview

The published app is [Fleck 1.1.2-beta.2 (Build 84)](https://github.com/elevatesoft/Fleck/releases/tag/v1.1.2-beta.2),
an early preview for **Apple silicon**. macOS 14 is the declared minimum, but a
full macOS 14 native test pass and Intel compatibility haven't been verified.
The preview isn't notarized, and behavior and storage formats may change.

1. In the release's **Assets**, download `Fleck.1.1.2-beta.2.Build.84.app.zip`,
   not a **Source code** archive. In Terminal, from the folder containing the
   ZIP, run `shasum -a 256 Fleck.1.1.2-beta.2.Build.84.app.zip` and compare
   the result with the SHA-256 shown on the release page.
2. Extract the ZIP and drag `Fleck 1.1.2-beta.2 Build 84.app` to **Applications**.
   Try opening it there. If macOS warns about the lack of notarization, see
   [Apple's guidance](https://support.apple.com/en-us/102445) before deciding
   whether to open it. Don't disable Gatekeeper.
3. Click Fleck's four-tile mark in the **menu bar** (there's no Dock icon).
   Create a note and start typing, or click the toolbar microphone and grant
   microphone permission to try Apple's on-device dictation.

The preview already lets you format notes, organize them with tabs and folders,
search across your workspace, and insert `[[note links]]` that create backlinks.
Drag an image file from Finder to put it inline; exported notes reference the
local image rather than embedding it. Follow the
[first-launch guide](docs/release-notes/1.1.2-beta.2.md) for shortcuts, more
editing features, and Agent Connector setup.

## What's in the source

![Fleck's dark workspace showing note tabs, a file shortcut, and the rich-text editor](docs/images/fleck-workspace.png)

*Screenshot from a development build with sample notes; the downloadable
preview may look different.*

Public `main` is newer than the downloadable preview. For example, it adds
inline image resizing and rotation; those controls aren't in Build 84.
[`VERSION`](VERSION) identifies the source tree's version, not an available
download. Use [GitHub Releases](https://github.com/elevatesoft/Fleck/releases) to
see which app packages are available and the [changelog](CHANGELOG.md) for source
changes. Local development builds and CI artifacts aren't public releases.

## Work on Fleck

The current source needs **Xcode 26 or later**, the full **macOS 26 SDK**, and
**Swift 6**. The standalone Command Line Tools aren't enough.

```sh
git clone https://github.com/elevatesoft/Fleck.git
cd Fleck
unset FLECK_ENHANCED_CANDIDATE
Scripts/run-nonempty-swift-tests.sh '^.+$'
```

Some native tests open synthetic AppKit fixture windows and can change focus;
use a disposable macOS test account. See [Testing](TESTING.md) for setup and
manual checks, and the [release policy](docs/RELEASES.md) and
[build identity guide](docs/build-identity.md) for packaging requirements.

- [Product overview](PRODUCT.md), [product plan](PRODUCT_PLAN.md), and
  [implementation status](IMPLEMENTATION_STATUS.md) explain the scope and
  distinguish the ordinary app from experimental source work.
- [Architecture](ARCHITECTURE.md) covers persistence, dictation, and the local
  Agent Connector. The [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)
  and other dependency pins are in [`Package.resolved`](Package.resolved).
- For bugs or ideas, use [GitHub Issues](https://github.com/elevatesoft/Fleck/issues).
  See [Contributing](CONTRIBUTING.md) before opening a pull request. Report
  vulnerabilities or conduct concerns through the private routes in
  [Security](SECURITY.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

Fleck's current first-party source and documentation are licensed under the
[Mozilla Public License 2.0](LICENSE), with exceptions in [NOTICE](NOTICE) and
[Third-party notices](THIRD_PARTY_NOTICES.md). Dependencies, data, and models
have their own terms; the app's
[third-party notices](Sources/FleckApp/Resources/ThirdPartyNotices.md) record
attribution. The Fleck name, logo, and listed brand assets are covered by the
separate [branding policy](BRANDING.md). Earlier revisions retain their
accompanying license terms. No contributor license agreement is required.
