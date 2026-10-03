/// The wallet's loans as a Templar Protocol site reports them —
/// `GET /connector/portfolio`, `docs/connector-protocol.md` §7 in the Templar
/// Protocol repository.
///
/// Pure Dart, no bridge, no network: the Loans screen renders exactly what
/// is here, and the tests can feed it the contract's JSON. Field names are
/// the contract's. Two rules keep the model honest about a site that moves
/// faster than the app:
///
///   * a `state` or a `kind` this build does not know is kept as text and
///     rendered as such — never dropped, never guessed into a known one;
///   * every amount and height is optional, and a loan missing one still
///     renders (with that line absent) rather than throwing the page away.
///
/// Nothing in here is persisted: the portfolio is fetched on open and on
/// Refresh and lives in memory only. The site is the ledger.
library;

export 'protocol_link.dart' show protocolActionLabel;

/// `state` of a loan on the site. [unknown] carries the raw text.
enum ProtocolLoanState {
  originating,
  active,
  repaid,
  defaulted,
  liquidated,
  unknown;

  static ProtocolLoanState parse(String raw) => switch (raw.trim()) {
        'originating' => originating,
        'active' => active,
        'repaid' => repaid,
        'defaulted' => defaulted,
        'liquidated' => liquidated,
        _ => unknown,
      };

  /// Still running: the card sits in the main list and has a time bar.
  bool get isOpen => this == originating || this == active;
}

/// `next_action.kind`: what the site expects from this wallet now.
enum ProtocolNextKind {
  sign,
  repay,
  claim,
  wait,
  none,
  unknown;

  static ProtocolNextKind parse(String raw) => switch (raw.trim()) {
        'sign' => sign,
        'repay' => repay,
        'claim' => claim,
        'wait' => wait,
        'none' => none,
        _ => unknown,
      };
}

/// One amount as the site writes it: whole coins as text (English format,
/// no separators) plus base units and the ticker. The text is what the card
/// shows; the base units are for arithmetic nobody does yet.
class ProtocolMoney {
  const ProtocolMoney({
    required this.ticker,
    required this.amount,
    this.sats,
    this.asset,
    this.rateBps,
    this.payer,
  });

  final String ticker;

  /// `"10000"`, `"0.5"` — as sent; [display] adds the thousands separators.
  final String amount;
  final int? sats;

  /// Asset id, hex; present on principal and collateral.
  final String? asset;

  /// `interest` only: the nominal rate.
  final int? rateBps;

  /// `templar_fee` only: `borrower` | `lender`.
  final String? payer;

  /// `10,000 rUSDt` — grouped integer part, decimals untouched.
  String get display => '${protocolGroupDigits(amount)} $ticker';

  static ProtocolMoney? fromJson(Object? v) {
    if (v is! Map) return null;
    final ticker = _str(v['ticker']);
    final amount = _str(v['amount']);
    if (ticker.isEmpty && amount.isEmpty) return null;
    return ProtocolMoney(
      ticker: ticker,
      amount: amount,
      sats: _int(v['sats']),
      asset: _strOrNull(v['asset']),
      rateBps: _int(v['rate_bps']),
      payer: _strOrNull(v['payer']),
    );
  }
}

/// `next_action`: the one line the dashboard leads with, and where it goes.
class ProtocolNextAction {
  const ProtocolNextAction({
    required this.kind,
    required this.rawKind,
    required this.label,
    this.url,
  });

  final ProtocolNextKind kind;

  /// The site's own word, kept for an [ProtocolNextKind.unknown] kind.
  final String rawKind;
  final String label;
  final Uri? url;

  static ProtocolNextAction? fromJson(Object? v) {
    if (v is! Map) return null;
    final raw = _str(v['kind']);
    return ProtocolNextAction(
      kind: ProtocolNextKind.parse(raw),
      rawKind: raw,
      label: _str(v['label']),
      url: _uri(v['url']),
    );
  }
}

