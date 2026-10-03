/// Proof of key (connector-protocol.md §9), as the bridge reports it.
///
/// The check PSET itself is built and judged by the engine
/// (`protocol_check_pset`, `protocol_is_check_pset`); the app only carries
/// the two answers around: the unsigned check to sign on a v1.1 connect, and
/// the verdict a `proof` signing request gets before anything is signed.
library;

/// The unsigned check of a challenge for this wallet's loan key.
class ProtocolCheck {
  const ProtocolCheck({
    required this.psetBase64,
    required this.loanKey,
    required this.fingerprint,
  });

  final String psetBase64;

  /// `[fp/2121h/1h/0h]tpub…` — the same value a connect sends as `escrow_xpub`.
  final String loanKey;

  /// Master fingerprint of that key, lower-case hex.
  final String fingerprint;

  factory ProtocolCheck.fromJson(Map<String, dynamic> j) => ProtocolCheck(
        psetBase64: (j['pset_base64'] as String?)?.trim() ?? '',
        loanKey: (j['loan_key'] as String?)?.trim() ?? '',
        fingerprint: (j['fingerprint'] as String?)?.trim() ?? '',
      );
}

/// Whether a PSET is exactly the check of a challenge for this wallet's
/// loan key (§9.5), and why not when it is not.
class ProtocolCheckVerdict {
  const ProtocolCheckVerdict({
    required this.isCheck,
    this.reason,
    this.loanKeyFingerprint = '',
  });

  final bool isCheck;

  /// In words, for the review screen's banner. Null when [isCheck].
  final String? reason;
  final String loanKeyFingerprint;

  factory ProtocolCheckVerdict.fromJson(Map<String, dynamic> j) =>
      ProtocolCheckVerdict(
        isCheck: j['is_check'] == true,
        reason: (j['reason'] as String?)?.trim(),
        loanKeyFingerprint: (j['loan_key_fingerprint'] as String?)?.trim() ?? '',
      );
}

/// What every proof route tells a Jade-backed wallet until the check has
/// been exercised on a device. The same sentence the engine uses.
const String kProtocolJadeProofUnsupported =
    'Proof of key through a Jade is not supported yet: the check needs a '
    'zero-value input the device has not been tested with. Connect a software '
    'wallet, or sign the proof with one.';

/// The sentence §9.5 asks the wallet to say, verbatim.
const String kProtocolProofStatement = 'This signature never moves funds';
