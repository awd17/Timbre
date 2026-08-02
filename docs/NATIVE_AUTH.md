# Native Authentication (Clerk OAuth + PKCE)

First-pass native sign-in for the Timbre macOS app using Clerk as an OAuth
provider, Authorization Code + PKCE, `ASWebAuthenticationSession`, Keychain
credential storage, and the existing `GET /api/me` Route Handler.

## Architecture

| Type | Role |
|------|------|
| `AuthenticationController` | App-facing state: signed out / signing in / signed in / error |
| `AuthenticationService` | PKCE, authorize URL, `ASWebAuthenticationSession`, token exchange/refresh |
| `KeychainCredentialStore` | Persist access + refresh tokens |
| `TimbreAPIClient` | `GET {TIMBRE_API_BASE_URL}/api/me` with `Authorization: Bearer` |

Tokens never go through the callback URL. The callback carries only `code` +
`state` (or an OAuth error). PKCE verifier and `state` are cleared after
success, failure, or cancellation.

## Local configuration

```bash
cp Config/Auth.local.xcconfig.example Config/Auth.local.xcconfig
```

Fill in values from your Clerk OAuth application and discovery document:

```text
https://<YOUR_CLERK_FAPI>/.well-known/oauth-authorization-server
```

`Config/Auth.local.xcconfig` is gitignored. `Config/Auth.xcconfig` is the shared
base file referenced by the Timbre target and optionally includes the local file.

| Build setting | Purpose |
|---------------|---------|
| `CLERK_OAUTH_CLIENT_ID` | Public OAuth client ID (no secret) |
| `CLERK_AUTHORIZATION_URL` | `authorization_endpoint` from discovery |
| `CLERK_TOKEN_URL` | `token_endpoint` from discovery |
| `TIMBRE_API_BASE_URL` | Debug: `http://localhost:3000`; Release: `https://www.timbre.website/` |
| `TIMBRE_AUTH_CALLBACK_SCHEME` | `timbre-auth` |
| `TIMBRE_AUTH_REDIRECT_URI` | `timbre-auth://oauth/callback` |

These are substituted into `Timbre/Info.plist` at build time.

## Clerk Dashboard

1. Open **OAuth applications** and create an app for Timbre macOS.
2. Enable **Public** (PKCE; no client secret).
3. Scopes: `openid`, `profile`, `email`.
4. Redirect URI / callback: `timbre-auth://oauth/callback`.
5. Copy the client ID into `Auth.local.xcconfig`.
6. Confirm authorize/token URLs from
   `https://<instance>.clerk.accounts.dev/.well-known/oauth-authorization-server`
   (or your production Frontend API host).

## Xcode / app callback

| Setting | Value |
|---------|-------|
| Bundle ID (Release) | `com.augustdrakton.Timbre` |
| Bundle ID (Debug) | `com.augustdrakton.Timbre.debug` |
| URL scheme (`CFBundleURLTypes`) | `$(TIMBRE_AUTH_CALLBACK_SCHEME)` → `timbre-auth` |
| Redirect URI registered with Clerk | `timbre-auth://oauth/callback` |

Both Debug and Release Timbre targets use `Config/Auth.xcconfig` as their base
configuration.

The release API URL intentionally uses the canonical `www` host. The apex
`https://timbre.website/` currently redirects to that host; `URLSession` does
not forward an `Authorization` header across that cross-host redirect, so the
apex URL makes every native request look signed out.

## UI entry points

1. **Onboarding (first step)** — Sign In before Welcome when setup is incomplete.
2. **Settings → Account** — Sign in / out and show `/api/me` profile fields.
3. **Menu bar** — Sign In… (browser) / Sign Out.

Completed onboarding users are not forced back into setup for auth; they use
Settings or the menu bar.

## Auth flow

```text
Sign In
  → generate PKCE verifier + S256 challenge + state
  → ASWebAuthenticationSession → Clerk authorize URL
  → callback timbre-auth://oauth/callback?code&state
  → validate state
  → POST token URL (code + code_verifier, no client_secret)
  → store tokens in Keychain
  → GET /api/me with Bearer access token
  → show user profile / continue onboarding
```

On later launches, Timbre loads Keychain credentials, refreshes the access token
when expired or on `401`, then retries `/api/me` once.

## Important: `/api/me` token verification

The deployed `timbre-web` `GET /api/me` handler must accept both browser
sessions and native OAuth bearer tokens. Use Clerk's explicit token acceptance:

```ts
const { isAuthenticated, userId } = await auth({
  acceptsToken: ["session_token", "oauth_token"],
})
```

The native app can complete the OAuth exchange and save credentials successfully
while `/api/me` still returns `401` if this backend change is not deployed.

## Pre-release Release-binary smoke test

Run the local `timbre-web` checkout with its Clerk environment first:

```bash
cd ../timbre-web
npm run dev
```

Then, from this repository, build and package the exact ad-hoc-signed Release
shape used by GitHub without creating a release:

```bash
scripts/run-release-auth-smoke.sh --launch
```

The script defaults to `http://127.0.0.1:3000`, validates the Release bundle
ID and embedded API URL, verifies the ad-hoc signature, and produces a local
DMG. Add `--fresh` for an interactive fresh-user reset, or set
`TIMBRE_RELEASE_SMOKE_API_BASE_URL=https://www.timbre.website/` to exercise the
deployed API with the Release bundle's existing credentials.

## Manual test checklist

1. Signed-out user starts Sign In from onboarding / Settings / menu.
2. Clerk opens via `ASWebAuthenticationSession`.
3. Success returns to Timbre; profile loads from `/api/me` (after web fix).
4. Quit and relaunch restores the session from Keychain.
5. Expired access token refreshes; one retry of `/api/me`.
6. Sign Out clears Keychain credentials.
7. Cancel browser auth returns UI to a usable signed-out state.
8. Failed / unauthorized API shows a recoverable error.
9. Logs never print access tokens, refresh tokens, or authorization codes.

## Security notes

- Public client only — no Clerk client secret in the app.
- HTTPS for authorize, token, and API calls (local `http://localhost` API base
  is allowed for development).
- TLS validation is not disabled.
- Ephemeral PKCE + state values are cleared after the flow ends.
