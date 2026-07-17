# Release pipeline secrets

The release workflow in `.github/workflows/release.yml` is intentionally
separate from the unsigned build workflow. A build can run without any
secrets; a Developer ID release must provide the credentials below. Never
commit certificates, private keys, API keys, or their values to this
repository.

## Required for Developer ID releases

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

## Local release

`scripts/release-local.sh` reads the same values from environment variables:

```bash
export APPSIFT_TEAM_ID="<team id>"
export APPSIFT_SIGNING_IDENTITY="Developer ID Application: <name> (<team id>)"
scripts/release-local.sh 1.0.0 AC_NOTARY
```

The notary profile is created locally with Apple's `notarytool` and should
refer to a key stored outside the repository. The script fails early when the
team or signing identity is missing; it never falls back to an unrelated
developer identity.

## Certificate handling

Export only the certificate and private key needed for AppSift into a
temporary, access-controlled `.p12`. Verify the exact identity locally with:

```bash
security find-identity -v -p codesigning login.keychain-db
```

Upload the base64 value through GitHub's encrypted secret UI or `gh secret set`.
Delete temporary exports after upload. Do not paste certificate material into
issues, pull requests, logs, or release notes.

## Release checklist

1. Run the unsigned universal build and tests first.
2. Configure all Developer ID and notarization secrets.
3. Trigger the workflow with `workflow_dispatch` for the intended version.
4. Confirm the archive, `codesign`, `spctl`, `notarytool`, and stapler checks.
5. Publish the tag only after the dry run is green.

Every release note includes SHA-256 checksums. The README describes signing
status per release; do not advertise an artifact as signed or notarized until
those checks pass.
