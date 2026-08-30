# macOS release procedure

Filicon has two explicit release tiers. `local` creates an ad-hoc-signed bundle
for development. `production` is fail-closed: it requires a Developer ID
Application identity, notarization profile, signed update feed, and clean ZIP
and DMG verification.

## Local artifact

```sh
VERSION=1.0.0 BUILD_NUMBER=100 RELEASE_TIER=local \
  ./scripts/release-macos.sh
```

The result is intentionally not notarized and must not be published as a
production build.

## Current repository state

The release pipeline is implemented. This Mac now has a newly generated
Ed25519 update-feed signing key in the Keychain under service
`com.filicon.app.update-feed-signing-key` and account `production`; its private
material is not in the repository. The `filicon-notary` Keychain profile has
also been validated against App Store Connect using the existing Team API Key
and issuer. A real HTTPS feed base URL and publication destination are still
absent, so no signed-feed production artifact is claimed and `UPD-03` remains
the sole partial parity row. External release values are never committed.

## Production prerequisites

- A `Developer ID Application: …` identity installed in the signing keychain.
- A `notarytool` Keychain profile created with `xcrun notarytool store-credentials`.
- A 32-byte Ed25519 update-feed private key. On this Mac,
  `release-macos.sh` loads the default Keychain item automatically; CI may
  supply `FILICON_UPDATE_PRIVATE_KEY_BASE64` as a secret. The Keychain loader
  refuses to print unless invoked by the release process with its explicit
  flag. Never commit the private key.
- An HTTPS base URL where the immutable ZIP artifact will be published.

To create a new local signing key (only when no item exists for the selected
Keychain service/account), run:

```sh
./scripts/generate-update-feed-key.swift
```

Then run the production release:

```sh
VERSION=1.0.0 \
BUILD_NUMBER=100 \
RELEASE_TIER=production \
SIGN_IDENTITY='Developer ID Application: Example, Inc. (TEAMID)' \
NOTARY_PROFILE=filicon-notary \
FEED_BASE_URL='https://downloads.example.com/filicon' \
FILICON_UPDATE_PRIVATE_KEY_BASE64='…' \
./scripts/release-macos.sh
```

The script refuses a non-empty release directory and validates all required
credentials, credential-free HTTPS URLs, and signing-key encoding before
creating artifacts. It builds and signs the app and nested
helpers, submits and staples the app, creates and signs ZIP/DMG artifacts,
notarizes and staples the DMG, signs the selected update-channel feed, verifies
both clean-install containers, and writes `SHA256SUMS`.

## Publication gate

Do not publish unless all of the following completed in the same release run:

- `codesign --verify --deep --strict` passes.
- Gatekeeper accepts the app extracted from the ZIP and the app mounted from
  the read-only DMG.
- `stapler validate` passes for the app and DMG.
- The feed signature verifies with the public key embedded in the shipped app.
- `SHA256SUMS` matches the exact immutable artifacts uploaded to the feed URLs.
- A clean Mac can install, launch, check for an update, stage it, and relaunch
  on the updated version.

Developer ID and Apple notarization are external attestations. A local or CI
run without those credentials can validate packaging mechanics, but cannot be
reported as a notarized production release.

The final verifier recorded 553 passing tests (420 Swift Testing and 133
XCTest), WAE pass, release build pass, and local release `0.18.0-180`
verification plus launch smoke pass.
