//! Templar Protocol connector helpers — the wallet side of
//! `docs/connector-protocol.md` in the Templar Protocol repository.
//!
//! A loan escrow is a per-loan CT descriptor
//!
//! ```text
//! ct(slip77(<view key>),
//!    elwsh(or_d(multi(2, <B>/<0;1>/*, <L>/<0;1>/*),
//!               and_v(v:pk(<L>/<0;1>/*), after(<term_height>)))))
//! ```
//!
//! where `<B>` / `<L>` are the borrower's and lender's **escrow account
//! keys** in keyorigin form `[fingerprint/2121h/1h/0h]tpub…` — a hardened
//! account below the BIP39 master key that never collides with the wallet's
//! spending keys (`84'/1'/0'`) or BIP87 multisig keys (`87'/1'/0'`).
//!
//! Signing needs no descriptor import: the PSET input carries the
//! `witness_script` and `bip32_derivation` entries
//! `[fingerprint/2121h/1h/0h/0/i]`, and `SwSigner::sign` matches on the
//! fingerprint — which is exactly what [`crate::LiquidWalletManager::sign`]
//! already does for multisig co-signing.

use std::str::FromStr;

use lwk_common::Signer;
use lwk_signer::SwSigner;
use lwk_wollet::bitcoin::bip32::{ChildNumber, DerivationPath, Fingerprint};
use lwk_wollet::bitcoin::PublicKey;
use lwk_wollet::elements::hashes::{sha256, Hash};
use lwk_wollet::elements::pset::{Input, Output, PartiallySignedTransaction, PsbtSighashType};
use lwk_wollet::elements::secp256k1_zkp::{ecdsa::Signature, Message};
use lwk_wollet::elements::sighash::SighashCache;
use lwk_wollet::elements::{
    confidential, EcdsaSighashType, OutPoint, PubkeyHash, Script, Sequence, TxOut, TxOutWitness,
    Txid, WPubkeyHash,
};
use lwk_wollet::elements_miniscript::DescriptorPublicKey;
use lwk_wollet::EC;

use crate::error::{LiquidError, TemplarError};
use crate::liquid::network::LiquidNetwork;

/// Hardened derivation path (below the master key) of the escrow account a
/// wallet contributes to Templar Protocol loan contracts: `m/2121'/1'/0'`
/// (2121' = Templar Protocol escrow purpose, 1' = test networks).
pub const ESCROW_KEY_PATH: &str = "2121h/1h/0h";

/// Derives the wallet's escrow account key in keyorigin form
/// (`[fingerprint/2121h/1h/0h]tpub…`), the value the connect callback
/// carries as `escrow_xpub`.
pub fn escrow_account_xpub(signer: &SwSigner) -> Result<String, TemplarError> {
    let path: DerivationPath = format!("m/{ESCROW_KEY_PATH}")
        .replace('h', "'")
        .parse()
        .map_err(|e| LiquidError::InvalidDescriptor(format!("escrow path: {e}")))?;
    let xpub = Signer::derive_xpub(signer, &path)
        .map_err(|e| LiquidError::InvalidDescriptor(format!("derive escrow xpub: {e}")))?;
    Ok(format!(
        "[{}/{}]{}",
        signer.fingerprint(),
        ESCROW_KEY_PATH,
        xpub
    ))
}

/// [`escrow_account_xpub`] straight from a BIP39 mnemonic (the registry
/// stores the phrase, not a signer).
pub fn escrow_xpub_from_mnemonic(mnemonic: &str) -> Result<String, TemplarError> {
    let signer = SwSigner::new(mnemonic, false)
        .map_err(|e| LiquidError::InvalidDescriptor(format!("SwSigner: {e}")))?;
    escrow_account_xpub(&signer)
}

// ── Proof of key: the check PSET (connector-protocol.md §9) ──────────────────
//
// A site identifies a wallet by its loan key — the `2121h` escrow account,
// or a Jade's `87h` BIP87 account — and lets it back in by a signature on a
// transaction that can never be broadcast: one input whose prevout is
// `sha256("templar-proof" ‖ challenge)`, a hash no transaction has, carrying
// an explicit 0 L-BTC `witness_utxo` to P2WPKH(loan key `/0/0`); one
// `OP_RETURN(challenge)` output; a fee output of 0. The sighash commits to
// the prevout and hence to the challenge (origin · nonce · expiry), so one
// proof is good for one site and one challenge. The wallet both builds it
// (v1.1 connect, §9.3) and recognises it (a `templar://sign` request with
// action `proof`, §9.2 / §9.5): nothing under that action is signed unless
// it is byte-for-byte the check of the request's own challenge and this
// wallet's own key.

/// Tag in front of the challenge bytes when the fake prevout is hashed.
pub const PROOF_PREVOUT_TAG: &[u8] = b"templar-proof";

/// The BIP87 account a Jade exports (`keyorigin_xpub(Bip87)`), accepted by the
/// site as a loan key beside [`ESCROW_KEY_PATH`].
pub const LOAN_KEY_PATH_BIP87: &str = "87h/1h/0h";

