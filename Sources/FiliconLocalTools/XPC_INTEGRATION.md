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