/// `pending_request`: a signature of this wallet the site is waiting for.
class ProtocolPendingRequest {
  const ProtocolPendingRequest({
    required this.id,
    required this.action,
    required this.link,
    this.expiresAt,
  });

  final String id;

  /// `origination` | `repayment` | … — the sign request's action.
  final String action;

  /// The `templar://sign?…` link, opened in-app.
  final Uri link;
  final DateTime? expiresAt;

  bool isExpired({DateTime? now}) {
    final e = expiresAt;
    if (e == null) return false;
    return !e.isAfter((now ?? DateTime.now()).toUtc());
  }

  static ProtocolPendingRequest? fromJson(Object? v) {
    if (v is! Map) return null;
    final link = _uri(v['link']);
    if (link == null || link.scheme.toLowerCase() != 'templar') return null;
    return ProtocolPendingRequest(
      id: _str(v['id']),
      action: _str(v['action']),
      link: link,
      expiresAt: _time(v['expires_at']),
    );
  }
}

/// `txids`: the transactions the loan has produced so far, by step.
class ProtocolLoanTxids {
  const ProtocolLoanTxids({this.origination, this.repayment, this.liquidation});
  final String? origination;
  final String? repayment;
  final String? liquidation;

  static ProtocolLoanTxids fromJson(Object? v) {
    if (v is! Map) return const ProtocolLoanTxids();
    return ProtocolLoanTxids(
      origination: _strOrNull(v['origination']),
      repayment: _strOrNull(v['repayment']),
      liquidation: _strOrNull(v['liquidation']),
    );
  }
}

/// One loan of this wallet.
class ProtocolLoan {
  const ProtocolLoan({
    required this.id,
    required this.ref,
    required this.role,
    required this.state,
    required this.rawState,
    this.principal,
    this.collateral,
    this.interest,
    this.templarFee,
    this.owed,
    this.openedAt,
    this.startHeight,
    this.termHeight,
    this.blocksLeft,
    this.dueAtEstimate,
    this.nextAction,
    this.pendingRequest,
    this.txids = const ProtocolLoanTxids(),
    this.escrowAddress,
  });

  final int id;

  /// `SQ-42`.
  final String ref;

  /// `borrower` | `lender`.
  final String role;
  final ProtocolLoanState state;

  /// The site's own word, shown when [state] is [ProtocolLoanState.unknown].
  final String rawState;

  final ProtocolMoney? principal;
  final ProtocolMoney? collateral;
  final ProtocolMoney? interest;
  final ProtocolMoney? templarFee;

  /// What closes the loan now; 0 once closed.
  final ProtocolMoney? owed;

  final DateTime? openedAt;
  final int? startHeight;
  final int? termHeight;

  /// `term_height − tip`, saturating; 0 once closed.
  final int? blocksLeft;
  final DateTime? dueAtEstimate;
  final ProtocolNextAction? nextAction;
  final ProtocolPendingRequest? pendingRequest;
  final ProtocolLoanTxids txids;
  final String? escrowAddress;

  /// The state as a chip label: the known word, or the site's own.
  String get stateLabel => state == ProtocolLoanState.unknown
      ? (rawState.isEmpty ? 'unknown' : rawState)
      : state.name;

  /// How far along the term the chain is, 0…1, from the heights the site
  /// sent and its tip. Null when the loan has no term yet (originating) or
  /// the heights do not describe one.
  double? termProgress(int tipHeight) =>
      protocolTermProgress(tipHeight, startHeight, termHeight);

