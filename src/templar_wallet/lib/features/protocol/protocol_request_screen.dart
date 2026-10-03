import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../app/routes.dart';
import '../../bridge/bridge_provider.dart';
import '../../bridge/wallet_bridge.dart';
import '../../shared/widgets/app_password_gate.dart';
import '../../shared/widgets/badges.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/code_box.dart';
import '../../shared/widgets/expander.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/list_rows.dart';
import '../../shared/widgets/page_header.dart';
import '../../services/protocol_portfolio_service.dart';
import '../../services/protocol_store.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../psbt/models/pset_inspection.dart';
import '../settings/liquid_network_switch.dart';
import '../vault/lock_action.dart';
import '../wallet_picker/models/wallet_summary.dart';
import 'models/protocol_link.dart';
import 'models/protocol_proof.dart';
import 'models/protocol_records.dart';
import 'models/protocol_wallet_fit.dart';
import 'protocol_confirm_gate.dart';
import 'protocol_paste_card.dart';
import 'protocol_network_mismatch_card.dart';

/// Handles a `templar://connect` or `templar://sign` request from a Templar Protocol
/// site (docs/connector-protocol.md §3–§4 in the Templar Protocol repository).
///
/// Lives outside the wallet shell so a link can be answered before any
/// wallet is open: the screen always asks which wallet answers (with the
/// one connected to this site put first), and for the vault passphrase when
/// storage is locked. It fetches the request, validates it (network, origin,
/// transport, expiry), shows what will leave the wallet next to what the
/// site claims, and only after an explicit confirmation plus the app
/// password does it sign and POST the answer. The PSET is never stored and
/// never broadcast from here — the site combines and broadcasts (it is the
/// facilitator, not the custodian).
class ProtocolRequestScreen extends StatefulWidget {
  const ProtocolRequestScreen({super.key, this.rawLink});

  /// The `templar://…` link as delivered by the OS, or null to show a paste
  /// box (manual testing without a registered URL handler).
  final String? rawLink;

  @override
  State<ProtocolRequestScreen> createState() => _ProtocolRequestScreenState();
}

enum _Phase { paste, loading, locked, error, mismatch, chooseWallet, review, done }

class _ProtocolRequestScreenState extends State<ProtocolRequestScreen> {
  final _bridge = walletBridge;

  _Phase _phase = _Phase.loading;
  String? _error;

  /// The link this run is answering. Not `widget.rawLink`: a pasted link has
  /// none, and after a network switch the request is fetched again — both
  /// need the text that actually started the run.
  String? _raw;
  ProtocolLink? _link;
  ProtocolRequest? _request;

  /// Set when the site and the wallet are not on the same chain. Carries
  /// both sides, so the card can offer the switch.
  ProtocolNetworkMismatch? _mismatch;

  /// The engine's Liquid state, read on every run: what the wallet signs on,
  /// whether the network is locked by the environment, and the stock regtest
  /// asset id the mismatch card prefills.
  LiquidNetworkInfo? _netInfo;

  /// Wallet the request is answered with. Chosen here, never assumed: a
  /// link may arrive with another wallet open, or none — and two sites on
  /// the same machine may each know a different wallet.
  WalletSummary? _wallet;
  List<WalletSummary> _wallets = const [];

  /// The wallet Settings › Templar Protocol names, when it can answer this
  /// request. Shown first in the chooser after the site's own wallet; it
  /// never removes the choice.
  String? _preferredWalletId;

  /// Wallets this device has connected to the requesting site before
  /// (`ProtocolStore`): the chooser leads with them, since a signing request
  /// from a site is almost always for the wallet that site knows.
  Set<String> _connectedWalletIds = const {};

  // Connect: what will be shared.
  String? _ctDescriptor;
  String? _escrowXpub;
  String? _receiveAddress;

  /// Connect: the small checkbox that puts Loans in the main menu once the
  /// site has taken the wallet. Shown only while it is not there yet.
  bool _addLoans = false;

  // Sign: the wallet's own reading of the PSET.
  PsetInspection? _inspection;

  /// Sign, action `proof` only: whether the PSET is exactly the check of the
  /// request's challenge for this wallet's key (§9.5). Anything else under
  /// that action is refused before the gate is even offered.
  ProtocolCheckVerdict? _proofVerdict;

  bool _busy = false;
  String? _nextUrl;

  @override
  void initState() {
    super.initState();
    final raw = widget.rawLink;
    if (raw == null || raw.trim().isEmpty) {
      _phase = _Phase.paste;
    } else {
      _start(raw);
    }
  }

  @override
  void didUpdateWidget(covariant ProtocolRequestScreen old) {
    super.didUpdateWidget(old);
    // Belt and braces with the router's key: never keep answering an old
    // request when a new link is handed to this element.
    if (old.rawLink != widget.rawLink && widget.rawLink != null) {
      _start(widget.rawLink!);
    }
  }

  static String _clean(Object e) => e
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst('wallet-ffi: ', '');

