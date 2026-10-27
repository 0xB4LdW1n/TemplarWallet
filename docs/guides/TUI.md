# Templar terminal client

> [!WARNING]
> Templar Wallet is alpha software for Bitcoin testnet, Liquid testnet, and
> local Liquid regtest only. Never enter a recovery phrase that controls
> mainnet funds.

The `templar` binary provides a read-only interactive TUI and a command-line
gateway to every `templarlib` wallet operation.

## Install

Install Rust stable from <https://rustup.rs>. Platform build requirements:

- macOS: Xcode command-line tools (`xcode-select --install`).
- Linux: a C toolchain, `pkg-config`, and `libudev-dev`.
- Windows: Visual Studio Build Tools with the Desktop development with C++ workload.

Clone the repository and install the binary:

```bash
git clone https://github.com/0xMrtnz/TemplarWallet.git
cd TemplarWallet
cargo install --locked --path crates/templar-tui
templar --version
templar --help
```

Cargo installs `templar` under its binary directory, normally
`~/.cargo/bin`. Ensure that directory is on `PATH`.

Update an existing installation:

```bash
git pull --ff-only
cargo install --locked --force --path crates/templar-tui
```

For development without installation, replace `templar` below with:

```bash
cargo run -p templar-tui --
```

## Help and interactive TUI

```bash
templar --help
templar methods
templar call --help
templar
```

The interactive TUI shows engine state and registered wallets. Use:

- `q`: quit.
- `r`: refresh.
- `?`: show or hide help.
- `Up`/`Down` or `k`/`j`: select a wallet.

The interactive screen is currently read-only. Use explicit commands for
changes. `templar methods` lists all supported engine methods.

## Wallet storage

Without `--data-dir`, the terminal client uses the same saved Templar Wallet
configuration and data directory as Flutter. Close Flutter before starting the
terminal client. A single-instance lock rejects two processes using the same
wallet data.

Use an isolated directory for testing or an enterprise profile:

```bash
export TEMPLAR_WALLET_DIR="$PWD/templar-data"
templar --data-dir "$TEMPLAR_WALLET_DIR" status
```

Repeat `--data-dir` on every command for that profile. The directory contains
the encrypted registry, vault metadata, local chain databases, asset metadata,
and configuration.

Close every Templar process before copying this directory. A directory backup
does not replace recovery-phrase backups. Store recovery phrases offline and
never put them in scripts, shell history, cloud notes, or issue reports.

## Create or open the vault

New seed wallets require an encrypted vault. Set it up once:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" call setup_vault --params -
```

Enter one JSON object, then press `Ctrl-D` on macOS/Linux or `Ctrl-Z`, `Enter`
on Windows:

```json
{"passphrase":"use-a-long-unique-password"}
```

Future processes start locked. Add `--unlock` to commands that need wallet
secrets. The password prompt hides input and does not place it in shell history:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" --unlock status
templar --data-dir "$TEMPLAR_WALLET_DIR" --unlock
```

If Flutter already configured the vault in the same data directory, skip
`setup_vault` and use its existing password.

Check vault state without unlocking:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" call vault_status
```

## Create or restore a software wallet

Generate a 12- or 24-word testnet recovery phrase:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" call generate_mnemonic \
  --params '{"word_count":24}'
```

Write the phrase down offline. Creating and restoring use the same command.
Terminal output contains the phrase, so protect its scrollback. Read secret
JSON from standard input when creating the wallet:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" --unlock \
  call create_wallet --params -
```

Then enter:

```json
{"name":"Treasury","mnemonic":"word1 word2 ... word24","liquid":true}
```

Set `liquid` to `false` for Bitcoin-only storage. The response contains the
wallet ID used by later commands.

List stored wallets:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" --unlock wallets
```

## Use a wallet

Replace `WALLET_ID` with the ID returned by `create_wallet` or `wallets`.

Sync Bitcoin and Liquid:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" --unlock \
  call sync_wallet --params '{"wallet_id":"WALLET_ID"}'
