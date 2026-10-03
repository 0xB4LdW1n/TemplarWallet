# Templar Protocol connector

Templar Wallet is the user-held signing wallet of the Templar Protocol, the
peer-to-peer Liquid lending protocol. The contract between the two is
`docs/connector-protocol.md` in the Templar Protocol repository; this guide is
the wallet side of it.

## What the wallet does

| Step | Where | What |
|---|---|---|
| Liquid network | Settings › Templar Protocol (and Network & Sync) | `testnet` (public) or `regtest` (a local `elementsd`, what the Templar Protocol runs for development). The wallet refuses any request whose `network` differs — and offers the switch on the spot (see *When the networks disagree*). |
| `templar://connect` | opened from the site's "Connect Templar Wallet" link | Fetches the request, checks version / nonce / origin / transport / expiry, lets the user pick a Liquid wallet (a software seed, or a Jade), shows the watch-only CT descriptor, the loan key (`[fp/2121h/1h/0h]tpub…` from a seed, `[fp/87h/1h/0h]tpub…` from a Jade) and a receive address, and POSTs them after the app password. When the site sent a `challenge` (v1.1) a software wallet also signs the **proof of key** (below) and sends it as `proof`; the answer's `portfolio` object is kept for the Loans page. |
| `templar://sign` | opened from a loan page | Fetches the request, shows the site's summary **next to** the wallet's own reading of the PSET (`inspect_pset`: which inputs ask for our key, which outputs are ours / an escrow / external, fee, network), requires the checkbox + app password, signs with `sign_pset` (or `sign_pset_hw` on a Jade) and POSTs the signed PSET. Never broadcasts, never stores the PSET. |
| `templar://sign` with `action: "proof"` | opened from the site's check page (a 0.1.0-style reconnect, «Ritrova», «Un altro wallet») | The strict review of contract §9.5: the engine rebuilds the check PSET from the request's `challenge` and this wallet's loan key (`protocol_is_check_pset`) and the screen **refuses anything else** — a real-looking prevout, a coin worth anything, another challenge, another key, an extra output, a non-zero fee, another chain's L-BTC — naming the reason. It shows the challenge line verbatim, the site origin, the expiry and «This signature never moves funds»; the wallet's own reading (not my coin, 0, OP_RETURN, fee 0) sits underneath. Then it signs through the ordinary route. |

| Loans (`/loans`) | beside the Dashboard; a carousel tab on a phone; the Liquid panel's row on the desktop dashboard | The wallet's loans as the connected site reports them (`GET /connector/portfolio`, §7, with the bearer token the connect answer handed back): one card per loan — reference, role, state, the site's «what happens now», the term as a bar with «≈ N d/h left» and the due estimate, owed / principal / collateral / interest / Templar fee — then the wallet's own offers and the closed loans under an expander. **Sign now** feeds the loan's `templar://sign` link to the app's own link handler (no browser round-trip); **Open on Templar Protocol** asks `POST /connector/open` (bearer token, `{"to": "/loans/<id>"}`, or `/` from the header) for a one-time link and opens it in the system browser, which lands already inside the wallet's session (§8) — the token never goes in a URL, the link is single use and dies in two minutes, a link to another host is refused; **Refresh** asks again. Pulled on open, on Refresh and after every signature answered for that site. `401` drops the token and the page says «Reconnect to see your loans»; `429` and a network failure keep the last answer on screen with the reason. Nothing is persisted but the token. |

Settings › Templar Protocol (`/settings/protocol`, one tap from the Loans
page) is where the connector's bookkeeping is visible: readiness, the paste
box, the connected sites, what was signed, and the wallet that answers by
default — with a Loans shortcut at its top and «How it works» folded under an
expander.

A site connected by Templar 0.1.0 handed back no token: its row on the Loans
page says so and offers the site, where «Connect Templar Wallet» issues one
(a v1.1 wallet proves its key inline and gets the token in the same answer;
see §9 of the contract). **Forget** on such a site also sends
`DELETE /connector/portfolio` so the token dies on the site's side too.

The escrow key is a dedicated hardened account (`m/2121'/1'/0'`) below the
seed: it never collides with spending keys (`84'`) or multisig keys (`87'`),
and a plain `sign_pset` finds it by fingerprint, so no descriptor import is
needed to sign a loan.

FFI methods: `get_protocol_escrow_xpub {wallet_id}`, `inspect_pset` (now with
`network`, `inputs[]`, `outputs[]`), `sign_pset` / `sign_pset_hw`,
`protocol_check_pset {wallet_id, challenge}` → `{pset_base64, loan_key,
fingerprint}` and `protocol_is_check_pset {wallet_id, challenge, pset_base64}`
→ `{is_check, reason, loan_key_fingerprint}`.

## Proof of key

The site identifies a wallet by its loan key and lets it back in — to its
loans, from a new browser — by a signature on the **check PSET** of contract
§9.1, deterministic from the challenge text and the key:

```
pk        = K/0/0
fake_txid = sha256("templar-proof" ‖ challenge)
input 0   prevout (fake_txid, 0), sequence 0xffffffff, SIGHASH_ALL,
          witness_utxo = explicit 0 L-BTC to P2WPKH(pk), bip32_derivation [fp/…/0/0]
output 0  OP_RETURN(challenge), explicit 0, policy asset
output 1  fee, explicit 0
locktime 0, PSET v2
```

It can never be broadcast (the prevout does not exist, value 0, fee 0), and
the sighash commits to the challenge — origin, single-use nonce, expiry — so
one proof is good for one site and one challenge. `templar-core` builds it
(`check_pset`), recognises it (`check_pset_shape` / `is_check_pset`, every
refusal with its reason) and carries the site's own verification
(`verify_check_signature`) so the tests prove what a site will accept. The
challenge is kept verbatim from the JSON: it is what gets hashed.

Two paths:

- **v1.1 connect** (§9.3): the connect JSON carries `challenge`; after the
  password gate the wallet builds the check, signs it with `sign_pset` like
  any PSET naming its key, and sends `"proof": {"kind": "check-pset",
  "pset": …}`. With a valid proof the site re-attaches the wallet's loans in
  one step and hands back the `portfolio` token.
- **`templar://sign` with action `proof`** (§9.2, what a 0.1.0 wallet
  already signs, and what a Jade is sent to): the strict review above.

**Jade.** A Jade-backed wallet connects with its BIP87 account
(`keyorigin_xpub(Bip87)`, the key its Liquid multisigs enrol), which the site
accepts as a loan key. Proving the key through the device is **not supported
yet**: the check carries an explicit zero-value input, and Jade's signing of
such an input has not been exercised on hardware. Every proof route — the
connect's proof card, the `proof` review, `protocol_check_pset` and
`protocol_is_check_pset` — says so in the same sentence and points to a
software wallet; the site, seeing no proof in the callback, falls back to a
signing request when it needs one.

## When the networks disagree

`validateProtocolRequest` throws a typed `ProtocolNetworkMismatch`
(`features/protocol/models/protocol_link.dart`) instead of a sentence, and the
request screen renders `ProtocolNetworkMismatchCard` instead of the generic
error. Three kinds:

| Kind | When | What the card offers |
|---|---|---|
| `network` | The site is on the other network Templar runs (`liquid-testnet` ↔ `liquid-regtest`). | **Switch this wallet to Liquid regtest/testnet**, then the request is fetched again by itself. |
| `chain` | Both say `liquid-regtest` but the policy assets differ — two `elementsd` instances started separately are different chains. | **Switch this wallet to the site's chain**, re-applying regtest with the site's asset id. |
| `unsupported` | `liquid` (mainnet) or a name this build does not know. | Only **Open Network settings** — no button that cannot work. |

Two extra cases: when `TEMPLAR_LIQUID_NETWORK` fixes the network for the run,
the card explains that and drops the switch; and when the site's token died
while the network was being switched, the request screen's refusal offers
**Open \<site\>**, because a single-use token is handed out again there, not
here.

The switch itself is `switchLiquidNetwork` in
`features/settings/liquid_network_switch.dart` — the same confirmation, the
same closing of the open wallet, shared with Settings › Network & Sync so the
two cannot drift. After it, the wallet list is read again and the wallet
chosen anew: the engine closed whatever was open.

### `policy_asset`

On regtest the connect and sign JSON may carry an optional `policy_asset`: the
L-BTC asset id of the site's chain, 64 hex characters, lower case.

```json
{
  "version": 1,
  "kind": "connect",
  "network": "liquid-regtest",
  "policy_asset": "5ac9f65c0efcc4775e0baec4ec03abdde22473cd3cf33c0419ca290e0751b225",
  "…": "…"
}
```

The wallet uses it twice: to notice a same-name, different-chain mismatch, and
to prefill the asset id the switch applies (editable in the card; without it
the stock `liquidregtest` id is offered). A value that is not 64 hex characters
is ignored rather than treated as another chain. It is meaningless on testnet
and is not read there.

## Settings › Templar Protocol

| Card | What it does |
|---|---|
| Status | "Ready for Liquid regtest · policy asset 5ac9…b225", the chain endpoint, **Change network** (the shared switch), or the env-locked notice. |
| Open a request | Paste a `templar://` link or scan its QR — the fallback for when the site could not open Templar itself. |
| Connected sites | Every site holding a watch-only view: name, origin, network, wallet, when, and what it received. **Forget** removes the local record only, and says so: nothing in the protocol revokes a descriptor, and the site keeps it until the wallet is removed there. |
| Signing history | The last 50 requests: loan ref, action, site, wallet, date, outcome (signed / refused by you / expired / failed). **Clear history**. |
| Preferred wallet | The wallet a signing request is answered with and the one offered first on connect. It never replaces the confirm gate: password plus checkbox, every time. |
| How it works | Three steps and a link to this guide. |

