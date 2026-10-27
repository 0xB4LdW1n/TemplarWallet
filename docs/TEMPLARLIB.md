# templarlib and terminal client

`templarlib` is the reusable application layer of Templar Wallet. It has no
Flutter or C ABI dependency. Flutter, terminal clients, and enterprise hosts
all call the same engine and receive the same JSON responses.

## Boundaries

| Package | Owns |
|---|---|
| `templar-core` | Bitcoin, Liquid, Miniscript, signing, vault, registry, and chain primitives |
| `templarlib` | Process state, application workflows, DTOs, dispatch, and single-instance data locking |
| `wallet-ffi` | C strings, panic containment, response zeroization, and exported ABI symbols |
| `templar-tui` | CLI parsing, terminal rendering, and operator help |
| Flutter app | Screens, navigation, themes, platform integration, and user interaction |

`wallet-ffi` and `templar-tui` must not duplicate wallet workflows. New
workflows belong in `templarlib` or `templar-core`, depending on whether they
need application state.

## Rust use

```rust
use serde_json::json;
use templarlib::TemplarLib;

let engine = TemplarLib::with_data_dir("./wallet-data");
let response = engine.call("vault_status", &json!({}));
println!("{response}");
```

Every response uses one stable envelope:

```json
{"ok": {}}
```

or:

```json
{"err": "human-readable error"}
```

`TemplarLib::methods()` returns every accepted method name. DTOs intended for
host adapters are available under `templarlib::types`.

## Terminal use

Full installation, storage, vault, wallet, receive, send, and configuration
instructions: [`guides/TUI.md`](guides/TUI.md).

```bash
cargo run -p templar-tui -- --help
cargo run -p templar-tui -- methods
cargo run -p templar-tui -- status
cargo run -p templar-tui -- wallets
cargo run -p templar-tui -- --unlock
cargo run -p templar-tui
```

Call any engine method:

```bash
cargo run -p templar-tui -- call vault_status
cargo run -p templar-tui -- call open_wallet --params '{"wallet_id":"..."}'
```

Do not put passwords, mnemonics, private keys, or vault keys in command-line
arguments. They can remain in shell history and process listings. Read secret
JSON from standard input instead:

```bash
cargo run -p templar-tui -- call unlock_vault --params -
```

The Flutter app and terminal client cannot open the same data directory at the
same time. The existing single-instance lock rejects the second process.

## Current TUI scope

The interactive TUI is intentionally read-only in this first slice. It shows
engine status and registered wallets. Mutating operations remain available
through the explicit `call` command and use the same validation as Flutter.

Next terminal work should add guided commands around existing methods. It must
not bypass transaction previews, frozen-input checks, or signing inspection.