  void _fail(Object e) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.error;
      _busy = false;
      _error = _clean(e);
    });
  }

  // ── Fetch + validate ───────────────────────────────────────────────────────

  Future<void> _start(String raw) async {
    debugPrint('[protocol] request: ${raw.split('&nonce=').first}');
    setState(() {
      _raw = raw;
      _phase = _Phase.loading;
      _error = null;
      _request = null;
      _mismatch = null;
      _inspection = null;
      _proofVerdict = null;
      _nextUrl = null;
      // A switch closed whatever was open; and a second link is a second
      // decision, not a continuation of the first.
      _wallet = null;
      _ctDescriptor = null;
      _escrowXpub = null;
      _receiveAddress = null;
      _addLoans = false;
    });
    ProtocolRequest? fetched;
    try {
      final link = ProtocolLink.parse(raw);
      _link = link;

      // Locked storage: nothing can be read or signed. Ask, then resume.
      final vault = await _bridge.vaultStatus();
      if (vault.initialized && !vault.unlocked) {
        if (mounted) setState(() => _phase = _Phase.locked);
        return;
      }

      final request = fetched = await _fetch(link);
      final info = await _network();
      validateProtocolRequest(
        link,
        request,
        activeNetwork: info.network,
        activePolicyAsset: info.isRegtest ? info.policyAsset : null,
      );
      if (!mounted) return;
      setState(() => _request = request);
      await _pickWallet();
    } on ProtocolNetworkMismatch catch (e) {
      // Not a dead end: the wallet can usually be moved to the site's chain
      // from here, so this gets a card of its own.
      if (!mounted) return;
      setState(() {
        _phase = _Phase.mismatch;
        _busy = false;
        _error = null;
        _mismatch = e;
      });
    } on ProtocolLinkError catch (e) {
      // A signing request that died before it could be answered is still
      // part of the user's history: without it the loan page says "waiting
      // for your signature" and the wallet says nothing at all.
      if (fetched != null &&
          _link?.action == ProtocolAction.sign &&
          !fetched.expiresAtTime.isAfter(DateTime.now().toUtc())) {
        await _record(fetched, ProtocolSignOutcome.expired);
      }
      _fail(e);
    } catch (e) {
      _fail(e);
    }
  }

  /// Moves the wallet to the site's chain, then answers the request again.
  ///
  /// The switch itself is the one Settings runs (liquid_network_switch.dart):
  /// same confirmation, same closing of the open wallet. What is added here
  /// is the retry — the point of the card is that the user does not have to
  /// come back with the link a second time.
  Future<void> _switchNetwork(String? policyAsset) async {
    final m = _mismatch;
    final target = m?.targetShortName;
    final raw = _raw;
    if (m == null || target == null || raw == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final done = await switchLiquidNetwork(
        context,
        target: target,
        policyAsset: policyAsset,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      if (done == null) return; // Cancelled at the dialog.
      setState(() => _netInfo = done.info);
      await _start(raw);
    } on LiquidNetworkSwitchError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  Future<ProtocolRequest> _fetch(ProtocolLink link) async {
    final http.Response resp;
    try {
      resp = await http
          .get(link.url, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw ProtocolLinkError('${link.url.host} did not answer within 15 seconds.');
    } catch (e) {
      throw ProtocolLinkError('Could not reach ${link.url.host}: ${_clean(e)}');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ProtocolLinkError(
          '${link.url.host} answered HTTP ${resp.statusCode} for this request. '
          'It may have expired or been used already.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    } catch (_) {
      throw const ProtocolLinkError('The site did not answer with JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ProtocolLinkError('The site did not answer with a request object.');
    }
    return ProtocolRequest.fromJson(decoded);
  }

  /// Always asks the engine: the network is what the wallet will actually
  /// sign on, and a cached value could lag a switch made elsewhere.
  Future<LiquidNetworkInfo> _network() async {
    final info = await _bridge.getLiquidNetwork();
    if (mounted) {
      context.read<AppState>().setLiquidNetworkInfo(info);
      setState(() => _netInfo = info);
    }
    return info;
  }

  // ── Wallet choice ──────────────────────────────────────────────────────────

  bool get _isConnect => _link?.action == ProtocolAction.connect;

  /// Wallets that can answer this request — the same rule Settings offers
  /// the preferred wallet from (models/protocol_wallet_fit.dart).
  bool _eligible(WalletSummary w) => protocolWalletFits(w, connect: _isConnect);

  /// Loads the wallets and shows the chooser. Always: a request is answered
  /// with the wallet the user names, never with whichever happens to be
  /// open — two sites on one machine may each know a different wallet, and
  /// a signature from the wrong one is a refusal on the site and a puzzle
  /// here. The one connected to this site leads the list.
  Future<void> _pickWallet() async {
    final wallets = await _bridge.listWallets();
    final preferredId = await ProtocolStore.instance.preferredWalletId();
    final origin = _link?.url.origin ?? '';
    final sites = await ProtocolStore.instance.sites();
    if (!mounted) return;
    final preferred = wallets.where((w) => w.id == preferredId).firstOrNull;
    setState(() {
      _wallets = wallets;
      _preferredWalletId =
          preferred != null && _eligible(preferred) ? preferred.id : null;
      _connectedWalletIds = {
        for (final s in sites)
          if (s.origin == origin) s.walletId,
      };
      _phase = _Phase.chooseWallet;
    });
  }

  /// Back to the chooser from the review: the wallet was the wrong one (its
  /// key is not in the PSET), or the user changed their mind.
  void _changeWallet() {
    setState(() {
      _phase = _Phase.chooseWallet;
      _error = null;
      _busy = false;
      _wallet = null;
      _inspection = null;
      _proofVerdict = null;
      _ctDescriptor = null;
      _escrowXpub = null;
      _receiveAddress = null;
    });
  }

  Future<void> _useWallet(WalletSummary w) async {
    setState(() {
      _phase = _Phase.loading;
      _wallet = w;
    });
    try {
      final appState = context.read<AppState>();
      if (appState.activeWalletId != w.id) {
        await _bridge.openWallet(w.id);
        if (!mounted) return;
        appState.setActiveWallet(
          w.id,
          name: w.name,
          type: w.displayType,
          liquid: w.liquidEnabled,
          bitcoin: w.bitcoinEnabled,
        );
      }
      if (_isConnect) {
        await _prepareConnect(w);
      } else {
        await _prepareSign(w);
      }
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _prepareConnect(WalletSummary w) async {
    final info = await _bridge.getWalletInfo(w.id);
    final desc = info.liquidDescriptor;
    if (desc == null || desc.isEmpty) {
      throw ProtocolLinkError(
          '"${w.name}" has no Liquid descriptor. Enable Liquid on it first.');
    }
    final xpub = await _bridge.getProtocolEscrowXpub(w.id);
    final addr = await _bridge.generateReceiveAddress(w.id, 'LBTC');
    if (!mounted) return;
    setState(() {
      _ctDescriptor = desc;
      _escrowXpub = xpub;
      _receiveAddress = addr.address;
      _phase = _Phase.review;
    });
  }

  Future<void> _prepareSign(WalletSummary w) async {
    final req = _request!;
    final pset = req.pset!;
    // The engine refuses a PSET carrying another network's assets here,
    // independently of what the site claimed in `network`.
    final inspection = await _bridge.inspectPset(w.id, pset);
    final verdict = req.isProof ? await _judgeProof(w, req, pset) : null;
    if (!mounted) return;
    setState(() {
      _inspection = inspection;
      _proofVerdict = verdict;
      _phase = _Phase.review;
    });
  }

  /// §9.5: under action `proof`, nothing but the exact check PSET of the
  /// request's own challenge for this wallet's loan key is signed. The
  /// check is recomputed by the engine from the challenge text and the key —
  /// the site's PSET is compared against it, never taken at its word.
  Future<ProtocolCheckVerdict> _judgeProof(
      WalletSummary w, ProtocolRequest req, String pset) async {
    final challenge = req.challenge;
    if (challenge == null || challenge.isEmpty) {
      return const ProtocolCheckVerdict(
        isCheck: false,
        reason: 'The site sent a proof request without the challenge text it '
            'is supposed to prove. Nothing can be checked, so nothing is signed.',
      );
    }
    if (w.isHardwareWallet) {
      return const ProtocolCheckVerdict(
          isCheck: false, reason: kProtocolJadeProofUnsupported);
    }
    try {
      return await _bridge.protocolIsCheckPset(w.id, challenge, pset);
    } catch (e) {
      return ProtocolCheckVerdict(
          isCheck: false, reason: 'The proof could not be checked: ${_clean(e)}');
    }
  }

  // ── Answer ─────────────────────────────────────────────────────────────────

  /// Whether this connect carries a proof: the site sent a challenge (v1.1)
  /// and the wallet can sign the check — a Jade cannot yet, and the site
  /// then falls back to a `proof` signing request when it needs one.
  bool get _connectProves {
    final c = _request?.challenge;
    final w = _wallet;
    return c != null && c.isNotEmpty && w != null && !w.isHardwareWallet;
  }

  Future<void> _confirmConnect() async {
    final w = _wallet!;
    final req = _request!;
    final proves = _connectProves;
    final ok = await showSpendPasswordGate(
      context,
      title: 'Share this wallet with ${req.site}?',
      confirmLabel: 'Share',
      message: 'Templar will send ${req.site} the watch-only descriptor of '
          '"${w.name}" (it can then see this wallet\'s Liquid balance and '
          'history), its loan escrow key, and a receive address'
          '${proves ? ', and will sign a proof of that key — a check that never moves funds — so the site recognises it again' : ''}. '
          'No secret leaves this computer.',
    );
    if (!ok || !mounted) return;
    // v1.1 (§9.3): the proof rides in the callback. Built by the engine from
    // the site's challenge and this wallet's loan key, signed through the
    // same route as any PSET naming the key. A refusal here is a refusal
    // of the whole connect — the site would only ask for it again.
    Map<String, dynamic>? proof;
    if (proves) {
      setState(() => _busy = true);
      try {
        final check = await _bridge.protocolCheckPset(w.id, req.challenge!);
        final signed = await _bridge.signPset(w.id, check.psetBase64);
        proof = {'kind': 'check-pset', 'pset': signed};
      } catch (e) {
        _fail(ProtocolLinkError('Could not sign the proof of key: ${_clean(e)}'));
        return;
      }
      if (!mounted) return;
    }
    final reply = await _post({
      'version': 1,
      'nonce': req.nonce,
      'network': req.network,
      'ct_descriptor': _ctDescriptor,
      'escrow_xpub': _escrowXpub,
      'receive_address': _receiveAddress,
      'wallet_name': 'Templar — ${w.name}',
      'signer': w.isHardwareWallet ? 'jade' : 'software',
      'proof': ?proof,
    });
    // Only once the site has taken it: a refused callback shared nothing.
    if (reply != null) {
      await _recordConnect(
          ProtocolConnectedSite.portfolioFromReply(reply['portfolio']));
      if (_addLoans && mounted) {
        await context.read<AppState>().setLoansInMenu(true);
      }
    }
  }

  /// Remembers that this site now holds a watch-only view of this wallet.
  /// What is kept is deliberately thin — see protocol_records.dart — plus,
  /// since v1.1, the portfolio URL and token the site hands back, which feed
  /// the Loans screen (§7). A v1 site sends none and the record says so.
  Future<void> _recordConnect(({String url, String token})? portfolio) async {
    final w = _wallet;
    final req = _request;
    if (w == null || req == null) return;
    final site = ProtocolConnectedSite(
      site: req.site,
      origin: _link?.url.origin ?? '',
      network: req.network,
      walletId: w.id,
      walletName: w.name,
      connectedAt: DateTime.now().toUtc(),
      escrowFingerprint: protocolKeyFingerprint(_escrowXpub),
      receiveAddress: _receiveAddress ?? '',
      portfolioUrl: portfolio?.url,
      portfolioToken: portfolio?.token,
    );
    await ProtocolStore.instance.recordConnect(site);
    if (site.hasPortfolio) {
      // Warm the Loans screen; nobody waits for this.
      unawaited(ProtocolPortfolioService.instance.refreshOrigin(site.origin));
    }
  }

  /// A signed callback's answer may carry the `portfolio` object too: the
  /// v1 reconnect path hands the token over only once the key is proved
  /// (§7, §9.2). The record of this site and wallet takes it; when there is
  /// none yet — the connect happened from another install — one is made,
  /// since the site evidently knows this wallet.
  Future<void> _storePortfolioFromSign(Map<String, dynamic> reply) async {
    final w = _wallet;
    final req = _request;
    final origin = _link?.url.origin;
    final portfolio = ProtocolConnectedSite.portfolioFromReply(reply['portfolio']);
    if (w == null || req == null || origin == null || portfolio == null) return;
    final store = ProtocolStore.instance;
    final key = '$origin|${w.id}';
    final known = (await store.sites()).any((s) => s.key == key);
    if (known) {
      await store.setPortfolio(key, url: portfolio.url, token: portfolio.token);
    } else {
      await store.recordConnect(ProtocolConnectedSite(
        site: req.site,
        origin: origin,
        network: req.network,
        walletId: w.id,
        walletName: w.name,
        connectedAt: DateTime.now().toUtc(),
        portfolioUrl: portfolio.url,
        portfolioToken: portfolio.token,
      ));
    }
  }

  /// Remembers how a signing request ended.
  Future<void> _record(ProtocolRequest req, ProtocolSignOutcome outcome) async {
    await ProtocolStore.instance.recordSign(ProtocolSignRecord(
      site: req.site,
      origin: _link?.url.origin ?? '',
      walletName: _wallet?.name ?? '',
      at: DateTime.now().toUtc(),
      outcome: outcome,
      loanRef: req.loanRef ?? '',
      action: req.action ?? '',
    ));
  }

  Future<void> _confirmSign() async {
    final w = _wallet!;
    final req = _request!;
    if (req.isProof && _proofVerdict?.isCheck != true) {
      // The gate is disabled for this case; this is the belt to its braces.
      _fail(ProtocolLinkError(_proofVerdict?.reason ??
          'This is not the proof-of-key check of the request\'s challenge.'));
      return;
    }
    final ok = await showSpendPasswordGate(
      context,
      title: 'Sign for ${req.site}?',
      message: req.isProof
          ? 'Templar is about to sign a proof that "${w.name}" holds its loan '
              'key, and send it to ${req.site}. The signed check can never be '
              'broadcast: it spends no coin and pays nobody. $kProtocolProofStatement.'
          : 'Templar is about to sign this ${req.actionLabel.toLowerCase()} '
              'with the key of "${w.name}" and send the signature to ${req.site}. '
              'The site broadcasts once every party has signed; nothing is '
              'broadcast from here.',
    );
    if (!ok) {
      await _record(req, ProtocolSignOutcome.refused);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    final String signed;
    try {
      signed = w.isHardwareWallet
          ? await _bridge.signPsetHw(w.id, req.pset!)
          : await _bridge.signPset(w.id, req.pset!);
    } catch (e) {
      await _record(req, ProtocolSignOutcome.failed);
      _fail(ProtocolLinkError('Signing failed: ${_clean(e)}'));
      return;
    }
    if (!mounted) return;
    final reply = await _post({
      'version': 1,
      'id': req.id,
      'nonce': req.nonce,
      'pset': signed,
    });
    await _record(
        req, reply != null ? ProtocolSignOutcome.signed : ProtocolSignOutcome.failed);
    if (reply != null) {
      await _storePortfolioFromSign(reply);
      // The loan moved a step: the Loans screen should say so when the user
      // gets back to it, without waiting for them to press Refresh.
      final origin = _link?.url.origin;
      if (origin != null) {
        unawaited(ProtocolPortfolioService.instance.refreshOrigin(origin));
      }
    }
  }

  /// Sends the answer. Returns the site's reply when it accepted it, null
  /// otherwise — a refusal has already been shown by then.
  Future<Map<String, dynamic>?> _post(Map<String, dynamic> body) async {
    final req = _request!;
    setState(() => _busy = true);
    try {
      final http.Response resp;
      try {
        resp = await http
            .post(
              req.callback,
              headers: const {
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 20));
      } on TimeoutException {
        throw ProtocolLinkError(
            '${req.callback.host} did not accept the answer within 20 seconds. '
            'Nothing was broadcast; you can retry from the site.');
      } catch (e) {
        throw ProtocolLinkError('Could not reach ${req.callback.host}: ${_clean(e)}');
      }
      Map<String, dynamic> reply = const {};
      try {
        final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
        if (decoded is Map<String, dynamic>) reply = decoded;
      } catch (_) {}
      final accepted = resp.statusCode >= 200 &&
          resp.statusCode < 300 &&
          (reply['ok'] == true || reply.isEmpty);
      if (!accepted) {
        final why = (reply['error'] as String?)?.trim();
        throw ProtocolLinkError(
            '${req.site} rejected the answer (HTTP ${resp.statusCode})'
            '${why != null && why.isNotEmpty ? ': $why' : '.'}');
      }
      if (!mounted) return reply;
      setState(() {
        _busy = false;
        _nextUrl = reply['next'] as String?;
        _phase = _Phase.done;
      });
      return reply;
    } on ProtocolLinkError catch (e) {
      _fail(e);
      return null;
    } catch (e) {
      _fail(e);
      return null;
    }
  }

  Future<void> _openNext() async {
    final next = _nextUrl;
    if (next == null) return;
    final uri = Uri.tryParse(next);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// The browser, at the site's root — where the user clicks "Connect" or
  /// opens the loan again. Offered after a refusal, because a request that
  /// died (an expired token, a token already used by the run before a
  /// network switch) is restarted there, not here.
  Future<void> _openSite() async {
    final link = _link;
    if (link == null) return;
    await launchUrl(Uri.parse(link.url.origin),
        mode: LaunchMode.externalApplication);
  }

  /// Settings › Network & Sync. It lives inside the wallet shell, so with no
  /// wallet open the router would bounce to the picker without a word —
  /// say so instead of appearing to ignore the tap.
  void _openNetworkSettings() {
    if (context.read<AppState>().activeWalletId != null) {
      context.go(AppRoutes.settingsNetwork);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Open a wallet first, then Settings › Network & Sync.'),
        duration: Duration(seconds: 5),
      ),
    );
    context.go(AppRoutes.walletPicker);
  }

  void _leave() {
    final hasWallet = context.read<AppState>().activeWalletId != null;
    context.go(hasWallet ? AppRoutes.dashboard : AppRoutes.walletPicker);
  }

  void _openLoans() => context.go(AppRoutes.loans);

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final req = _request;
    final title = switch (_link?.action) {
      ProtocolAction.connect => 'Connect wallet',
      ProtocolAction.sign => req?.actionLabel ?? 'Sign request',
      null => 'Templar Protocol',
    };
    final subtitle = req != null
        ? '${req.site} · ${_link?.origin ?? req.callback.host} · ${protocolNetworkLabel(req.network)}'
        : 'A site is asking this wallet to take part in a loan.';
    final canChangeWallet = _wallet != null &&
        _wallets.length > 1 &&
        (_phase == _Phase.review || _phase == _Phase.error) &&
        !_busy;

    return Scaffold(
      body: PageBackground.flat(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: ListView(
              padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
              children: [
                PageHeader(
                  title: title,
                  subtitle: subtitle,
                  actions: [
                    if (canChangeWallet)
                      GhostButton(
                        key: const Key('protocol-change-wallet'),
                        label: 'Change wallet',
                        icon: Icons.swap_horiz_rounded,
                        onPressed: _changeWallet,
                      ),
                    GhostButton(
                      label: _phase == _Phase.done ? 'Close' : 'Cancel',
                      icon: Icons.close,
                      onPressed: _busy ? null : _leave,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                _body(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() => switch (_phase) {
        _Phase.paste => ProtocolPasteCard(onOpen: _start),
        _Phase.loading => Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
              child: const CircularProgressIndicator(),
            ),
          ),
        _Phase.locked => _LockedCard(onUnlock: () {
            pushVaultUnlock(context, onUnlocked: () {
              if (mounted && _raw != null) _start(_raw!);
            });
          }),
        _Phase.error => _ErrorCard(
            message: _error ?? 'Something went wrong.',
            onRetry: _raw == null ? null : () => _start(_raw!),
            onOpenSite: _link == null ? null : _openSite,
            siteName: _request?.site ?? _link?.url.host,
          ),
        _Phase.mismatch => ProtocolNetworkMismatchCard(
            mismatch: _mismatch!,
            info: _netInfo,
            busy: _busy,
            onSwitch: _switchNetwork,
            onOpenSettings: _openNetworkSettings,
          ),
        _Phase.chooseWallet => _WalletChoice(
            wallets: _wallets,
            eligible: _eligible,
            connect: _isConnect,
            siteName: _request?.site ?? _link?.url.host ?? 'the site',
            preferredWalletId: _preferredWalletId,
            activeWalletId: context.read<AppState>().activeWalletId,
            connectedWalletIds: _connectedWalletIds,
            onPick: _useWallet,
          ),
        _Phase.review => _isConnect ? _connectReview() : _signReview(),
        _Phase.done => _DoneCard(
            site: _request!.site,
            connect: _isConnect,
            next: _nextUrl,
            onOpen: _openNext,
            onClose: _leave,
            onOpenLoans: _isConnect && context.read<AppState>().loansInMenu
                ? _openLoans
                : null,
          ),
      };

  // ── Connect review ─────────────────────────────────────────────────────────

  Widget _connectReview() {
    final req = _request!;
    final w = _wallet!;
    final s = AppScheme.of(context);
    final loansInMenu = context.watch<AppState>().loansInMenu;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ActionHeader(
          icon: Icons.link_rounded,
          tint: s.liquid,
          title: 'Share a view of "${w.name}" with ${req.site}',
          subtitle: 'The site will see this wallet\'s Liquid balance and history and '
              'build loan transactions for it. It cannot spend: every signature '
              'happens here, after you confirm.',
          chips: [
            TagChip(label: protocolNetworkLabel(req.network), color: s.liquid),
            TagChip(label: w.isHardwareWallet ? 'Jade' : 'software seed', color: s.inkSecondary),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        _ShareFlow(site: req.site, walletName: w.name),
        const SizedBox(height: AppSpacing.lg),
        FormCard(
          title: 'Shared with ${req.site}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CopyRow(label: 'Wallet', value: 'Templar — ${w.name}', mono: false),
              const Divider(height: 1),
              CopyRow(label: 'Signer', value: w.isHardwareWallet ? 'jade' : 'software', mono: false),
              const Divider(height: 1),
              CopyRow(label: 'Network', value: protocolNetworkLabel(req.network), mono: false),
              const Divider(height: 1),
              CopyRow(label: 'Receive address', value: _receiveAddress ?? ''),
              const SizedBox(height: AppSpacing.lg),
              CodeBox(label: 'Liquid CT descriptor (watch-only)', value: _ctDescriptor ?? ''),
              const SizedBox(height: AppSpacing.lg),
              CodeBox(
                label: w.isHardwareWallet
                    ? 'Loan key (m/87\'/1\'/0\', read from the Jade)'
                    : 'Escrow key (m/2121\'/1\'/0\')',
                value: _escrowXpub ?? '',
              ),
            ],
          ),
        ),
        if (req.challenge != null) ...[
          const SizedBox(height: AppSpacing.lg),
          _ProofCard(
            challenge: req.challenge!,
            origin: _link?.origin ?? req.callback.origin,
            expiresAt: req.expiresAtTime,
            walletName: w.name,
            keyFingerprint: protocolKeyFingerprint(_escrowXpub),
            title: _connectProves
                ? 'Proof of key, signed with the share'
                : 'Proof of key: not from a Jade yet',
            body: _connectProves
                ? 'So that ${req.site} recognises this key again later, the wallet '
                    'also signs a check built from the line below: one input that '
                    'is no coin, 0 L-BTC, the line itself as the only output. It '
                    'can never be broadcast. It proves the key; it moves nothing.'
                : '$kProtocolJadeProofUnsupported The site may ask for the proof '
                    'through a signing request instead.',
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        FormCard(
          title: 'Sent to',
          child: CopyRow(label: 'Callback', value: req.callback.toString()),
        ),
        if (!loansInMenu) ...[
          const SizedBox(height: AppSpacing.lg),
          _LoansOptIn(
            value: _addLoans,
            onChanged: (v) => setState(() => _addLoans = v),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        if (_error != null) ...[
          DangerBanner(message: _error!),
          const SizedBox(height: AppSpacing.lg),
        ],
        ProtocolConfirmGate(
          statement: 'I want ${req.site} to watch "${w.name}" and to use its escrow key in my loans.',
          buttonLabel: 'Share with ${req.site}',
          icon: Icons.link,
          busy: _busy,
          onConfirm: _confirmConnect,
        ),
      ],
    );
  }

  // ── Sign review ────────────────────────────────────────────────────────────

  /// Action `proof` (§9.2 / §9.5): the dedicated review. The verdict leads;
  /// the challenge, the origin and the expiry are shown as the site sent
  /// them; the wallet's own reading sits underneath as evidence (not its
  /// coin, 0, an OP_RETURN, fee 0); the gate opens only on a true check.
  Widget _proofReview() {
    final req = _request!;
    final w = _wallet!;
    final i = _inspection!;
    final s = AppScheme.of(context);
    final origin = _link?.origin ?? req.callback.origin;
    final v = _proofVerdict ??
        const ProtocolCheckVerdict(
            isCheck: false, reason: 'The proof was not checked.');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ActionHeader(
          icon: Icons.verified_user_outlined,
          tint: v.isCheck ? s.liquid : s.danger,
          title: 'Prove that "${w.name}" holds its loan key',
          subtitle: 'A signature on a check that can never be broadcast: it spends '
              'no coin and pays nobody. $kProtocolProofStatement.',
          chips: [
            TagChip(label: 'proof of key', color: s.liquid),
            TagChip(label: protocolNetworkLabel(req.network), color: s.inkSecondary),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        if (!v.isCheck)
          DangerBanner(
            title: 'Refusing to sign this',
            message: '${v.reason ?? 'This is not the check of the request\'s challenge.'} '
                'Under a proof request Templar signs only the exact check it '
                'recomputes from the challenge and its own key — nothing else, '
                'whatever the site says it is.',
          )
        else
          InfoBanner(
            title: 'The check is genuine',
            message: 'The engine rebuilt it from the line below and this wallet\'s '
                'loan key; the site\'s PSET is that check, byte for byte. It '
                'proves to $origin that "${w.name}" holds the key, so the site '
                'can show you your loans again.',
          ),
        const SizedBox(height: AppSpacing.lg),
        _ProofCard(
          challenge: req.challenge ?? '',
          origin: origin,
          expiresAt: req.expiresAtTime,
          walletName: w.name,
          keyFingerprint: v.loanKeyFingerprint,
          title: 'What you are signing',
        ),
        const SizedBox(height: AppSpacing.lg),
        _NetChangeCard(inspection: i, walletName: w.name),
        const SizedBox(height: AppSpacing.lg),
        ExpanderCard(
          key: const Key('protocol-technical-details'),
          title: 'Technical details',
          subtitle: 'The request, and the wallet\'s raw reading of the check.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _RequestRows(request: req, walletName: w.name),
              const SizedBox(height: AppSpacing.lg),
              _SiteSaysCard(request: req, compact: true),
              const SizedBox(height: AppSpacing.lg),
              _RawReading(inspection: i, walletName: w.name),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        if (_error != null) ...[
          DangerBanner(message: _error!),
          const SizedBox(height: AppSpacing.lg),
        ],
        Text(
          'The signature is sent to ${req.site} only. Nothing is broadcast by this wallet, '
          'and the check is not kept once this screen closes.',
          style: AppTypography.caption.copyWith(color: s.inkSecondary),
        ),
        const SizedBox(height: AppSpacing.md),
        ProtocolConfirmGate(
          key: const Key('protocol-proof-gate'),
          statement: 'I understand this signature proves my loan key to $origin and moves no funds.',
          buttonLabel: 'Sign the proof for ${req.site}',
          busy: _busy,
          enabled: v.isCheck,
          onConfirm: _confirmSign,
        ),
      ],
    );
  }

  /// Every other action: what this does to the wallet (the net change the
  /// engine computed), where the money goes (the outputs, as a flow), what
  /// the site says it is (its own lines, to compare), and the raw reading
  /// under a fold. One column, read top to bottom.
  Widget _signReview() {
    final req = _request!;
    if (req.isProof) return _proofReview();
    final w = _wallet!;
    final i = _inspection!;
    final ours = i.ourInputs;
    final s = AppScheme.of(context);
    final role = req.summary?.role ?? '';
    final loanRef = req.loanRef ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ActionHeader(
          icon: _actionIcon(req.action),
          tint: s.accent,
          title: req.actionLabel,
          subtitle: [
            if (loanRef.isNotEmpty) 'Loan $loanRef',
            if (role.isNotEmpty) 'you are the $role',
            'signed with "${w.name}"',
          ].join(' · '),
          chips: [
            TagChip(label: req.site, color: s.accent),
            TagChip(label: protocolNetworkLabel(req.network), color: s.liquid),
            if (i.touchesEscrow) TagChip(label: 'loan escrow', color: s.warning),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        if (ours.isEmpty)
          WarningBanner(
            title: 'Nothing here is for this wallet to sign',
            message: 'None of the inputs names a key of "${w.name}". Either the '
                'site sent this request to the wrong wallet, or the wallet that '
                'took part in the loan is a different one — pick it with '
                '"Change wallet" above.',
            action: _wallets.length > 1
                ? GhostButton(
                    label: 'Change wallet',
                    icon: Icons.swap_horiz_rounded,
                    onPressed: _changeWallet,
                  )
                : null,
          )
        else
          InfoBanner(
            title: 'Read it top to bottom',
            message: 'First what changes for this wallet, then where every coin '
                'goes — both read by the wallet from the transaction itself. '
                'Then what ${req.site} says it is. Sign only if they agree; the '
                'site cannot change what the wallet sees.',
          ),
        const SizedBox(height: AppSpacing.lg),
        _NetChangeCard(inspection: i, walletName: w.name),
        const SizedBox(height: AppSpacing.lg),
        _FlowCard(inspection: i),
        const SizedBox(height: AppSpacing.lg),
        _SiteSaysCard(request: req),
        const SizedBox(height: AppSpacing.lg),
        ExpanderCard(
          key: const Key('protocol-technical-details'),
          title: 'Technical details',
          subtitle: 'Request ids, every input and output as the wallet reads them, '
              'the escrow contract.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _RequestRows(request: req, walletName: w.name),
              const SizedBox(height: AppSpacing.lg),
              _RawReading(inspection: i, walletName: w.name),
              if (req.escrow != null && req.escrow!.address.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.lg),
                Text('Escrow contract named by the site',
                    style: AppTypography.sectionTitle),
                const SizedBox(height: AppSpacing.sm),
                CopyRow(label: 'Address', value: req.escrow!.address),
                if (req.escrow!.descriptor.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  CodeBox(label: 'Descriptor', value: req.escrow!.descriptor),
                ],
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        if (_error != null) ...[
          DangerBanner(message: _error!),
          const SizedBox(height: AppSpacing.lg),
        ],
        Text(
          'The signature is sent to ${req.site} only. Nothing is broadcast by this wallet, '
          'and the transaction is not kept once this screen closes.',
          style: AppTypography.caption.copyWith(color: s.inkSecondary),
        ),
        const SizedBox(height: AppSpacing.md),
        ProtocolConfirmGate(
          statement: 'I compared what the wallet reads with what the site says, and they describe the same transaction.',
          buttonLabel: 'Sign and send to ${req.site}',
          busy: _busy,
          enabled: ours.isNotEmpty,
          onConfirm: _confirmSign,
        ),
      ],
    );
  }
}

IconData _actionIcon(String? action) => switch (action) {
      'origination' => Icons.handshake_outlined,
      'repayment' => Icons.payments_outlined,
      'installment' => Icons.event_repeat_rounded,
      'default' => Icons.gavel_outlined,
      'liquidation' => Icons.gavel_outlined,
      'swap' => Icons.swap_horiz_rounded,
      'proof' => Icons.verified_user_outlined,
      _ => Icons.draw_outlined,
    };

// ── Pieces ────────────────────────────────────────────────────────────────────

/// The one-glance head of a review: a big glyph for what this is, the title,
/// one sentence, and the chips that place it (site, network, role).
class _ActionHeader extends StatelessWidget {
  const _ActionHeader({
    required this.icon,
    required this.tint,
    required this.title,
    required this.subtitle,
    this.chips = const [],
  });
  final IconData icon;
  final Color tint;
  final String title;
  final String subtitle;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    return FormCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListIconTile(icon: icon, tint: tint, size: phone ? 48 : 56),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: AppTypography.sectionTitleOf(context).copyWith(color: s.ink)),
                const SizedBox(height: AppSpacing.xs),
                Text(subtitle,
                    style: AppTypography.bodySmall.copyWith(color: s.inkSecondary)),
                if (chips.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(spacing: AppSpacing.xs, runSpacing: AppSpacing.xs, children: chips),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Connect, as a picture: what goes to the site and what stays here.
class _ShareFlow extends StatelessWidget {
  const _ShareFlow({required this.site, required this.walletName});
  final String site;
  final String walletName;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    Widget tile(IconData icon, Color tint, String title, String body) => Expanded(
          child: DataWell(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListIconTile(icon: icon, tint: tint, size: 32),
                const SizedBox(height: AppSpacing.sm),
                Text(title,
                    style: AppTypography.body
                        .copyWith(color: s.ink, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(body, style: AppTypography.caption.copyWith(color: s.inkSecondary)),
              ],
            ),
          ),
        );
    final arrow = Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: Icon(Icons.arrow_forward_rounded, color: s.inkFaint),
    );
    return FormCard(
      title: 'What leaves this computer, and what never does',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              tile(Icons.visibility_outlined, s.liquid, 'A view',
                  'Watch-only descriptor, loan key, one address → $site'),
              arrow,
              tile(Icons.language_rounded, s.accent, site,
                  'Sees balances and history; builds each loan transaction'),
              arrow,
              tile(Icons.draw_outlined, s.liquid, 'Your signature',
                  'Every step comes back here to be read and signed by you'),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Icon(Icons.lock_outline_rounded, size: 16, color: s.success),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  'Stays here: the seed of "$walletName" and every private key. '
                  'The escrow key is its own account below the seed, used only in loans.',
                  style: AppTypography.caption.copyWith(color: s.inkSecondary),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The checkbox a connect offers: put Loans in the main menu.
class _LoansOptIn extends StatelessWidget {
  const _LoansOptIn({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return FormCard(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.sm, AppSpacing.xs, AppSpacing.lg, AppSpacing.xs),
      child: Material(
        type: MaterialType.transparency,
        child: CheckboxListTile(
          key: const Key('protocol-add-loans'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          activeColor: AppColors.accent,
          value: value,
          onChanged: (v) => onChanged(v ?? false),
          title: Text('Add Loans to the menu',
              style: AppTypography.body.copyWith(color: s.ink)),
          subtitle: Text(
            'A Loans page beside the Dashboard with this site\'s loans, payments '
            'and pending signatures. You can switch it off in Settings › Templar Protocol.',
            style: AppTypography.caption.copyWith(color: s.inkSecondary),
          ),
          secondary: ListIconTile(icon: Icons.handshake_outlined, tint: s.liquid, size: 32),
        ),
      ),
    );
  }
}

/// What the signature does to this wallet, in one figure per asset: the net
/// change the engine computed from its own unblinding — the one number a
/// PSET cannot misstate. Green comes in, amber goes out.
class _NetChangeCard extends StatelessWidget {
  const _NetChangeCard({required this.inspection, required this.walletName});
  final PsetInspection inspection;
  final String walletName;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final lines = inspection.netChangeLines;
    return FormCard(
      title: 'What changes for "$walletName"',
      subtitle: 'Read by the wallet from the transaction itself, not from the site.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (inspection.hasUnverifiedOutputs)
            const Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.md),
              child: DangerBanner(
                message: 'An output claims an amount or asset its commitment does not '
                    'prove. The engine will not sign this.',
              ),
            ),
          if (lines.isEmpty)
            Row(
              children: [
                ListIconTile(icon: Icons.remove_rounded, tint: s.inkFaint, size: 36),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    'Nothing of this wallet\'s moves. The signature only unlocks the '
                    'escrow for the other party, or proves a key.',
                    style: AppTypography.body.copyWith(color: s.inkSecondary),
                  ),
                ),
              ],
            )
          else
            for (var i = 0; i < lines.length; i++) ...[
              if (i > 0) Divider(height: AppSpacing.lg, color: s.edge),
              _NetChangeRow(line: lines[i]),
            ],
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Icon(Icons.local_gas_station_outlined, size: 14, color: s.inkFaint),
              const SizedBox(width: AppSpacing.xs),
              Text('Network fee ${inspection.feeDisplay}',
                  style: AppTypography.caption.copyWith(color: s.inkFaint)),
              const Spacer(),
              Text(
                '${inspection.sigsHave} of ${inspection.sigsNeeded} signatures on the least-signed input',
                style: AppTypography.caption.copyWith(color: s.inkFaint),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NetChangeRow extends StatelessWidget {
  const _NetChangeRow({required this.line});
  final PsetNetChange line;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final incoming = line.isIncoming;
    final tint = incoming ? s.success : s.warning;
    return Row(
      children: [
        ListIconTile(
          icon: incoming ? Icons.south_west_rounded : Icons.north_east_rounded,
          tint: tint,
          size: 36,
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Text(
            incoming ? 'Comes into this wallet' : 'Leaves this wallet',
            style: AppTypography.body.copyWith(color: s.inkSecondary),
          ),
        ),
        Text(
          line.displayAmount,
          style: AppTypography.numericLarge.copyWith(
            color: tint,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// Where every coin goes, as a flow: what feeds the transaction on top,
/// then one row per output with a glyph for its destination — back to this
/// wallet, into the loan escrow, to the other party, the network fee.
class _FlowCard extends StatelessWidget {
  const _FlowCard({required this.inspection});
  final PsetInspection inspection;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final i = inspection;
    final ownCoins = i.inputs.where((x) => x.isOurs && !x.isScriptHash).length;
    final ownEscrow = i.inputs.where((x) => x.isOurs && x.isScriptHash).length;
    final others = i.inputs.where((x) => !x.isOurs).length;
    final sources = <Widget>[
      if (ownCoins > 0)
        _SourceChip(
          icon: Icons.account_balance_wallet_outlined,
          tint: s.liquid,
          label: '$ownCoins of your coin${ownCoins == 1 ? '' : 's'}',
        ),
      if (ownEscrow > 0)
        _SourceChip(
          icon: Icons.lock_open_rounded,
          tint: s.accent,
          label: 'the loan escrow · your key',
        ),
      if (others > 0)
        _SourceChip(
          icon: Icons.person_outline_rounded,
          tint: s.inkSecondary,
          label: '$others input${others == 1 ? '' : 's'} from others',
        ),
    ];
    return FormCard(
      title: 'Where the money goes',
      subtitle: 'Every output of the transaction, classified by the wallet.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('FROM',
              style: AppTypography.navSection.copyWith(color: s.inkFaint, letterSpacing: 1.2)),
          const SizedBox(height: AppSpacing.xs),
          Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.xs, children: sources),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Row(
              children: [
                const SizedBox(width: 10),
                Icon(Icons.arrow_downward_rounded, size: 18, color: s.inkFaint),
              ],
            ),
          ),
          Text('TO',
              style: AppTypography.navSection.copyWith(color: s.inkFaint, letterSpacing: 1.2)),
          const SizedBox(height: AppSpacing.xs),
          for (var k = 0; k < i.outputs.length; k++) ...[
            if (k > 0) Divider(height: AppSpacing.md, color: s.edge),
            _OutputRow(output: i.outputs[k]),
          ],
        ],
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.icon, required this.tint, required this.label});
  final IconData icon;
  final Color tint;
  final String label;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm + 2, vertical: 6),
      decoration: BoxDecoration(
        color: s.panelInset,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm + 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: tint),
          const SizedBox(width: 6),
          Text(label, style: AppTypography.caption.copyWith(color: s.ink)),
        ],
      ),
    );
  }
}

class _OutputRow extends StatelessWidget {
  const _OutputRow({required this.output});
  final PsetOutput output;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final o = output;
    final (icon, tint, label) = switch (o.kind) {
      'own' => (Icons.account_balance_wallet_outlined, s.liquid, 'Back to this wallet'),
      'escrow' => (Icons.lock_outline_rounded, s.accent, 'Into the loan escrow'),
      'fee' => (Icons.local_gas_station_outlined, s.inkFaint, 'Network fee'),
      _ => (Icons.person_outline_rounded, AppColors.warning, 'To someone else'),
    };
    final addr = o.address;
    final amount = o.unverified
        ? 'unverified'
        : (o.displayAmount ?? (o.ticker != null ? 'blinded (${o.ticker})' : 'blinded'));
    return Row(
      children: [
        ListIconTile(icon: icon, tint: tint, size: 36),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: AppTypography.body.copyWith(color: s.ink)),
              if (addr != null && addr.isNotEmpty)
                Text(_short(addr),
                    style: AppTypography.monoSmall.copyWith(color: s.inkFaint)),
            ],
          ),
        ),
        Text(
          amount,
          style: AppTypography.numericSmall.copyWith(
            color: o.unverified ? s.danger : s.ink,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  static String _short(String a) =>
      a.length <= 22 ? a : '${a.substring(0, 12)}…${a.substring(a.length - 8)}';
}

/// The site's own description, to compare with the wallet's reading above
/// — never instead of it.
class _SiteSaysCard extends StatelessWidget {
  const _SiteSaysCard({required this.request, this.compact = false});
  final ProtocolRequest request;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final summary = request.summary;
    final body = summary == null || summary.lines.isEmpty
        ? Text('The site sent no summary.',
            style: AppTypography.caption.copyWith(color: s.inkSecondary))
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (summary.role.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: TagChip(label: 'Your role: ${summary.role}', color: s.accent),
                ),
              for (final line in summary.lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.chat_bubble_outline_rounded, size: 14, color: s.inkFaint),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(line.label,
                            style: AppTypography.bodySmall.copyWith(color: s.inkSecondary)),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(line.amount,
                          style: AppTypography.numericSmall
                              .copyWith(color: s.ink, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
            ],
          );
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('What ${request.site} says', style: AppTypography.sectionTitle),
          const SizedBox(height: AppSpacing.sm),
          body,
        ],
      );
    }
    return RailPanel(
      title: 'What ${request.site} says',
      rail: s.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          body,
          const SizedBox(height: AppSpacing.sm),
          Text(
            'The site\'s own words. Compare them with the two cards above: the '
            'figures there come from the transaction, and the site cannot change them.',
            style: AppTypography.caption.copyWith(color: s.inkFaint),
          ),
        ],
      ),
    );
  }
}

/// Request ids and addresses, for the technical fold.
class _RequestRows extends StatelessWidget {
  const _RequestRows({required this.request, required this.walletName});
  final ProtocolRequest request;
  final String walletName;

  @override
  Widget build(BuildContext context) {
    final req = request;
    return SummaryCard(
      title: 'Request',
      rows: [
        (label: 'Site', value: req.site, isMono: false),
        (label: 'Action', value: req.actionLabel, isMono: false),
        if (req.loanRef != null && req.loanRef!.isNotEmpty)
          (label: 'Loan', value: req.loanRef!, isMono: true),
        (label: 'Request id', value: req.id ?? '', isMono: true),
        (label: 'Network', value: protocolNetworkLabel(req.network), isMono: false),
        (label: 'Wallet', value: walletName, isMono: false),
        (label: 'Callback', value: req.callback.toString(), isMono: true),
        (label: 'Expires', value: req.expiresAtTime.toLocal().toString(), isMono: false),
      ],
    );
  }
}

/// Every input and output as the wallet reads them — outpoints, keys,
/// signatures, addresses. The evidence behind the cards above.
class _RawReading extends StatelessWidget {
  const _RawReading({required this.inspection, required this.walletName});
  final PsetInspection inspection;
  final String walletName;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final i = inspection;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('What "$walletName" reads', style: AppTypography.sectionTitle),
        const SizedBox(height: AppSpacing.sm),
        Text('Inputs (${i.inputs.length})', style: AppTypography.label.copyWith(color: s.inkSecondary)),
        const SizedBox(height: AppSpacing.sm),
        for (final inp in i.inputs)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: DataWell(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      TagChip(
                        label: inp.isOurs
                            ? (inp.isScriptHash ? 'escrow · your key' : 'your coin')
                            : (inp.isScriptHash ? 'contract · not yours' : 'not yours'),
                        color: inp.isOurs ? s.liquid : s.inkFaint,
                      ),
                      const Spacer(),
                      Text(
                        inp.displayAmount ??
                            (inp.ticker != null ? 'blinded (${inp.ticker})' : 'blinded'),
                        style: AppTypography.numericSmall.copyWith(
                          fontWeight: FontWeight.w700,
                          color: s.ink,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  KvRow(label: 'Outpoint', value: inp.outpoint),
                  if (inp.keyFingerprints.isNotEmpty)
                    KvRow(label: 'Keys', value: inp.keyFingerprints.join(', ')),
                  if (inp.signedBy.isNotEmpty)
                    KvRow(label: 'Signed by', value: inp.signedBy.join(', ')),
                ],
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        Text('Outputs (${i.outputs.length})', style: AppTypography.label.copyWith(color: s.inkSecondary)),
        const SizedBox(height: AppSpacing.sm),
        for (final out in i.outputs)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: DataWell(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      TagChip(
                        label: out.kindLabel,
                        color: out.isOwn
                            ? s.liquid
                            : out.isEscrow
                                ? s.accent
                                : out.isFee
                                    ? s.inkFaint
                                    : AppColors.warning,
                      ),
                      const Spacer(),
                      Text(
                        out.displayAmount ??
                            (out.ticker != null ? 'blinded (${out.ticker})' : 'blinded'),
                        style: AppTypography.numericSmall.copyWith(
                          fontWeight: FontWeight.w700,
                          color: s.ink,
                        ),
                      ),
                    ],
                  ),
                  if (out.address != null) ...[
                    const SizedBox(height: AppSpacing.xs),
                    KvRow(label: 'Address', value: out.address!),
                  ],
                ],
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        KvRow(label: 'Fee', value: i.feeDisplay),
        KvRow(label: 'Network', value: protocolNetworkLabel(i.network)),
        KvRow(
          label: 'Signatures',
          value: '${i.sigsHave} of ${i.sigsNeeded} on the least-signed input',
        ),
      ],
    );
  }
}

/// The proof of key as the user must see it (§9.5): the statement, the
/// site, the expiry, the wallet and its key, and the challenge line itself,
/// verbatim — it is what gets hashed into the check.
class _ProofCard extends StatelessWidget {
  const _ProofCard({
    required this.challenge,
    required this.origin,
    required this.expiresAt,
    required this.walletName,
    required this.keyFingerprint,
    required this.title,
    this.body,
  });
  final String challenge;
  final String origin;
  final DateTime expiresAt;
  final String walletName;
  final String keyFingerprint;
  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final left = expiresAt.difference(DateTime.now().toUtc());
    final expires = left.isNegative
        ? 'expired'
        : left.inMinutes >= 1
            ? 'in ${left.inMinutes} min'
            : 'in under a minute';
    return FormCard(
      title: title,
      subtitle: body,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.verified_user_outlined, size: 18, color: s.liquid),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  '$kProtocolProofStatement.',
                  key: const Key('protocol-proof-statement'),
                  style: AppTypography.body.copyWith(color: s.ink, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          KvRow(label: 'Site', value: origin, labelWidth: 96),
          KvRow(
            label: 'Expires',
            value: '$expires · ${expiresAt.toLocal()}',
            labelWidth: 96,
          ),
          KvRow(label: 'Wallet', value: walletName, labelWidth: 96),
          if (keyFingerprint.isNotEmpty)
            KvRow(label: 'Loan key', value: keyFingerprint, labelWidth: 96),
          const SizedBox(height: AppSpacing.md),
          CodeBox(label: 'Challenge, as the site sent it', value: challenge),
        ],
      ),
    );
  }
}

class _LockedCard extends StatelessWidget {
  const _LockedCard({required this.onUnlock});
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    return FormCard(
      title: 'Wallet storage is locked',
      subtitle: 'Enter your app passphrase to read the request and choose a wallet.',
      child: PrimaryButton(label: 'Unlock', icon: Icons.lock_open_outlined, onPressed: onUnlock),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.message,
    this.onRetry,
    this.onOpenSite,
    this.siteName,
  });
  final String message;
  final VoidCallback? onRetry;

  /// Opens the site in the browser. A refused request is often one the site
  /// must hand out again — a token is single use, and the one fetched before
  /// a network switch is spent — so "Try again" alone can only fail twice.
  final VoidCallback? onOpenSite;
  final String? siteName;

  @override
  Widget build(BuildContext context) {
    final phone = AppLayout.isPhone(context);
    final buttons = <Widget>[
      if (onOpenSite != null)
        PrimaryButton(
          label: siteName == null ? 'Open the site' : 'Open $siteName',
          icon: Icons.open_in_new,
          onPressed: onOpenSite,
          isFullWidth: phone,
        ),
      if (onRetry != null)
        SecondaryButton(
          label: 'Try again',
          icon: Icons.refresh,
          onPressed: onRetry,
          isFullWidth: phone,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DangerBanner(title: 'Request refused', message: message),
        if (buttons.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          if (phone)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final b in buttons) ...[
                  b,
                  if (b != buttons.last) const SizedBox(height: AppSpacing.md),
                ],
              ],
            )
          else
            Row(
              children: [
                for (final b in buttons) ...[
                  b,
                  if (b != buttons.last) const SizedBox(width: AppSpacing.md),
                ],
              ],
            ),
        ],
      ],
    );
  }
}