  static ProtocolLoan? fromJson(Object? v) {
    if (v is! Map) return null;
    final id = _int(v['id']);
    if (id == null) return null;
    final rawState = _str(v['state']);
    return ProtocolLoan(
      id: id,
      ref: _str(v['ref']).isEmpty ? 'SQ-$id' : _str(v['ref']),
      role: _str(v['role']),
      state: ProtocolLoanState.parse(rawState),
      rawState: rawState,
      principal: ProtocolMoney.fromJson(v['principal']),
      collateral: ProtocolMoney.fromJson(v['collateral']),
      interest: ProtocolMoney.fromJson(v['interest']),
      templarFee: ProtocolMoney.fromJson(v['templar_fee']),
      owed: ProtocolMoney.fromJson(v['owed']),
      openedAt: _time(v['opened_at']),
      startHeight: _int(v['start_height']),
      termHeight: _int(v['term_height']),
      blocksLeft: _int(v['blocks_left']),
      dueAtEstimate: _time(v['due_at_estimate']),
      nextAction: ProtocolNextAction.fromJson(v['next_action']),
      pendingRequest: ProtocolPendingRequest.fromJson(v['pending_request']),
      txids: ProtocolLoanTxids.fromJson(v['txids']),
      escrowAddress: _strOrNull(v['escrow_address']),
    );
  }
}

/// One of this wallet's own offers on the site's market.
class ProtocolOffer {
  const ProtocolOffer({
    required this.id,
    required this.side,
    required this.state,
    this.principal,
    this.collateral,
    this.rateBps,
    this.durationBlocks,
    this.url,
  });

  final int id;

  /// `lend` | `borrow`.
  final String side;

  /// The offer status as the site names it (`open`, …).
  final String state;
  final ProtocolMoney? principal;
  final ProtocolMoney? collateral;
  final int? rateBps;
  final int? durationBlocks;
  final Uri? url;

  static ProtocolOffer? fromJson(Object? v) {
    if (v is! Map) return null;
    final id = _int(v['id']);
    if (id == null) return null;
    return ProtocolOffer(
      id: id,
      side: _str(v['side']),
      state: _str(v['state']),
      principal: ProtocolMoney.fromJson(v['principal']),
      collateral: ProtocolMoney.fromJson(v['collateral']),
      rateBps: _int(v['rate_bps']),
      durationBlocks: _int(v['duration_blocks']),
      url: _uri(v['url']),
    );
  }
}

/// `wallet`: how the site labels this wallet, and the loan key it knows.
class ProtocolPortfolioWallet {
  const ProtocolPortfolioWallet({required this.label, required this.escrowFingerprint});
  final String label;
  final String escrowFingerprint;
}

/// The whole answer.
class ProtocolPortfolio {
  const ProtocolPortfolio({
    required this.version,
    required this.site,
    required this.network,
    required this.tipHeight,
    required this.asOf,
    required this.wallet,
    required this.loans,
    required this.offers,
  });

  final int version;
  final String site;

  /// `liquid-testnet` | `liquid-regtest`.
  final String network;
  final int tipHeight;

  /// When the site computed this; shown so a stale screen says so.
  final DateTime asOf;
  final ProtocolPortfolioWallet wallet;
  final List<ProtocolLoan> loans;
  final List<ProtocolOffer> offers;

  /// Loans still running, pending signatures first, then by due date.
  List<ProtocolLoan> get openLoans {
    final out = loans.where((l) => l.state.isOpen).toList();
    out.sort((a, b) {
      final pa = a.pendingRequest != null ? 0 : 1;
      final pb = b.pendingRequest != null ? 0 : 1;
      if (pa != pb) return pa - pb;
      final da = a.blocksLeft ?? 1 << 30;
      final db = b.blocksLeft ?? 1 << 30;
      if (da != db) return da - db;
      return b.id - a.id;
    });
    return out;
  }

  /// Loans that ended, newest first.
  List<ProtocolLoan> get closedLoans {
    final out = loans.where((l) => !l.state.isOpen).toList();
    out.sort((a, b) => b.id - a.id);
    return out;
  }

  /// Signatures the site waits for, across every loan.
  int get pendingCount => loans.where((l) => l.pendingRequest != null).length;

