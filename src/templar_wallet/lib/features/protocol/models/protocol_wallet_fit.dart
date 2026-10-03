import '../../wallet_picker/models/wallet_summary.dart';

/// Whether a wallet can answer a Templar Protocol request, and why not when it cannot.
///
/// One rule, two readers: the request screen filters the chooser with it, and
/// Settings › Templar Protocol offers the same wallets as the preferred one. A
/// second copy of the rule would eventually offer a wallet the request screen
/// refuses.
///
/// A software seed derives the escrow key at `m/2121'/1'/0'`; a Jade offers
/// its BIP87 account (`m/87'/1'/0'`) instead, which the site accepts as a
/// loan key too, and signs a PSET whose inputs name that key. What a Jade
/// cannot do yet is sign the proof of key (connector-protocol.md §9) — the
/// screens say so where it matters, rather than hiding the wallet here.
bool protocolWalletFits(WalletSummary w, {required bool connect}) {
  if (!w.liquidEnabled || w.isViewOnlyWallet || w.isAirgapWallet) return false;
  if (w.type != WalletType.singlesig) return false;
  if (w.isHardwareWallet) return protocolWalletIsJade(w);
  return true;
}

/// A Jade-backed wallet: the one device that can hold a Liquid loan key.
bool protocolWalletIsJade(WalletSummary w) =>
    w.isHardwareWallet && (w.deviceModel ?? '').toLowerCase().contains('jade');