/// `sha256(PROOF_PREVOUT_TAG ‖ challenge)` as a txid: the prevout of the one
/// input. A real txid is a double SHA-256 of a serialized transaction; this
/// is a single, tagged SHA-256 of text, so no chain holds it and the check
/// can never spend anything.
pub fn proof_fake_txid(challenge: &str) -> Txid {
    let mut data = Vec::with_capacity(PROOF_PREVOUT_TAG.len() + challenge.len());
    data.extend_from_slice(PROOF_PREVOUT_TAG);
    data.extend_from_slice(challenge.as_bytes());
    Txid::from_byte_array(sha256::Hash::hash(&data).to_byte_array())
}

/// The key a check is signed with: `K/0/0` of the loan account `K` given in
/// keyorigin form (`[fp/2121h/1h/0h]tpub…` or `[fp/87h/1h/0h]tpub…`), with
/// the master fingerprint and the full path the PSET's `bip32_derivation`
/// names. A key without origin, with a wildcard or with a path already
/// appended is refused: the site only knows the bare account.
pub fn loan_key_at_zero(
    account_xpub_with_origin: &str,
) -> Result<(PublicKey, Fingerprint, DerivationPath), TemplarError> {
    let bad = |why: String| {
        TemplarError::from(LiquidError::InvalidDescriptor(format!("loan key: {why}")))
    };
    let key = DescriptorPublicKey::from_str(account_xpub_with_origin.trim())
        .map_err(|e| bad(e.to_string()))?;
    let DescriptorPublicKey::XPub(xkey) = key else {
        return Err(bad("not an extended key".into()));
    };
    if !xkey.derivation_path.is_empty()
        || xkey.wildcard != lwk_wollet::elements_miniscript::descriptor::Wildcard::None
    {
        return Err(bad(
            "an account key carries no derivation after the xpub".into()
        ));
    }
    let (fingerprint, origin_path) = xkey
        .origin
        .ok_or_else(|| bad("missing keyorigin ([fingerprint/path])".into()))?;
    if origin_path.is_empty() {
        return Err(bad("empty keyorigin path".into()));
    }
    let zero = ChildNumber::from_normal_idx(0).expect("0 is a valid index");
    let leaf = [zero, zero];
    let derived = xkey
        .xkey
        .derive_pub(&EC, &leaf)
        .map_err(|e| bad(format!("derive /0/0: {e}")))?;
    Ok((
        PublicKey::new(derived.public_key),
        fingerprint,
        origin_path.extend(leaf),
    ))
}

fn p2wpkh(pk: &PublicKey) -> Script {
    Script::new_v0_wpkh(&WPubkeyHash::hash(&pk.to_bytes()))
}

/// BIP-143 script code of a P2WPKH input: the P2PKH script of its key.
fn p2wpkh_script_code(pk: &PublicKey) -> Script {
    Script::new_p2pkh(&PubkeyHash::hash(&pk.to_bytes()))
}

/// Builds the check PSET of §9.1 for `challenge` and the loan key
/// `account_xpub_with_origin`, deterministically: PSET v2, one input on
/// [`proof_fake_txid`] (sequence `0xffffffff`, explicit 0 of `network`'s
/// policy asset to P2WPKH(`K/0/0`), `bip32_derivation` for that key,
/// `SIGHASH_ALL`), output 0 = `OP_RETURN(challenge)` explicit 0, output 1 =
/// fee 0, locktime 0. The network decides the policy asset, which the
/// shape commits to — a check for testnet is not a check for regtest.
pub fn check_pset(
    challenge: &str,
    account_xpub_with_origin: &str,
    network: &LiquidNetwork,
) -> Result<PartiallySignedTransaction, TemplarError> {
    if challenge.trim().is_empty() {
        return Err(LiquidError::PsetBuildFailed("check PSET: empty challenge".into()).into());
    }
    let (pk, fingerprint, path) = loan_key_at_zero(account_xpub_with_origin)?;
    let policy_asset = network.policy_asset();
    let mut input = Input::from_prevout(OutPoint::new(proof_fake_txid(challenge), 0));
    input.sequence = Some(Sequence::MAX);
    input.witness_utxo = Some(TxOut {
        asset: confidential::Asset::Explicit(policy_asset),
        value: confidential::Value::Explicit(0),
        nonce: confidential::Nonce::Null,
        script_pubkey: p2wpkh(&pk),
        witness: TxOutWitness::default(),
    });
    input.bip32_derivation.insert(pk, (fingerprint, path));
    input.sighash_type = Some(PsbtSighashType::from(EcdsaSighashType::All));
    let mut pset = PartiallySignedTransaction::new_v2();
    pset.add_input(input);
    pset.add_output(Output::new_explicit(
        Script::new_op_return(challenge.as_bytes()),
        0,
        policy_asset,
        None,
    ));
    pset.add_output(Output::from_txout(TxOut::new_fee(0, policy_asset)));
    Ok(pset)
}

