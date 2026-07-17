# Release pipeline secrets

## Current self-signed customer releases

Customer Release artifacts currently use the same `AppSift Local Code Signing`
identity as local development and installation builds:

```bash
cd /absolute/path/to/AppSift && scripts/release-self-signed.sh
```

The private key stays in the local login keychain. Do not export it into the
repository or upload it to GitHub Actions. The generated status file must ship
with the artifacts and must state that they are self-signed and not notarized.

The Developer ID workflow below is retained only for a future explicit
certificate migration. It is manual-only because switching identities causes
one macOS privacy-permission migration.

The release workflow in `.github/workflows/release.yml` is intentionally
separate from the non-distribution build workflow. A build can run without any
secrets; a Developer ID release must provide the credentials below. Never
commit certificates, private keys, API keys, or their values to this
repository.

## Future Developer ID releases

| Secret | Meaning |
| --- | --- |
| `DEVELOPMENT_TEAM_ID` | Apple Developer Team ID that owns the Developer ID certificate |
| `DEVELOPER_ID_APPLICATION` | Exact keychain identity, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `BUILD_CERTIFICATE_BASE64` | Base64-encoded `.p12` containing the matching Developer ID certificate and private key |
| `P12_PASSWORD` | Password used to export the `.p12` |
| `KEYCHAIN_PASSWORD` | One-time password for the runner's temporary keychain |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key ID used by `notarytool` |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect issuer UUID |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Full contents of the matching `.p8` private key |

`HOMEBREW_TAP_TOKEN` is optional. If it is absent, the in-repository cask is
still updated, while a separate tap is left untouched.

## Current local compatibility entry point

`scripts/release-local.sh` forwards to the current self-signed builder. It does
not read Developer ID or notarization credentials:

```bash
scripts/release-local.sh
```

Passing an old notarization-profile argument fails explicitly. A future
Developer ID migration must use the gated GitHub workflow.

## Certificate handling

Export only the certificate and private key needed for AppSift into a
temporary, access-controlled `.p12`. Verify the exact identity locally with:

```bash
security find-identity -v -p codesigning login.keychain-db
```

Upload the base64 value through GitHub's encrypted secret UI or `gh secret set`.
Delete temporary exports after upload. Do not paste certificate material into
issues, pull requests, logs, or release notes.

## Future Developer ID migration checklist

1. Run the non-Developer-ID universal build and tests first.
2. Configure all Developer ID and notarization secrets.
3. Trigger the workflow with `workflow_dispatch` for the intended version.
4. Confirm the archive, `codesign`, `spctl`, `notarytool`, and stapler checks.
5. Publish the tag only after the dry run is green.

Every release note includes SHA-256 checksums. The README describes signing
status per release; do not advertise an artifact as signed or notarized until
those checks pass.
