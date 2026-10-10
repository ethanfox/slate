# ChatGPT: refresh the token, don’t make the user sign in again

Problem from 8 Oct 2026. Direction is locked.

A ChatGPT turn can last many sequential tool rounds. Membrae used to mint the access token once at the start and reuse it. When the token died mid-turn, the API said `token_expired` and the user had to reconnect.

## What to do

- Refresh when stored `expiresAt` or the JWT `exp` has less than 60 seconds left.
- Refresh again at the start of each tool round.
- On `401` / `token_expired`, refresh and retry that request once.
- Serialize refresh so two callers do not burn a one-time refresh token.

## Do not

- Ask the user to sign in because one request used a stale bearer
- Skip refresh because `expiresAt` still looks an hour away if the JWT is already dead
- Refresh on every send when the token is still valid

## Where it lives

`ChatGPTSignIn.validSession` / `needsRefresh` / `jwtExpiration`. `ChatGPTProvider.openAuthorizedStream`.

See also: [`chatgpt-lazy-prep.md`](chatgpt-lazy-prep.md), [`chatgpt-tool-budget.md`](chatgpt-tool-budget.md).