/// Why `pset` is not the check PSET of `challenge` for `our_xpub` on
/// `network` (§9.5) — or `Ok(())` when it is exactly that, signed or not.
///
/// The expected check is rebuilt from the challenge and the key and compared
/// on the unsigned transaction (prevout, sequence, both outputs, locktime)
/// and on the input's coin (asset, value 0, script), so a real-looking
/// prevout, a coin worth anything, another challenge, another key, an extra
/// input or output, or another chain's policy asset all name their reason.
pub fn check_pset_shape(
    pset: &PartiallySignedTransaction,
    challenge: &str,
    our_xpub: &str,
    network: &LiquidNetwork,
) -> Result<(), TemplarError> {
    let shape = |why: &str| {
        TemplarError::from(LiquidError::PsetInspectionFailed(format!(
            "not a check PSET: {why}"
        )))
    };
    let expected = check_pset(challenge, our_xpub, network)?;
    if pset.inputs().len() != 1 {
        return Err(shape(&format!(
            "expected one input, found {}",
            pset.inputs().len()
        )));
    }
    if pset.outputs().len() != 2 {
        return Err(shape(&format!(
            "expected two outputs (the challenge and a zero fee), found {}",
            pset.outputs().len()
        )));
    }
    let input = &pset.inputs()[0];
    let want = &expected.inputs()[0];
    let Some(utxo) = &input.witness_utxo else {
        return Err(shape("the input has no witness_utxo"));
    };
    if utxo.value != confidential::Value::Explicit(0) {
        return Err(shape(
            "the input is a coin worth something, not the zero-value check",
        ));
    }
    if utxo.asset != confidential::Asset::Explicit(network.policy_asset()) {
        return Err(shape(&format!(
            "the input's asset is not {}'s L-BTC",
            network.name()
        )));
    }
    if utxo.script_pubkey != want.witness_utxo.as_ref().expect("built").script_pubkey {
        return Err(shape("the input does not belong to this wallet's loan key"));
    }
    if input.previous_txid != want.previous_txid || input.previous_output_index != 0 {
        return Err(shape(
            "the input spends a real-looking outpoint, not the challenge hash",
        ));
    }
    let got_tx = pset
        .extract_tx()
        .map_err(|e| shape(&format!("unreadable transaction: {e}")))?;
    let want_tx = expected.extract_tx().expect("the built check extracts");
    if got_tx.txid() != want_tx.txid() {
        // Same prevout, same coin, yet a different transaction: an output,
        // the sequence or the locktime was changed.
        if !got_tx.output[0].script_pubkey.is_op_return()
            || got_tx.output[0].script_pubkey != want_tx.output[0].script_pubkey
        {
            return Err(shape(
                "output 0 is not OP_RETURN of this request's challenge",
            ));
        }
        if got_tx.output[0].value != confidential::Value::Explicit(0) {
            return Err(shape("the challenge output carries a value"));
        }
        if !got_tx.output[1].is_fee() || got_tx.output[1].value != confidential::Value::Explicit(0)
        {
            return Err(shape("the fee is not zero"));
        }
        return Err(shape(
            "the transaction differs from the check (sequence, locktime or an output field)",
        ));
    }
    Ok(())
}

/// [`check_pset_shape`] as a yes/no.
pub fn is_check_pset(
    pset: &PartiallySignedTransaction,
    challenge: &str,
    our_xpub: &str,
    network: &LiquidNetwork,
) -> bool {
    check_pset_shape(pset, challenge, our_xpub, network).is_ok()
}

