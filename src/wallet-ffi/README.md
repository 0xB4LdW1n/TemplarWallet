# wallet-ffi

Thin C ABI adapter between the Flutter app and `templarlib`.

It exports `wallet_call`, `wallet_free_string`, and `wallet_set_data_dir`.
Wallet state, DTOs, dispatch, and workflows belong to `templarlib`; this crate
only owns C-string conversion, panic containment, and response zeroization.

Build it with:

```bash
cargo build -p wallet-ffi
```
