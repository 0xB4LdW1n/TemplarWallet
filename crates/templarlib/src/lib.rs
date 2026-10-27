//! Reusable Templar Wallet application engine.
//!
//! `templar-core` owns chain and wallet primitives. `templarlib` adds the
//! stateful application workflows shared by Flutter, terminal clients, and
//! future enterprise integrations.

mod dispatch;
mod handlers;
mod state;
pub mod types;

#[cfg(test)]
mod contract_tests;

use std::path::PathBuf;
use std::sync::Mutex;

use serde_json::Value;
use state::AppState;

/// Every method accepted by [`TemplarLib::call`].
pub const METHODS: &[&str] = &[
    "version",
    "get_liquid_network",
    "set_liquid_network",
    "vault_status",
    "setup_vault",
    "unlock_vault",
    "unlock_vault_with_key",
    "export_vault_key",
    "lock_vault",
    "verify_vault_passphrase",
    "verify_vault_key",
    "verify_backup",
    "list_wallets",
    "generate_mnemonic",
    "rename_wallet",
    "delete_wallet",
    "enable_liquid",
    "create_wallet",
    "create_multisig_wallet",
    "derive_cosigner_xpub",
    "derive_liquid_cosigner_xpub",
    "get_liquid_cosigner_xpub",
    "get_cosigner_xpub",
    "get_mnemonic",
    "get_private_key",
    "open_wallet",
    "sync_wallet",
    "get_wallet_summary",
    "generate_receive_address",
    "list_previous_addresses",
    "list_activity",
    "get_balance_history",
    "list_utxos",
    "set_utxos_frozen",
    "build_consolidation_psbt",
    "consolidate_utxos",
    "get_wallet_info",
    "preview_transaction",
    "send_transaction",
    "ur_psbt_encode",
    "ur_pset_encode",
    "repair_multisig_wallet",
    "validate_cosigner_key",
    "ur_decode_parts",
    "get_protocol_escrow_xpub",
    "protocol_check_pset",
    "protocol_is_check_pset",
    "inspect_pset",
    "sign_pset",
    "sign_pset_hw",
    "combine_psets",
    "broadcast_pset",
    "inspect_psbt",
    "sign_psbt",
    "combine_psbts",
    "send_transaction_hw",
    "sign_transaction_hw",
    "sign_psbt_hw",
    "build_unsigned_psbt",
    "broadcast_signed_psbt",
    "issue_asset",
    "reissue_asset",
    "burn_asset",
    "reregister_asset",
    "enumerate_hw_devices",
    "enumerate_native_devices",
    "jade_ports",
    "import_jade_liquid_wallet",
    "get_hw_cosigner_xpub",
    "get_jade_liquid_cosigner_xpub",
    "derive_liquid_descriptor",
    "get_data_dir",
    "hwi_status",
    "set_hwi_path",
    "import_hw_wallet",
    "add_liquid_to_wallet",
    "create_watch_only_wallet",
    "verify_hw_address",
    "peg_quote",
    "peg_start",
    "peg_status",
    "peg_list",
    "peg_cancel",
    "list_swaps",
    "swap_verify",
    "swap_take_preview",
    "swap_take",
    "swap_make",
    "swap_make_prepare",
    "list_my_offers",
    "swap_cancel",
];

/// Thread-safe application engine shared by every host adapter.
pub struct TemplarLib {
    state: Mutex<AppState>,
}

impl TemplarLib {
    /// Use the saved application configuration or the platform default.
    pub fn new() -> Self {
        Self {
            state: Mutex::new(AppState::new()),
        }
    }

    /// Keep all wallet data and configuration under `data_dir`.
    pub fn with_data_dir(data_dir: impl Into<PathBuf>) -> Self {
        Self {
            state: Mutex::new(AppState::with_data_dir(data_dir.into())),
        }
    }

    /// Execute one application method and return the stable JSON envelope.
    ///
    /// Responses are `{"ok": value}` or `{"err": "message"}`. The same
    /// contract is consumed by Flutter and the terminal client.
    pub fn call(&self, method: &str, params: &Value) -> Value {
        match self.state.lock() {
            Ok(mut state) => dispatch::dispatch(&mut state, method, params),
            Err(poisoned) => {
                let mut state = poisoned.into_inner();
                dispatch::dispatch(&mut state, method, params)
            }
        }
    }

    /// Supported method names for adapters, diagnostics, and generated help.
    pub fn methods() -> &'static [&'static str] {
        METHODS
    }
}

impl Default for TemplarLib {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod public_api_tests {
    use std::collections::BTreeSet;

    use super::METHODS;

    #[test]
    fn method_catalog_is_unique_and_points_at_dispatch_routes() {
        let unique: BTreeSet<_> = METHODS.iter().copied().collect();
        assert_eq!(unique.len(), METHODS.len());

        let dispatch = include_str!("dispatch.rs");
        for method in METHODS {
            assert!(
                dispatch.contains(&format!("\"{method}\"")),
                "{method} is missing from dispatch"
            );
        }
    }
}