/// §9.4 steps 1–2, the site's verification, kept here so the wallet's
/// tests prove what a site will accept: the shape, then `partial_sigs[K/0/0]`
/// as a low-S DER signature with `SIGHASH_ALL` over the segwit v0 sighash
/// recomputed from the rebuilt check.
pub fn verify_check_signature(
    pset: &PartiallySignedTransaction,
    challenge: &str,
    xpub: &str,
    network: &LiquidNetwork,
) -> Result<(), TemplarError> {
    check_pset_shape(pset, challenge, xpub, network)?;
    let sig_err = |why: String| {
        TemplarError::from(LiquidError::SigningFailed(format!(
            "check signature: {why}"
        )))
    };
    let (pk, _, _) = loan_key_at_zero(xpub)?;
    let raw = pset.inputs()[0]
        .partial_sigs
        .get(&pk)
        .ok_or_else(|| sig_err("no signature from the loan key".into()))?;
    let (hash_ty, der) = raw
        .split_last()
        .ok_or_else(|| sig_err("empty signature".into()))?;
    if *hash_ty != 0x01 {
        return Err(sig_err("sighash type is not SIGHASH_ALL".into()));
    }
    let sig = Signature::from_der(der).map_err(|e| sig_err(format!("DER: {e}")))?;
    let mut low_s = sig;
    low_s.normalize_s();
    if low_s != sig {
        return Err(sig_err("high-S signature".into()));
    }
    let tx = check_pset(challenge, xpub, network)?
        .extract_tx()
        .expect("the built check extracts");
    let mut cache = SighashCache::new(&tx);
    let sighash = cache.segwitv0_sighash(
        0,
        &p2wpkh_script_code(&pk),
        confidential::Value::Explicit(0),
        EcdsaSighashType::All,
    );
    let msg = Message::from_digest(sighash.to_byte_array());
    EC.verify_ecdsa(&msg, &sig, &pk.inner)
        .map_err(|_| sig_err("the signature does not verify for the loan key".into()))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use lwk_wollet::elements::confidential::{Asset, Nonce, Value};
    use lwk_wollet::elements::pset::{Input, Output, PartiallySignedTransaction};
    use lwk_wollet::elements::{OutPoint, Script, TxOut, Txid};
    use lwk_wollet::elements_miniscript::psbt::PsbtExt;
    use lwk_wollet::{Chain, WolletDescriptor};
    use std::str::FromStr;

    use crate::liquid::network::LiquidNetwork;
    use crate::liquid::wallet::LiquidWalletManager;

    /// BIP39 test vector, fingerprint 73c5da0a.
    pub(crate) const MNEMONIC_BORROWER: &str =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    pub(crate) const MNEMONIC_LENDER: &str = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong";
    /// Any 32-byte hex works as the shared SLIP-77 view key of the escrow;
    /// Templar Protocol derives it from the loan commitment hash.
    const VIEW_KEY: &str = "1111111111111111111111111111111111111111111111111111111111111111";
    const TERM_HEIGHT: u32 = 1_700_000;
    /// Per-loan derivation index (Templar Protocol: first byte of the commitment).
    pub(crate) const LOAN_INDEX: u32 = 7;

    /// The §2 contract for the two test mnemonics.
    pub(crate) fn escrow_descriptor() -> String {
        let b = escrow_xpub_from_mnemonic(MNEMONIC_BORROWER).unwrap();
        let l = escrow_xpub_from_mnemonic(MNEMONIC_LENDER).unwrap();
        format!(
            "ct(slip77({VIEW_KEY}),elwsh(or_d(multi(2,{b}/<0;1>/*,{l}/<0;1>/*),and_v(v:pk({l}/<0;1>/*),after({TERM_HEIGHT})))))"
        )
    }

    /// A PSET that spends a fake (explicit, unblinded) escrow deposit at
    /// `LOAN_INDEX`, exactly as the protocol's settlement code builds it: the
    /// escrow input carries `witness_utxo`, `witness_script` and the
    /// `[fp/2121h/1h/0h/0/i]` `bip32_derivation` entries of both keys. One
    /// explicit payout to `payout_script` plus the fee output.
    pub(crate) fn escrow_spend_pset(
        network: &LiquidNetwork,
        payout_script: Script,
        value: u64,
        payout: u64,
    ) -> PartiallySignedTransaction {
        let wd: WolletDescriptor = escrow_descriptor().parse().expect("LWK parses §2");
        let definite = wd.definite_descriptor(Chain::External, LOAN_INDEX).unwrap();
        let spk = wd.script_pubkey(Chain::External, LOAN_INDEX).unwrap();
        let lbtc = network.policy_asset();

        let txout = TxOut {
            asset: Asset::Explicit(lbtc),
            value: Value::Explicit(value),
            nonce: Nonce::Null,
            script_pubkey: spk,
            witness: Default::default(),
        };
        let txid =
            Txid::from_str("2222222222222222222222222222222222222222222222222222222222222222")
                .unwrap();
        let mut input = Input::from_prevout(OutPoint::new(txid, 0));
        input.witness_utxo = Some(txout);
        input.asset = Some(lbtc);
        input.amount = Some(value);

        let mut pset = PartiallySignedTransaction::new_v2();
        pset.add_input(input);
        pset.update_input_with_descriptor(0, &definite)
            .expect("witness_script + bip32_derivation");
        pset.add_output(Output::new_explicit(payout_script, payout, lbtc, None));
        pset.add_output(Output::new_explicit(
            Script::default(),
            value - payout,
            lbtc,
            None,
        ));
        pset
    }

    /// p2wpkh-shaped script nobody owns.
    pub(crate) fn dummy_payout_script() -> Script {
        Script::from(vec![
            0u8, 20, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        ])
    }

    #[test]
    fn escrow_xpub_has_the_protocol_shape() {
        let x = escrow_xpub_from_mnemonic(MNEMONIC_BORROWER).unwrap();
        assert!(x.starts_with("[73c5da0a/2121h/1h/0h]tpub"), "got {x}");
        // Deterministic, and a different account from the spending keys.
        assert_eq!(x, escrow_xpub_from_mnemonic(MNEMONIC_BORROWER).unwrap());
        let (_, spending) = crate::account_xpub_bip84(MNEMONIC_BORROWER).unwrap();
        assert!(!x.ends_with(&spending));
        assert!(escrow_xpub_from_mnemonic("not a mnemonic").is_err());
    }

    /// The critical check: LWK parses the §2 descriptor, and a plain wallet
    /// signer — knowing nothing about the loan — adds its escrow signature
    /// by fingerprint alone. Once for each party.
    #[test]
    fn both_parties_sign_the_escrow_input_with_their_2121_keys() {
        let network = LiquidNetwork::testnet();
        let mut pset = escrow_spend_pset(&network, dummy_payout_script(), 1_000_000, 999_500);
        let input = &pset.inputs()[0];
        assert!(
            input.witness_script.is_some(),
            "P2WSH input carries its script"
        );
        assert_eq!(input.bip32_derivation.len(), 2, "both escrow keys listed");
        for (fp, path) in input.bip32_derivation.values() {
            let path = path.to_string();
            assert!(
                path.contains("2121'/1'/0'/0/7"),
                "{fp}: {path} is not the escrow account"
            );
        }

        let borrower =
            LiquidWalletManager::from_mnemonic_with_persist_on(&network, MNEMONIC_BORROWER, None)
                .unwrap();
        let lender =
            LiquidWalletManager::from_mnemonic_with_persist_on(&network, MNEMONIC_LENDER, None)
                .unwrap();
        assert_eq!(borrower.sign(&mut pset).unwrap(), 1, "borrower signs once");
        assert_eq!(lender.sign(&mut pset).unwrap(), 1, "lender signs once");
        assert_eq!(pset.inputs()[0].partial_sigs.len(), 2);
        // Signing again adds nothing — the signature is already there.
        assert_eq!(borrower.sign(&mut pset).unwrap(), 0);

        // A stranger's key is not in the script.
        let stranger = LiquidWalletManager::from_mnemonic_with_persist_on(
            &network,
            "letter advice cage absurd amount doctor acoustic avoid letter advice cage above",
            None,
        )
        .unwrap();
        assert_eq!(stranger.sign(&mut pset).unwrap(), 0);
    }

    /// The wallet's own view of an escrow spend, the thing the user sees
    /// next to the site's summary before signing.
    ///
    /// Outputs here are explicit, so none can be the wallet's own: LWK only
    /// accepts a wallet output when it is blinded with proofs (which is how
    /// Templar Protocol builds real ones). Ownership is covered separately below.
    #[test]
    fn inspection_describes_the_escrow_input_and_classifies_outputs() {
        let network = LiquidNetwork::testnet();
        let borrower =
            LiquidWalletManager::from_mnemonic_with_persist_on(&network, MNEMONIC_BORROWER, None)
                .unwrap();
        let mut pset = escrow_spend_pset(&network, dummy_payout_script(), 1_000_000, 999_500);
        // Plus an escrow-shaped output (another loan being funded).
        let escrow_spk = escrow_descriptor()
            .parse::<WolletDescriptor>()
            .unwrap()
            .script_pubkey(Chain::External, 3)
            .unwrap();
        let lbtc = network.policy_asset();
        pset.add_output(Output::new_explicit(escrow_spk, 1, lbtc, None));

        let d = borrower.inspect_pset(&pset).unwrap();
        assert_eq!(d.network, "liquid-testnet");
        assert_eq!(d.inputs.len(), 1);
        let input = &d.inputs[0];
        assert!(input.is_ours, "borrower's 2121' key is in the script");
        assert_eq!(input.script_type, "p2wsh");
        assert!(input.witness_script.is_some());
        assert!(input
            .witness_script_asm
            .as_deref()
            .unwrap()
            .contains("OP_CHECKMULTISIG"));
        assert_eq!(input.amount, Some(1_000_000));
        assert_eq!(input.asset.as_deref(), Some(crate::TESTNET_POLICY_ASSET));
        assert_eq!(input.key_fingerprints.len(), 2);
        assert!(input.key_fingerprints.contains(&"73c5da0a".to_string()));
        assert!(input.signed_by.is_empty());
        assert!(input.outpoint.ends_with(":0"));
        assert_eq!(d.our_inputs().len(), 1);
        assert!(d.touches_escrow());

        let kinds: Vec<&str> = d.outputs.iter().map(|o| o.kind.as_str()).collect();
        assert_eq!(kinds, ["external", "fee", "escrow"], "{:?}", d.outputs);
        assert_eq!(d.outputs[0].script_type, "p2wpkh");
        assert!(d.outputs[0].address.is_some());
        assert_eq!(d.outputs[0].amount, Some(999_500));
        assert_eq!(d.outputs[1].amount, Some(500));
        assert_eq!(d.outputs[2].script_type, "p2wsh");
        assert_eq!(d.outputs[2].amount, Some(1));
        assert!(d.outputs[2].address.as_deref().unwrap().starts_with("tex1"));

        // After the borrower signs, the input reports it.
        borrower.sign(&mut pset).unwrap();
        let d = borrower.inspect_pset(&pset).unwrap();
        assert_eq!(d.inputs[0].signed_by, vec!["73c5da0a".to_string()]);

        // The lender sees the same input as theirs too; a stranger does not.
        let lender =
            LiquidWalletManager::from_mnemonic_with_persist_on(&network, MNEMONIC_LENDER, None)
                .unwrap();
        assert!(lender.inspect_pset(&pset).unwrap().inputs[0].is_ours);
        let stranger = LiquidWalletManager::from_mnemonic_with_persist_on(
            &network,
            "letter advice cage absurd amount doctor acoustic avoid letter advice cage above",
            None,
        )
        .unwrap();
        let s = stranger.inspect_pset(&pset).unwrap();
        assert!(!s.inputs[0].is_ours);
    }

    /// Output ownership follows LWK's rule — the output's key derivation
    /// reproduces one of the wallet's scripts — which is how Templar Protocol marks
    /// the payee's outputs (`add_details`) in origination and settlement.
    #[test]
    fn own_outputs_are_recognised_by_their_derivation() {
        let network = LiquidNetwork::testnet();
        let borrower =
            LiquidWalletManager::from_mnemonic_with_persist_on(&network, MNEMONIC_BORROWER, None)
                .unwrap();
        let own_script = borrower
            .wollet
            .address(Some(5))
            .unwrap()
            .address()
            .script_pubkey();
        let mut pset = escrow_spend_pset(&network, own_script.clone(), 1_000, 500);
        let own_definite = borrower
            .wollet
            .wollet_descriptor()
            .definite_descriptor(Chain::External, 5)
            .unwrap();
        pset.update_output_with_descriptor(0, &own_definite)
            .unwrap();
        let output = &pset.outputs()[0];
        assert!(!output.bip32_derivation.is_empty());
        let known = std::collections::HashSet::new();
        assert!(borrower.script_is_ours(&own_script, &output.bip32_derivation, &known));
        // Same derivation, someone else's script: not ours.
        assert!(!borrower.script_is_ours(&dummy_payout_script(), &output.bip32_derivation, &known));
        // No derivation at all: only a script the wallet already received
        // on counts.
        let empty = Default::default();
        assert!(!borrower.script_is_ours(&own_script, &empty, &known));
        let mut known = std::collections::HashSet::new();
        known.insert(own_script.clone());
        assert!(borrower.script_is_ours(&own_script, &empty, &known));
        // The lender's wallet does not own the borrower's script.
        let lender =
            LiquidWalletManager::from_mnemonic_with_persist_on(&network, MNEMONIC_LENDER, None)
                .unwrap();
        assert!(!lender.script_is_ours(&own_script, &output.bip32_derivation, &Default::default()));
    }

    /// A PSET built for testnet must not be signable by a regtest wallet,
    /// and the other way round — the fee and explicit assets give it away.
    #[test]
    fn inspection_refuses_a_pset_from_another_network() {
        let testnet_pset =
            escrow_spend_pset(&LiquidNetwork::testnet(), dummy_payout_script(), 1_000, 500);
        let regtest_wallet = LiquidWalletManager::from_mnemonic_with_persist_on(
            &LiquidNetwork::regtest_default(),
            MNEMONIC_BORROWER,
            None,
        )
        .unwrap();
        let err = regtest_wallet
            .inspect_pset(&testnet_pset)
            .unwrap_err()
            .to_string();
        assert!(err.contains("Network mismatch"), "{err}");
        assert!(err.contains("liquid-regtest"), "{err}");

        let regtest_pset = escrow_spend_pset(
            &LiquidNetwork::regtest_default(),
            dummy_payout_script(),
            1_000,
            500,
        );
        let testnet_wallet = LiquidWalletManager::from_mnemonic_with_persist_on(
            &LiquidNetwork::testnet(),
            MNEMONIC_BORROWER,
            None,
        )
        .unwrap();
        let err = testnet_wallet
            .inspect_pset(&regtest_pset)
            .unwrap_err()
            .to_string();
        assert!(err.contains("Network mismatch"), "{err}");
        // And each wallet reads its own network's PSET fine.
        assert_eq!(
            regtest_wallet.inspect_pset(&regtest_pset).unwrap().network,
            "liquid-regtest"
        );
        assert_eq!(
            testnet_wallet.inspect_pset(&testnet_pset).unwrap().network,
            "liquid-testnet"
        );
    }

    /// Prints the base64 of the testnet escrow-spend fixture, the one the
    /// wallet-ffi contract tests pin (`cargo test -p templar-core
    /// print_escrow_fixture -- --ignored --nocapture`).
    #[test]
    #[ignore = "fixture generator"]
    fn print_escrow_fixture() {
        let pset = escrow_spend_pset(
            &LiquidNetwork::testnet(),
            dummy_payout_script(),
            1_000_000,
            999_500,
        );
        println!(
            "ESCROW_FIXTURE={}",
            LiquidWalletManager::pset_to_base64(&pset).unwrap()
        );
    }

    // ── Proof of key (§9) ───────────────────────────────────────────────────

    const CHALLENGE: &str = "Templar Protocol · access · http://127.0.0.1:8087 · \
                             nonce=AAAAAAAAAAAAAAAAAAAAAA · expires=2026-10-03T10:15:00Z · \
                             this signature never moves funds";

    #[test]
    fn fake_txid_is_tagged_and_deterministic() {
        let a = proof_fake_txid("x");
        assert_eq!(a, proof_fake_txid("x"));
        assert_ne!(a, proof_fake_txid("y"));
        let mut data = PROOF_PREVOUT_TAG.to_vec();
        data.extend_from_slice(b"x");
        assert_eq!(a.to_byte_array(), sha256::Hash::hash(&data).to_byte_array());
    }

    #[test]
    fn loan_key_at_zero_reads_both_accounts_and_refuses_the_rest() {
        let signer = SwSigner::new(MNEMONIC_BORROWER, false).unwrap();
        let k2121 = escrow_account_xpub(&signer).unwrap();
        let (pk, fp, path) = loan_key_at_zero(&k2121).unwrap();
        assert_eq!(fp, signer.fingerprint());
        assert_eq!(path.to_string(), "2121'/1'/0'/0/0");
        assert!(pk.compressed);
        // The spelling with apostrophes names the same key.
        let (pk2, _, _) = loan_key_at_zero(&k2121.replace('h', "'")).unwrap();
        assert_eq!(pk, pk2);

        let k87 = Signer::keyorigin_xpub(&signer, lwk_common::Bip::Bip87, false).unwrap();
        assert!(k87.contains("/87h/1h/0h]"), "{k87}");
        let (pk87, fp87, path87) = loan_key_at_zero(&k87).unwrap();
        assert_eq!(fp87, fp);
        assert_eq!(path87.to_string(), "87'/1'/0'/0/0");
        assert_ne!(pk87, pk);

        // No origin, a wildcard, a derivation after the account, garbage.
        let bare = k2121.split(']').nth(1).unwrap();
        assert!(loan_key_at_zero(bare).is_err());
        assert!(loan_key_at_zero(&format!("{k2121}/<0;1>/*")).is_err());
        assert!(loan_key_at_zero(&format!("{k2121}/0/*")).is_err());
        assert!(loan_key_at_zero(&format!("{k2121}/0/0")).is_err());
        assert!(loan_key_at_zero("[deadbeef/2121h/1h/0h]tpubFake").is_err());
        assert!(loan_key_at_zero("").is_err());
    }

    /// Build → one software signature → the site's own verification passes,
    /// through the wallet manager and through the wire encoding.
    #[test]
    fn check_pset_is_built_signed_once_and_verifies() {
        let network = LiquidNetwork::testnet();
        let xpub = escrow_xpub_from_mnemonic(MNEMONIC_BORROWER).unwrap();
        let pset = check_pset(CHALLENGE, &xpub, &network).unwrap();
        assert_eq!(
            pset,
            check_pset(CHALLENGE, &xpub, &network).unwrap(),
            "deterministic"
        );

        let tx = pset.extract_tx().unwrap();
        assert_eq!((tx.input.len(), tx.output.len()), (1, 2));
        assert_eq!(
            tx.input[0].previous_output,
            OutPoint::new(proof_fake_txid(CHALLENGE), 0)
        );
        assert_eq!(tx.input[0].sequence, Sequence::MAX);
        assert!(tx.output[0].script_pubkey.is_op_return());
        assert_eq!(tx.output[0].value, confidential::Value::Explicit(0));
        assert_eq!(
            tx.output[0].asset,
            confidential::Asset::Explicit(network.policy_asset())
        );
        assert!(tx.output[1].is_fee());
        assert_eq!(tx.output[1].value, confidential::Value::Explicit(0));
        assert_eq!(tx.lock_time, lwk_wollet::elements::LockTime::ZERO);
        let input = &pset.inputs()[0];
        let utxo = input.witness_utxo.as_ref().unwrap();
        assert!(utxo.script_pubkey.is_v0_p2wpkh());
        assert_eq!(utxo.value, confidential::Value::Explicit(0));
        assert_eq!(input.bip32_derivation.len(), 1);
        let (fp, path) = input.bip32_derivation.values().next().unwrap();
        assert_eq!(fp.to_string(), "73c5da0a");
        assert_eq!(path.to_string(), "2121'/1'/0'/0/0");
        assert!(is_check_pset(&pset, CHALLENGE, &xpub, &network));
        // Unsigned: the shape is right, the signature is missing.
        assert!(verify_check_signature(&pset, CHALLENGE, &xpub, &network)
            .unwrap_err()
            .to_string()
            .contains("no signature"));

        // The wallet signs it like any PSET naming its key: exactly once.
        let borrower =
            LiquidWalletManager::from_mnemonic_with_persist_on(&network, MNEMONIC_BORROWER, None)
                .unwrap();
        let mut signed = LiquidWalletManager::pset_from_base64(
            &LiquidWalletManager::pset_to_base64(&pset).unwrap(),
        )
        .unwrap();
        assert_eq!(borrower.sign(&mut signed).unwrap(), 1);
        assert_eq!(signed.inputs()[0].partial_sigs.len(), 1);
        assert_eq!(
            borrower.sign(&mut signed).unwrap(),
            0,
            "nothing left to sign"
        );
        let back = LiquidWalletManager::pset_from_base64(
            &LiquidWalletManager::pset_to_base64(&signed).unwrap(),
        )
        .unwrap();
        assert!(
            is_check_pset(&back, CHALLENGE, &xpub, &network),
            "still the check once signed"
        );
        verify_check_signature(&back, CHALLENGE, &xpub, &network).unwrap();

        // The wallet's own reading: not its coin, 0, an OP_RETURN, fee 0.
        let d = borrower.inspect_pset(&back).unwrap();
        assert_eq!(d.inputs.len(), 1);
        assert!(d.inputs[0].is_ours, "the loan key is this wallet's");
        assert_eq!(d.inputs[0].amount, Some(0));
        assert_eq!(d.inputs[0].signed_by, vec!["73c5da0a".to_string()]);
        assert_eq!(d.fee, 0);
        assert!(d.outputs.iter().any(|o| o.kind == "fee"));
        assert!(!d.has_unverified_outputs());

        // A stranger's key is not in it.
        let stranger =
            LiquidWalletManager::from_mnemonic_with_persist_on(&network, MNEMONIC_LENDER, None)
                .unwrap();
        let mut untouched = pset.clone();
        assert_eq!(stranger.sign(&mut untouched).unwrap(), 0);

        // The 87h account is a loan key too.
        let signer = SwSigner::new(MNEMONIC_BORROWER, false).unwrap();
        let k87 = Signer::keyorigin_xpub(&signer, lwk_common::Bip::Bip87, false).unwrap();
        let mut c87 = check_pset(CHALLENGE, &k87, &network).unwrap();
        assert!(
            !is_check_pset(&c87, CHALLENGE, &xpub, &network),
            "another key, another check"
        );
        assert_eq!(borrower.sign(&mut c87).unwrap(), 1);
        verify_check_signature(&c87, CHALLENGE, &k87, &network).unwrap();
    }

    /// Everything that is almost a check is not one, and says why.
    #[test]
    fn anything_but_the_exact_check_is_refused() {
        let network = LiquidNetwork::testnet();
        let xpub = escrow_xpub_from_mnemonic(MNEMONIC_BORROWER).unwrap();
        let fresh = || check_pset(CHALLENGE, &xpub, &network).unwrap();
        let why = |p: &PartiallySignedTransaction, ch: &str, k: &str, n: &LiquidNetwork| {
            assert!(!is_check_pset(p, ch, k, n));
            check_pset_shape(p, ch, k, n).unwrap_err().to_string()
        };

        // A real-looking input: the escrow spend of the loan tests.
        let real = escrow_spend_pset(&network, dummy_payout_script(), 1_000_000, 999_500);
        assert!(why(&real, CHALLENGE, &xpub, &network).contains("worth something"));

        // A real prevout under the right coin.
        let mut prevout = fresh();
        prevout.inputs_mut()[0].previous_txid = Txid::from_byte_array([0x11; 32]);
        assert!(why(&prevout, CHALLENGE, &xpub, &network).contains("real-looking outpoint"));

        // A coin worth one satoshi.
        let mut rich = fresh();
        rich.inputs_mut()[0].witness_utxo.as_mut().unwrap().value =
            confidential::Value::Explicit(1);
        assert!(why(&rich, CHALLENGE, &xpub, &network).contains("worth something"));

        // Another challenge, another site: another transaction.
        assert!(
            why(&fresh(), "another challenge", &xpub, &network).contains("real-looking outpoint")
        );
        let other_site = CHALLENGE.replace("127.0.0.1:8087", "evil.example");
        assert!(!is_check_pset(&fresh(), &other_site, &xpub, &network));

        // Another wallet's key: the coin is somebody else's.
        let lender = escrow_xpub_from_mnemonic(MNEMONIC_LENDER).unwrap();
        assert!(why(&fresh(), CHALLENGE, &lender, &network).contains("loan key"));

        // A second output, or a fee that is not zero.
        let mut extra = fresh();
        extra.add_output(Output::new_explicit(
            dummy_payout_script(),
            0,
            network.policy_asset(),
            None,
        ));
        assert!(why(&extra, CHALLENGE, &xpub, &network).contains("two outputs"));
        let mut fee = fresh();
        fee.outputs_mut()[1].amount = Some(1);
        let fee_tx_differs = why(&fee, CHALLENGE, &xpub, &network);
        assert!(
            fee_tx_differs.contains("fee is not zero"),
            "{fee_tx_differs}"
        );

        // Someone else's text in the OP_RETURN.
        let mut text = fresh();
        text.outputs_mut()[0].script_pubkey = Script::new_op_return(b"something else");
        assert!(why(&text, CHALLENGE, &xpub, &network).contains("OP_RETURN"));

        // A second input.
        let mut two = fresh();
        two.add_input(fresh().inputs()[0].clone());
        assert!(why(&two, CHALLENGE, &xpub, &network).contains("one input"));

        // Another chain's L-BTC.
        let regtest = LiquidNetwork::regtest_default();
        assert!(why(&fresh(), CHALLENGE, &xpub, &regtest).contains("L-BTC"));
        assert!(is_check_pset(
            &check_pset(CHALLENGE, &xpub, &regtest).unwrap(),
            CHALLENGE,
            &xpub,
            &regtest
        ));

        // No challenge is no check.
        assert!(check_pset("", &xpub, &network).is_err());
    }
}