The records live in SharedPreferences (`services/protocol_store.dart`:
`protocol_sites_v1`, `protocol_history_v1`, `protocol_preferred_wallet_v1`) — no secret,
so no vault and no keychain. They are local to the device: not in a backup, not
on another machine. What they never hold: the PSET, the amounts, the site's
summary, the CT descriptor or any key — the escrow key appears as its
fingerprint alone. Deleting a wallet deletes its records with it.

## URL scheme registration

| OS | Registration | Notes |
|---|---|---|
| macOS | `macos/Runner/Info.plist` `CFBundleURLTypes` (`templar`) | Launch Services registers the scheme when the `.app` is built or copied to `/Applications`. |
| Linux | `packaging/linux/dev.templarwallet.templar_wallet.desktop` (`MimeType=x-scheme-handler/templar;`, `Exec=templar_wallet %u`) | Install the file into `~/.local/share/applications/` (or `/usr/share/applications/`) with the executable on `PATH`, then `xdg-mime default dev.templarwallet.templar_wallet.desktop x-scheme-handler/templar`. The runner is a unique `GApplication`; a second launch forwards the link to the running window. |
| Windows | `packaging/windows/templar-wallet.iss` `[Registry]` (`HKA\Software\Classes\templar`) | The installer registers the scheme; the plain zip does not. A second launch hands the link to the running instance (`windows/runner/main.cpp`). |

Links are received by the `app_links` package (`lib/services/protocol_link_service.dart`)
and delivered only once the vault is unlocked; links that arrive earlier
wait. A link can also be pasted or scanned from Settings ›
Templar Protocol › Open a request.

## Testing without the web side

The fixtures in `docs/fixtures/protocol/` stand in for a protocol site:

```bash
python3 scripts/protocol_fixture_server.py          # serves the fixtures on 127.0.0.1:8765
                                                 # and prints every callback body
open "templar://connect?url=http://127.0.0.1:8765/connect.json&nonce=fixture-nonce-connect"
open "templar://sign?url=http://127.0.0.1:8765/sign.json&nonce=fixture-nonce-sign"
```

The fixtures are on **Liquid testnet**. The sign fixture spends a fake loan
escrow whose contract names the key of the BIP39 test vector
`abandon abandon … about` (fingerprint `73c5da0a`); restore that phrase as a
software wallet with Liquid enabled and the request shows the escrow input as
*escrow · your key*. Any other wallet sees *contract · not yours* and the
gate stays disabled.

Plain `http://` is accepted only for `localhost` / `127.0.0.1`; a remote site
must use `https://`.

## Against the Templar Protocol on regtest

Start the protocol's local regtest node and site as its repository describes
(the node listens on `127.0.0.1:18884` with RPC user and password `templar`,
the wallet's defaults). Then, in Templar: Settings › Network & Sync › Liquid
network → Regtest, reopen the wallet, sync, and fund a Liquid receive address
from the node.

Register on the site, click "Connect Templar Wallet" on `/wallet`, pick the
wallet, confirm. Take an offer as that user; the origination signing request
opens through `templar://sign`.

### Headless acceptance

Two ignored contract tests in `src/wallet-ffi/src/contract_tests.rs` drive
the exact FFI dispatch the app calls against the running site, so the wire
contract can be checked without the GUI:

```bash
# 1. In a browser without a wallet (or with curl and a fresh cookie jar), press
#    "Connect Templar Wallet" on /wallet and copy its templar://connect link.
TEMPLAR_LIVE_CONNECT_LINK='templar://connect?url=…&nonce=…' \
  cargo test -p wallet-ffi live_connect -- --ignored --nocapture
#    → connects with the proof of key in the callback, reads GET /connector/portfolio
#      with the token it got back (TEMPLAR_LIVE_OUT=file saves the JSON), mints a
#      POST /connector/open link and prints it: open it in a browser to land signed in.
#    TEMPLAR_LIVE_NO_PROOF=1 answers like 0.1.0 instead and asserts the site leads
#    to /wallet/prove/<id> with no token.

# 2. From that prove page (or «Find your loans»), copy the templar://sign link.
TEMPLAR_LIVE_SIGN_LINK='templar://sign?url=…&nonce=…' \
  cargo test -p wallet-ffi live_proof -- --ignored --nocapture
#    → protocol_is_check_pset must say yes to the site-built check, sign_pset
#      signs it, the callback is accepted and carries the portfolio token.
```

`TEMPLAR_LIVE_MNEMONIC` picks the wallet (default: the BIP39 test vector,
fingerprint `73c5da0a`). Both ran green against the site on 2026-10-03.

## Limits (v1)

- Connect takes a software wallet or a Jade (BIP87 loan key). Signing a
  loan step accepts both; signing the proof of key needs a software wallet
  for now (see *Proof of key*).
- The site's summary is free text; the wallet shows it beside its own
  reading of the PSET and asks the user to compare — it cannot reconcile the
  two arithmetically.
- No in-wallet lending screens, no wallet-side broadcast, no mainnet.
- Forgetting a connected site is local bookkeeping: the protocol has no
  revocation, so the site keeps the watch-only descriptor until the user
  removes the wallet there.
- The signing history is this device's alone — it is not a ledger of your
  loans, which live on the site and on the chain.