```

Show balances and recent activity:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" --unlock \
  call get_wallet_summary --params '{"wallet_id":"WALLET_ID"}'

templar --data-dir "$TEMPLAR_WALLET_DIR" --unlock \
  call list_activity --params '{"wallet_id":"WALLET_ID"}'
```

Get the current Bitcoin receive address:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" --unlock \
  call generate_receive_address \
  --params '{"wallet_id":"WALLET_ID","asset":"BTC","fresh":false}'
```

Set `fresh` to `true` to advance to a new Bitcoin address. For a Liquid receive
address, use `"asset":"LBTC"`; Liquid confidential addresses stay stable and
ignore `fresh`.

List coins:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" --unlock \
  call list_utxos --params '{"wallet_id":"WALLET_ID","chain":"BTC"}'
```

Freeze a coin so transaction builders and signers cannot spend it:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" --unlock \
  call set_utxos_frozen \
  --params '{"wallet_id":"WALLET_ID","chain":"BTC","outpoints":["TXID:VOUT"],"frozen":true}'
```

Use `false` to unfreeze it.

## Preview and send

Always preview before sending. This example sends Bitcoin testnet sats at
2 sat/vB:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" --unlock \
  call preview_transaction \
  --params '{"wallet_id":"WALLET_ID","address":"TESTNET_ADDRESS","amount_sats":10000,"asset_id":"BTC","fee_rate":2.0}'
```

Inspect recipients, inputs, change, and fee. Then submit the same intent:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" --unlock \
  call send_transaction \
  --params '{"wallet_id":"WALLET_ID","address":"TESTNET_ADDRESS","amount_sats":10000,"asset_id":"BTC","fee_rate":2.0}'
```

`send_transaction` builds, signs, and broadcasts. For hardware, multisig, or
air-gapped flows, use the PSBT/PSET methods shown by `templar methods`. Never
bypass `inspect_psbt` or `inspect_pset` before signing imported transactions.

## Configure a wallet profile

Rename a wallet:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" --unlock \
  call rename_wallet \
  --params '{"wallet_id":"WALLET_ID","new_name":"Operations"}'
```

Enable Liquid for an existing software wallet:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" --unlock \
  call enable_liquid --params '{"wallet_id":"WALLET_ID"}'
```

Show current Liquid configuration:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" call get_liquid_network
```

Select Liquid testnet:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" \
  call set_liquid_network --params '{"network":"testnet"}'
```

Select local regtest with its policy asset:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" \
  call set_liquid_network \
  --params '{"network":"regtest","policy_asset":"64_HEX_CHAR_ASSET_ID"}'
```

Network environment overrides include:

- `TEMPLAR_ELECTRUM_URL`
- `TEMPLAR_LIQUID_ELECTRUM_URL`
- `TEMPLAR_LIQUID_NETWORK=testnet|regtest`
- `TEMPLAR_LIQUID_BACKEND=electrum|elements_rpc`
- `TEMPLAR_ELEMENTS_RPC_URL`, `TEMPLAR_ELEMENTS_RPC_USER`, and
  `TEMPLAR_ELEMENTS_RPC_PASS`
- `TEMPLAR_HWI_BIN`

See [`../../CLAUDE.md`](../../CLAUDE.md#env-overrides) for complete defaults.

## Delete a wallet

Deletion removes the registry entry and the Bitcoin cache when it is not
shared. Harmless Liquid cache data may remain. Confirm the offline recovery
phrase first:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" --unlock \
  call verify_backup --params -
```

Enter the wallet ID and phrase through standard input. Then delete explicitly:

```bash
templar --data-dir "$TEMPLAR_WALLET_DIR" --unlock \
  call delete_wallet --params '{"wallet_id":"WALLET_ID"}'
```

Deletion cannot erase chain history or recover a missing phrase. It only
removes local Templar data.

## Troubleshooting

- `Another Templar Wallet instance...`: close Flutter or the other TUI.
- Empty wallet list: use the same `--data-dir`, then add `--unlock`.
- `unknown method`: run `templar methods` and check spelling.
- Hardware unavailable: run `templar call hwi_status` and review the hardware
  guides in this directory.
- Network sync failure: inspect the per-chain result from `sync_wallet` and
  verify endpoint overrides.