/// Which wallet answers. Always shown, never skipped: the one this site
/// already knows leads (a signing request from a site is almost always for
/// the wallet that site connected), then the preferred one, then the open
/// one; the rest follow. Wallets that cannot take part are listed dimmed
/// with the reason, so nothing seems to have vanished.
class _WalletChoice extends StatelessWidget {
  const _WalletChoice({
    required this.wallets,
    required this.eligible,
    required this.connect,
    required this.siteName,
    required this.onPick,
    required this.connectedWalletIds,
    this.preferredWalletId,
    this.activeWalletId,
  });
  final List<WalletSummary> wallets;
  final bool Function(WalletSummary) eligible;
  final bool connect;
  final String siteName;
  final void Function(WalletSummary) onPick;

  /// Wallets this device connected to the requesting site before.
  final Set<String> connectedWalletIds;

  /// Settings › Templar Protocol's choice, when it can answer this request.
  final String? preferredWalletId;
  final String? activeWalletId;

  int _rank(WalletSummary w) {
    if (connectedWalletIds.contains(w.id)) return 0;
    if (w.id == preferredWalletId) return 1;
    if (w.id == activeWalletId) return 2;
    return 3;
  }

  static String _whyNot(WalletSummary w) {
    if (!w.liquidEnabled) return 'no Liquid side';
    if (w.isViewOnlyWallet) return 'watch-only, cannot sign';
    if (w.isAirgapWallet) return 'air-gapped signer';
    if (w.type != WalletType.singlesig) return 'multisig or policy wallet';
    if (w.isHardwareWallet) return 'device is not a Jade';
    return 'not usable here';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final usable = wallets.where(eligible).toList()
      ..sort((a, b) {
        final r = _rank(a).compareTo(_rank(b));
        return r != 0 ? r : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final others = wallets.where((w) => !eligible(w)).toList();
    final hasConnected = usable.any((w) => connectedWalletIds.contains(w.id));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ActionHeader(
          icon: connect ? Icons.link_rounded : Icons.draw_outlined,
          tint: s.liquid,
          title: connect
              ? 'Which wallet should $siteName know?'
              : 'Which wallet signs for $siteName?',
          subtitle: connect
              ? 'The site will watch this wallet and use its loan key in your loans. '
                  'A software seed or a Jade, with Liquid enabled.'
              : hasConnected
                  ? 'The wallet this site connected is first — a signing request from '
                      'a site is for the wallet that site knows. Pick another only if '
                      'you connected this site elsewhere.'
                  : 'Pick the wallet whose key took part in this loan. This device has '
                      'not connected $siteName yet, so none is marked.',
          chips: [
            TagChip(
              label: '${usable.length} usable',
              color: usable.isEmpty ? s.danger : s.liquid,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        if (usable.isEmpty)
          const WarningBanner(
            message: 'No wallet qualifies. Create or restore a software wallet with '
                'Liquid enabled (or import a Jade), then open the link again.',
          )
        else
          ListCard(
            children: [
              for (final w in usable)
                _WalletRow(
                  wallet: w,
                  connected: connectedWalletIds.contains(w.id),
                  preferred: w.id == preferredWalletId,
                  open: w.id == activeWalletId,
                  onTap: () => onPick(w),
                ),
            ],
          ),
        if (others.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          Text('NOT USABLE HERE',
              style: AppTypography.navSection.copyWith(color: s.inkFaint, letterSpacing: 1.2)),
          const SizedBox(height: AppSpacing.sm),
          Opacity(
            opacity: 0.7,
            child: ListCard(
              children: [
                for (final w in others)
                  ListRow(
                    icon: w.isHardwareWallet ? Icons.usb_rounded : Icons.account_balance_wallet_outlined,
                    tint: s.inkFaint,
                    title: w.name,
                    subtitle: '${w.displayType} · ${_whyNot(w)}',
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _WalletRow extends StatelessWidget {
  const _WalletRow({
    required this.wallet,
    required this.connected,
    required this.preferred,
    required this.open,
    required this.onTap,
  });
  final WalletSummary wallet;
  final bool connected;
  final bool preferred;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final w = wallet;
    final badges = <Widget>[
      if (connected)
        const StatusBadge(label: 'Connected to this site', variant: BadgeVariant.accent, dot: true),
      if (preferred)
        const StatusBadge(label: 'Preferred', variant: BadgeVariant.success),
      if (open)
        const StatusBadge(label: 'Open now', variant: BadgeVariant.neutral),
    ];
    return Semantics(
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: Key('protocol-wallet-${w.id}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: kListPad, vertical: AppSpacing.md),
            child: Row(
              children: [
                ListIconTile(
                  icon: w.isHardwareWallet ? Icons.usb_rounded : Icons.key_rounded,
                  tint: connected ? s.accent : s.liquid,
                ),
                const SizedBox(width: kListGap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(w.name,
                          style: AppTypography.body.copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: s.ink,
                          )),
                      const SizedBox(height: 2),
                      Text(
                        '${w.displayType} · ${w.networksLabel}'
                        '${w.masterFingerprint != null ? ' · ${w.masterFingerprint}' : ''}',
                        style: AppTypography.caption.copyWith(color: s.inkSecondary),
                      ),
                      if (badges.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Wrap(spacing: AppSpacing.xs, runSpacing: AppSpacing.xs, children: badges),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Icon(Icons.chevron_right_rounded, size: 22, color: s.inkFaint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DoneCard extends StatelessWidget {
  const _DoneCard({
    required this.site,
    required this.connect,
    required this.next,
    required this.onOpen,
    required this.onClose,
    this.onOpenLoans,
  });
  final String site;
  final bool connect;
  final String? next;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  /// Set when the Loans page is in the menu: the natural next place after a
  /// connect, where the site's loans show up.
  final VoidCallback? onOpenLoans;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final buttons = <Widget>[
      if (next != null)
        PrimaryButton(label: 'Open in browser', icon: Icons.open_in_new, onPressed: onOpen),
      if (onOpenLoans != null)
        SecondaryButton(label: 'Open Loans', icon: Icons.handshake_outlined, onPressed: onOpenLoans),
      SecondaryButton(label: 'Back to wallet', onPressed: onClose),
    ];
    return FormCard(
      title: connect ? 'Wallet connected' : 'Signature sent',
      subtitle: connect
          ? '$site now watches this wallet and holds its escrow key. Every signing step for your loans will open here.'
          : '$site received the signature. It broadcasts once every party has signed; check the loan page for the transaction id.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_outline, color: AppColors.success, size: 22),
              const SizedBox(width: AppSpacing.sm),
              Text('Done', style: AppTypography.sectionTitle.copyWith(color: s.ink)),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          if (phone)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < buttons.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppSpacing.sm),
                  buttons[i],
                ],
              ],
            )
          else
            Wrap(spacing: AppSpacing.md, runSpacing: AppSpacing.sm, children: buttons),
        ],
      ),
    );
  }
}