  /// Decodes the §7 JSON. Throws [FormatException] only when the answer is
  /// not a portfolio at all (no `loans` array); everything inside is lenient.
  static ProtocolPortfolio fromJson(Map<String, dynamic> j) {
    final loansRaw = j['loans'];
    if (loansRaw is! List) {
      throw const FormatException('The portfolio answer has no "loans" list.');
    }
    final wallet = j['wallet'];
    return ProtocolPortfolio(
      version: _int(j['version']) ?? 1,
      site: _str(j['site']),
      network: _str(j['network']),
      tipHeight: _int(j['tip_height']) ?? 0,
      asOf: _time(j['as_of']) ?? DateTime.now().toUtc(),
      wallet: ProtocolPortfolioWallet(
        label: wallet is Map ? _str(wallet['label']) : '',
        escrowFingerprint: wallet is Map ? _str(wallet['escrow_fingerprint']) : '',
      ),
      loans: loansRaw.map(ProtocolLoan.fromJson).whereType<ProtocolLoan>().toList(),
      offers: (j['offers'] is List ? j['offers'] as List : const [])
          .map(ProtocolOffer.fromJson)
          .whereType<ProtocolOffer>()
          .toList(),
    );
  }
}

// ── Helpers the cards share ───────────────────────────────────────────────────

/// `(tip − start) / (term − start)`, clamped to 0…1; null when the heights
/// do not describe a term (missing, or term at or before start).
double? protocolTermProgress(int tipHeight, int? startHeight, int? termHeight) {
  if (startHeight == null || termHeight == null) return null;
  final span = termHeight - startHeight;
  if (span <= 0) return null;
  final done = (tipHeight - startHeight) / span;
  return done.clamp(0.0, 1.0).toDouble();
}

/// `blocks_left` as the time it stands for, one Liquid block being about a
/// minute: `≈ 3 d left`, `≈ 5 h left`, `≈ 50 min left`, or `term reached`
/// at zero. Null blocks give an empty string — the line is simply absent.
String protocolBlocksLeftLabel(int? blocksLeft) {
  if (blocksLeft == null) return '';
  if (blocksLeft <= 0) return 'term reached';
  final minutes = blocksLeft;
  if (minutes >= 2 * 24 * 60) return '≈ ${minutes ~/ (24 * 60)} d left';
  if (minutes >= 60) return '≈ ${minutes ~/ 60} h left';
  return '≈ $minutes min left';
}

/// `10000` → `10,000`; `0.5` stays; `1234567.89` → `1,234,567.89`. Only the
/// integer part is grouped, and anything that is not a plain number is
/// returned as it came.
String protocolGroupDigits(String amount) {
  final s = amount.trim();
  final m = RegExp(r'^(-?)(\d+)(\.\d+)?$').firstMatch(s);
  if (m == null) return s;
  final sign = m.group(1)!;
  final whole = m.group(2)!;
  final frac = m.group(3) ?? '';
  final buf = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    final fromEnd = whole.length - i;
    buf.write(whole[i]);
    if (fromEnd > 1 && fromEnd % 3 == 1) buf.write(',');
  }
  return '$sign$buf$frac';
}

/// `200` bps → `2%`, `250` → `2.5%`, `33` → `0.33%`.
String protocolBpsLabel(int bps) {
  final whole = bps ~/ 100;
  final rest = bps % 100;
  if (rest == 0) return '$whole%';
  final frac = rest.toString().padLeft(2, '0').replaceFirst(RegExp(r'0$'), '');
  return '$whole.$frac%';
}

String _str(Object? v) => v is String ? v.trim() : (v == null ? '' : v.toString());

String? _strOrNull(Object? v) {
  if (v is! String) return null;
  final s = v.trim();
  return s.isEmpty ? null : s;
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

/// Unix seconds → UTC time. Null for absent or non-numeric values.
DateTime? _time(Object? v) {
  final n = _int(v);
  if (n == null || n <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(n * 1000, isUtc: true);
}

Uri? _uri(Object? v) {
  if (v is! String || v.trim().isEmpty) return null;
  final u = Uri.tryParse(v.trim());
  if (u == null || !u.hasScheme) return null;
  return u;
}
