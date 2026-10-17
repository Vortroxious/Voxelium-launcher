# Microsoft account sign-in

## Default: Live web sign-in (as Amethyst-iOS)

On 2026-10-17 the user chose to sign in the way Amethyst-iOS and PojavLauncher do, so that sign-in works without waiting for Mojang to approve an app ID:

- **Sign-in page:** `https://login.live.com/oauth20_authorize.srf`, shown in an `ASWebAuthenticationSession` (ephemeral, so no shared Safari cookies).
  - client ID `00000000402b5328`: Microsoft's own Minecraft launcher client, not one registered by this project;
  - scope `service::user.auth.xboxlive.com::MBI_SSL`;
  - the browser returns to `ms-xal-00000000402b5328://…?code=…`.
- **Code exchange:** the code is redeemed (and later refreshed) at `https://login.live.com/oauth20_token.srf`.
- **Xbox Live:** the Live token goes to Xbox Live as a bare RPS ticket (no `d=`). The rest of the chain is shared with the device-code flow.
- **What this does and doesn't mean:**
  - You still sign in with your own Microsoft account on Microsoft's page, and Mojang still checks game ownership.
  - Nothing bypasses authentication or entitlements.
  - The ID is not ours, though, so Microsoft can block it for third-party use at any time. If that happens, use your own approved ID (below).

Reference: Amethyst-iOS `Natives/AccountListViewController.m` (`actionLoginMicrosoft`) and `Natives/authenticator/MicrosoftAuthenticator.m` (GPL-3.0).

## With your own Azure app ID: device code (as ZalithLauncher2)

If a build bundles `microsoft-client-id.txt` (see "The app (client) ID" below), the app uses the device-code flow from ZalithLauncher2 (`MicrosoftAuthenticator.kt`) instead:

1. Microsoft identity platform **device code** flow (`login.microsoftonline.com/consumers`, scope `XboxLive.signin offline_access`).
2. Xbox Live `user/authenticate` with the RPS ticket `d=<token>`. As upstream does, it retries without `d=` on HTTP 400.
3. XSTS `xsts/authorize` for `rp://api.minecraftservices.com/`. XErr codes are explained to the user.
4. Minecraft services: `authentication/login_with_xbox`, then `entitlements/mcstore` (game ownership), then `minecraft/profile`.

The code is in `Sources/ZalithCore/Accounts/MicrosoftAuth.swift`, tested with mocked responses in `Tests/ZalithCoreTests/MicrosoftAuthTests.swift`. The app side is in `App/ZalithIOS/AccountModel.swift`.

## Secrets

- The Minecraft access token, its expiry and the Microsoft refresh token are stored **only** in the iOS Keychain:
  - service `io.github.zalithios.microsoft`;
  - accessibility `AfterFirstUnlockThisDeviceOnly`.
  They are never written to settings.json, launcher.log or jvm.log. The launch log records only the player name and the user type.
- The token reaches the game as `--accessToken` (Minecraft hides it in its own logs and crash reports).
- Before launch, the token is refreshed when it has less than an hour left.

## The app (client) ID

Like ZalithLauncher2, which keeps its own ID in a CI secret, this repository contains no ID of its own. Without one, the app uses the Live web sign-in above.

To build with your own ID instead:

1. **Register an app** in the Azure portal (App registrations → New registration):
   - Supported account types: **Personal Microsoft accounts only** (the `consumers` tenant is required for `XboxLive.signin`).
   - Authentication → **Allow public client flows: Yes** (device code flow).
2. **Apply to Mojang** for Minecraft API access for that client ID: <https://aka.ms/mce-reviewappid>.
   - Until it is approved, `api.minecraftservices.com` answers **HTTP 403** ("Invalid app registration"), and the app reports that clearly.
   - Approval reportedly takes up to a few weeks.
3. **Add the ID to your build:** put it in `.oauth_client_id.txt` at the repository root (git-ignored), or set `ZL_MS_CLIENT_ID` when running `scripts/build-ipa.sh`. The "Bundle Java runtime" build phase writes it into the app as `microsoft-client-id.txt`.

Do not borrow another launcher's own registered client ID (such as ZalithLauncher2's) without that project's permission.

## Status

- Implemented and unit-tested; 75/75 tests pass. The tests cover:
  - the Live web sign-in (authorize URL, callback parsing, code exchange, bare RPS ticket, refresh);
  - the device-code flow, including `authorization_pending` and `slow_down`;
  - XSTS errors, the unapproved app (403), and no game ownership;
  - refresh, and an expired refresh token.
- **Not yet verified against the real services or on a device.**

Sources: [Minecraft Wiki, Microsoft Authentication Scheme](https://minecraft.wiki/w/Minecraft_Wiki:Projects/wiki.vg_merge/Microsoft_Authentication_Scheme); [AuthMe issue #109 (approval form)](https://git.tdem.in/axieum/authme/issues/109); [Microsoft Q&A on "Invalid app registration"](https://learn.microsoft.com/en-us/answers/a/12581049); ZalithLauncher2 2.6.1 source.
