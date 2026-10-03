# Changelog

All notable changes to Templar Wallet. Versions follow
[Semantic Versioning](https://semver.org); while the version starts with 0,
any release may change anything.

## [Unreleased]

### Templar Protocol

- **Loans**, a destination beside the Dashboard (a carousel tab on a phone):
  the wallet's loans as the connected site reports them through the v1.1
  portfolio read (`GET /connector/portfolio`) — role, state, the site's next
  step, the term as a time bar with the due estimate, owed / principal /
  collateral / interest / Templar fee — plus the wallet's own offers and the
  closed loans under an expander. **Sign now** opens a pending signing
  request in the app itself; **Refresh** asks the site again, and the page
  refreshes by itself after every signature answered for that site. A revoked
  token (`401`) is dropped and the page says «Reconnect to see your loans»;
  rate limits and a site that is offline keep the last answer on screen with
  the reason.
- **Open on Templar Protocol**, from a loan card or the Loans header: the
  wallet asks the site for a one-time link (`POST /connector/open`) and
  opens it in the browser, which lands on the loan already signed in as
  this wallet. The token stays in the request header; the link is single
  use and expires in two minutes; an expired token or an offline site is
  explained in words.
- The connect answer's `portfolio` object (URL + bearer token) is kept with
  the connected site; sites connected by 0.1.0 have none and say so.
  «Forget» on a site with a token also revokes it on the site
  (`DELETE /connector/portfolio`).
- Loans is **opt-in in the navigation**: off by default, switched on from
  Settings › Templar Protocol («Show Loans in the menu») or with the small
  checkbox a `templar://connect` offers; the page stays reachable from
  Settings and the dashboard either way. Settings › Templar Protocol leads
  with the Loans shortcut and that switch; «How it works» is folded under
  an expander. The desktop dashboard's Liquid panel row now opens Loans.
- The Loans page opens with four stat tiles (active, to sign, offers,
  closed); each loan card carries a role glyph, a term ring and a flow strip
  (collateral → escrow, principal → borrower, repayment → lender) beside the
  time bar and the amounts.
- **The signing request screen is rebuilt** for every action: a header with
  the action's glyph, loan and role; «What changes for this wallet» — the net
  change per asset the engine computed from its own unblinding, green in and
  amber out; «Where the money goes» — every output as a flow with a glyph for
  its destination (this wallet, the loan escrow, someone else, the fee); the
  site's own lines to compare; and the raw inputs/outputs, request ids and
  escrow contract under a «Technical details» fold. Connect shows the share
  as a picture (what leaves, what never does). The engine's `inspect_pset`
  gains `net_change_lines` (ticker and formatted amount per asset).
- **The wallet is always asked for.** A request from a site no longer picks
  the open or preferred wallet by itself: the chooser leads with the wallet
  this device connected to that site («Connected to this site»), then the
  preferred and the open one, lists the rest with the reason they cannot
  take part, and the review offers «Change wallet». Fixes signing with two
  sites, each knowing a different wallet, from one machine.
- **Proof of key** (contract §9). A v1.1 connect carries a `challenge`; the
  wallet builds the check PSET from it and its loan key (one input on
  `sha256("templar-proof" ‖ challenge)`, an explicit 0 L-BTC coin to the
  key at `/0/0`, `OP_RETURN(challenge)`, fee 0 — it can never be broadcast),
  signs it with the escrow key and sends it as `proof`, so reconnecting the
  same wallet re-attaches its loans in one step and gets the portfolio token
  back. A `templar://sign` request with action `proof` gets a dedicated
  review: the challenge line verbatim, the site origin, the expiry and «This
  signature never moves funds»; the engine recomputes the check and the
  screen refuses anything that is not byte-for-byte that check for this
  wallet's key. New FFI ops `protocol_check_pset` and
  `protocol_is_check_pset`; templar-core gains `check_pset`,
  `check_pset_shape` / `is_check_pset` and `verify_check_signature`.
- A Jade-backed wallet can now connect: its BIP87 account
  (`[fp/87h/1h/0h]tpub…`) is offered as the loan key, which the site
  accepts. Proving the key through a Jade is not supported yet (the check
  needs a zero-value input untested on the device); every proof route says
  so and the site falls back to a signing request.

## [0.1.0] — 2026-09-24

The first public release. Testnet only: Bitcoin testnet and Liquid testnet,
plus a local Liquid regtest for development. Mainnet is refused by design.

### Wallets

- Software single-sig (BIP84) with Bitcoin and, optionally, Liquid from the
  same recovery phrase.
- Multisig on Bitcoin (P2WSH, BIP48 keys) and Liquid (BIP87 keys, shared
  blinding key), created in a guided wizard; keys from this device, other
  devices, hardware wallets or QR.
- Miniscript policy wallets from templates or a policy builder: timelocks,
  hashlocks, thresholds, AND/OR.
- Watch-only wallets from descriptors, hardware wallets (Ledger and Jade over
  USB, Trezor / Coldcard / KeepKey / BitBox through HWI on Windows and Linux)
  and air-gapped signing over animated QR (BC-UR).

### Security

- Recovery phrases are sealed in a vault (Argon2id + XChaCha20-Poly1305)
  behind an app password; nothing secret is written in the clear.
- Touch ID on macOS and fingerprint unlock on Android; auto-lock after a
  chosen idle time; the password (or Touch ID) is asked again before a send
  is signed and before the recovery phrase is shown.
- Co-signing refuses a transaction whose amounts it cannot prove: Bitcoin
  inputs without consistent previous outputs, Liquid outputs whose blinded
  amounts do not open.
- Fee rates are held to 0.1–1000 sat/vB, absurd fees are refused, every
  Bitcoin transaction signals RBF.

### Coin control

- The UTXO screen shows every coin as a banknote or a row, sized by its share
  of the asset's holdings, with labels, details and a link to the explorer.
- **Freeze coins**: select them and press Freeze, or use the button in a
  coin's details. A frozen coin stays in the balance, but the engine never
  spends it — automatic selection and MAX leave it out, the send wizard's
  picker shows it locked, consolidation skips it, and a PSBT or PSET that
  would spend it (even one built by a co-signer or a protocol site) is
  refused before signing. On Liquid, a payment that moves an asset other
  than L-BTC cannot leave coins out yet, so it is refused with the reason
  instead. Unfreeze the same way.
- Consolidation of Bitcoin coins, reviewed and signed like any other
  transaction; incoming coins show as pending until they confirm.

### Everything else

- Guided send (several recipients, MAX, fee presets, manual inputs) and
  receive with BIP21 payment requests; activity and a portfolio chart.
- PSBT / PSET co-signing: import by paste, file or camera, inspect what the
  transaction does, sign, merge co-signers' copies, broadcast.
- Liquid assets: issuance, reissuance and burn on testnet; LiquiDEX swaps;
  peg-in / peg-out against a simulated provider.
- Templar Protocol connector: `templar://` links let a Templar Protocol site
  ask this wallet to connect or sign a loan transaction, which the wallet
  shows next to its own reading of it and signs only after you confirm.
- macOS, Windows (installer and portable zip), Linux and Android builds,
  published by CI with fixed download links.
