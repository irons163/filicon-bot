# App-bundle XPC wiring

The shipping bundle now embeds `FiliconLocalToolService.xpc`. Its exported
`FiliconLocalToolXPCProtocol` accepts only encoded request/response data and
owns the `LocalToolProcessHost`; filesystem descriptors and child-process
handles never live in the app process.

The boundary enforces:

1. same-user client validation plus signing-identifier and, for Developer ID
   builds, Team ID matching;
2. a fresh generation and 32-byte-or-longer HMAC session key per connection;
3. replay-resistant request IDs/nonces, expiry, direction epochs, and exact
   action/target permission receipts;
4. sandboxed XPC execution without network or Keychain entitlements;
5. security-scoped bookmarks for every filesystem/working-directory root;
6. literal `posix_spawn` argv, bounded output, timeouts, and process-group
   cancellation.

`scripts/package-app.sh` builds the XPC executable, lays out its `.xpc` bundle,
signs it before the containing app, and verifies the final nested signature.
`FiliconLocalToolHelper` remains only a JSON-lines diagnostic harness; normal
shipping execution uses `LocalToolXPCClient`.

The main app owns persistent, app-scoped bookmarks. Before a tool request it
resolves only the registered exact root and creates an ephemeral transport
bookmark (`options: []`). The separately signed XPC service resolves that
bookmark without implicitly starting access, checks the exact root, then
explicitly starts and stops its security scope. Forwarding a persistent
app-scoped bookmark directly to the service fails because it belongs to a
different signing identity. See Apple's [cross-process bookmark guidance](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).

App-scoped grants can also stop resolving after the main app's own identity
changes (including ad-hoc rebuilds). Apple's [bookmark API documentation](https://developer.apple.com/documentation/foundation/nsurl/bookmarkdata(options:includingresourcevaluesforkeys:relativeto:))
requires the resolving caller to have the creating caller's signing identity.
The localized Cocoa 259 message describes a file format error, but in this
path it means resolution of saved authorization failed before project I/O.
`accessState` distinguishes stored-but-invalid grants from valid exact roots.
Discovery excludes them from `authorized_roots`; if no usable grant remains,
or a scoped tool targets an invalid grant, the conversation asks for renewed
native folder selection before operation review. Cancellation retains the
old record but cannot use it. No unscoped resolution, implicit path-based
reauthorization, or sandbox relaxation is used as recovery.

For Xcode development, open `Filicon.xcworkspace` and select **Filicon App**.
Native App, XPC Service, and helper targets build and embed all executables.
The Debug service uses `Support/LocalToolService-Debug.entitlements`: Xcode
expands `$(BUILT_PRODUCTS_DIR)/Filicon.app/` into one exact, read-only sandbox
exception for client-signature inspection. No project directory or parent of
the app bundle is granted. The existing client-signature gate is unchanged.
Release and standalone packaging continue to use the production entitlements
without this exception. `⌘U` runs `XcodeTests/PackagedLocalToolTests.swift` inside
the real app against the real embedded service, with isolated data and fixtures.
The shared scheme disables XPC debugger attachment for normal Run. XCTest can
still re-sign services with testmanager access and read-only `/`; hosted tests
alone are therefore not evidence of the strict sandbox. After a clean normal
Debug build, `scripts/smoke-xcode-xpc.sh` verifies exact entitlements and uses
the actual built service in a separate diagnostic app with temporary fixtures,
without XCTest. `verify-package.sh --xcode-debug` rejects expanded exceptions;
production verification also rejects all temporary exceptions and debugger
attachment rights. Debugging the parent app remains enabled.

Run standalone/release packaged apps from `/Applications`. A sandboxed
service may be unable to read the client signature when the parent executable
is in a repository or temporary directory. Keep the signature check and service
sandbox enabled; an unbundled `swift run` is a UI-development launch, not an XPC
integration test. Test real packaged read/write separately from in-process
unit tests.
