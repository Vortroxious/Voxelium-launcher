# Security

## Reporting
Report vulnerabilities privately to the repository owner through GitHub's private vulnerability reporting. Do not open a public issue.

## Current posture
- No passwords or tokens are stored. Only offline profiles exist. When Microsoft sign-in is added, tokens must go in the iOS Keychain and never in `settings.json` or logs.
- Every downloaded file with a published hash is SHA-1-verified before it is moved into place. SHA-1 matches Mojang's metadata. It protects against corruption, not against a compromised Mojang server.
- Paths derived from downloaded metadata are confined to the data directory (`AppPaths.resolve` rejects absolute paths and `..`).
- The version manifest itself has no published hash and is trusted over HTTPS.
- JIT requires a debugger-attached process. This weakens iOS code-signing protections for this app's process. Install development builds only on devices you control.
- Never distribute signing certificates, `.mobileprovision` files or StikDebug pairing files.
