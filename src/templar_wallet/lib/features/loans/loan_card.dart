// One loan as a tile on the Loans screen: who you are in it and where it
// stands, what the site expects next, how much of the term has run, where
// the money sits, and the one or two things you can do from here.
//
// The card is pure presentation over `ProtocolLoan`: it never fetches and
// never signs. "Sign now" hands the loan's `templar://sign` link back to the
// screen, which feeds it to the app's own link handler — the same path a
// link from the browser takes, with the same review and the same gate.
//
// Reading order, top to bottom: the glyph says the role (money coming to
// you, or going out as a lender), the ring says how far the term has run,
// the chips say the state; the next line is the site's own «what happens
// now»; the flow strip shows collateral, principal and what closes the loan
// as arrows between you, the escrow and the other party; the amounts follow.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../shared/widgets/badges.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/code_box.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/list_rows.dart';
import '../../shared/widgets/privacy.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../protocol/models/protocol_portfolio.dart';

class LoanCard extends StatefulWidget {
  const LoanCard({
    super.key,
    required this.loan,
    required this.tipHeight,
    this.onSign,
    this.onOpen,
    this.busy = false,
    this.now,
  });

  final ProtocolLoan loan;

  /// The site's chain tip when the portfolio was computed — the ring's "now".
  final int tipHeight;

  /// Called with the pending request when "Sign now" is pressed. Null hides
  /// the button even if a request is pending (a closed site, say).
  final void Function(ProtocolPendingRequest request)? onSign;

  /// "Open on Templar Protocol" for this loan.
  final VoidCallback? onOpen;

  /// An open link is being fetched: the buttons wait.
  final bool busy;

  /// Injectable clock, for the expiry line in tests.
  final DateTime? now;

  @override
  State<LoanCard> createState() => _LoanCardState();
}

class _LoanCardState extends State<LoanCard> {
  bool _details = false;

  ProtocolLoan get loan => widget.loan;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final pad = phone ? AppSpacing.cardPaddingSmall : AppSpacing.cardPadding;
    final pending = loan.pendingRequest;
    final next = loan.nextAction;
    final open = loan.state.isOpen;

    return Container(
      key: Key('loan-card-${loan.id}'),
      decoration: BoxDecoration(
        color: s.surfaceGlass,
        borderRadius: BorderRadius.circular(
            phone ? AppSpacing.radiusLg : AppSpacing.radiusMd),
        border: Border.all(
          // A waiting signature is the one thing on this screen the user has
          // to act on; its card says so at the edge, not with a wash.
          color: pending != null ? s.accent.withValues(alpha: 0.6) : s.edge,
        ),
        boxShadow: s.panelShadow,
      ),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TitleRow(loan: loan, tipHeight: widget.tipHeight),
            if (next != null && next.label.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              _NextLine(action: next, pending: pending, now: widget.now),
            ],
            if (open) ...[
              const SizedBox(height: AppSpacing.md),
              _TermBar(loan: loan, tipHeight: widget.tipHeight),
            ],
            const SizedBox(height: AppSpacing.md),
            _FlowStrip(loan: loan),
            const SizedBox(height: AppSpacing.md),
            Divider(height: 1, color: s.edge),
            const SizedBox(height: AppSpacing.sm),
            _Amounts(loan: loan),
            if (_details) ...[
              const SizedBox(height: AppSpacing.md),
              _Details(loan: loan),
            ],
            const SizedBox(height: AppSpacing.md),
            _Actions(
              loan: loan,
              phone: phone,
              busy: widget.busy,
              details: _details,
              onToggleDetails: () => setState(() => _details = !_details),
              onSign: widget.onSign == null || pending == null
                  ? null
                  : () => widget.onSign!(pending),
              onOpen: widget.onOpen,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Pieces ────────────────────────────────────────────────────────────────────

/// Glyph · reference · role and state chips · the term ring.
class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.loan, required this.tipHeight});
  final ProtocolLoan loan;
  final int tipHeight;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final lender = loan.role == 'lender';
    final stateColor = loanStateColor(s, loan.state);
    final progress = loan.termProgress(tipHeight);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Money comes to a borrower and leaves a lender: the arrow says
        // which, the hue says it is a Liquid thing.
        ListIconTile(
          icon: lender ? Icons.call_made_rounded : Icons.call_received_rounded,
          tint: lender ? s.accent : s.liquid,
        ),
        const SizedBox(width: kListGap),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(loan.ref,
                      style: AppTypography.sectionTitleOf(context)
                          .copyWith(color: s.ink)),
                  const SizedBox(width: AppSpacing.sm),
                  TagChip(label: loan.stateLabel, color: stateColor),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                lender ? 'You are the lender' : 'You are the borrower',
                style: AppTypography.caption.copyWith(color: s.inkSecondary),
              ),
            ],
          ),
        ),
        if (loan.pendingRequest != null) ...[
          const StatusBadge(
            label: 'Your signature',
            variant: BadgeVariant.accent,
            dot: true,
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
        if (loan.state.isOpen)
          _TermRing(
            progress: progress,
            label: progress == null
                ? '—'
                : '${(progress * 100).round()}%',
            color: progress != null && progress >= 1 ? s.warning : s.liquid,
          ),
      ],
    );
  }
}

/// The chip colour of a loan state, shared with the Loans screen's summary.
Color loanStateColor(AppScheme s, ProtocolLoanState state) => switch (state) {
      ProtocolLoanState.originating => s.warning,
      ProtocolLoanState.active => s.liquid,
      ProtocolLoanState.repaid => s.success,
      ProtocolLoanState.defaulted => s.danger,
      ProtocolLoanState.liquidated => s.danger,
      ProtocolLoanState.unknown => s.inkFaint,
    };

/// A small ring: how much of the term has run, as the one glance figure.
class _TermRing extends StatelessWidget {
  const _TermRing({required this.progress, required this.label, required this.color});
  final double? progress;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Tooltip(
      message: progress == null
          ? 'The term has not started yet'
          : 'Term run: ${(progress! * 100).round()}%',
      child: SizedBox(
        width: 44,
        height: 44,
        child: CustomPaint(
          painter: _RingPainter(
            progress: progress ?? 0,
            track: s.panelInset,
            fill: color,
          ),
          child: Center(
            child: Text(
              label,
              style: AppTypography.caption.copyWith(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: s.inkSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.progress, required this.track, required this.fill});
  final double progress;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 4.0;
    final rect = Offset.zero & size;
    final r = rect.deflate(stroke / 2);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(r, 0, math.pi * 2, false, base);
    if (progress > 0) {
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = fill;
      canvas.drawArc(r, -math.pi / 2, math.pi * 2 * progress.clamp(0.0, 1.0), false, p);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.track != track || old.fill != fill;
}

/// The site's one-line «what happens now», with a glyph for its kind.
class _NextLine extends StatelessWidget {
  const _NextLine({required this.action, required this.pending, this.now});
  final ProtocolNextAction action;
  final ProtocolPendingRequest? pending;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final (icon, tint) = switch (action.kind) {
      ProtocolNextKind.sign => (Icons.draw_outlined, s.accent),
      ProtocolNextKind.repay => (Icons.payments_outlined, s.liquid),
      ProtocolNextKind.claim => (Icons.gavel_outlined, s.warning),
      ProtocolNextKind.wait => (Icons.hourglass_empty_rounded, s.inkSecondary),
      ProtocolNextKind.none => (Icons.check_circle_outline, s.inkFaint),
      ProtocolNextKind.unknown => (Icons.help_outline, s.inkSecondary),
    };
    final p = pending;
    String? expiry;
    if (p?.expiresAt != null) {
      final ref = (now ?? DateTime.now()).toUtc();
      final left = p!.expiresAt!.difference(ref);
      expiry = left.isNegative
          ? 'request expired — the site will issue a new one'
          : left.inMinutes >= 1
              ? 'request expires in ${left.inMinutes} min'
              : 'request expires in under a minute';
    }
    return DataWell(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 18, color: tint),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(action.label,
                    style: AppTypography.body
                        .copyWith(color: s.ink, fontWeight: FontWeight.w600)),
                if (expiry != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${protocolActionLabel(p!.action)} · $expiry',
                      style: AppTypography.caption.copyWith(color: s.inkSecondary),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// How much of the term has run, in blocks, with the time it stands for.
class _TermBar extends StatelessWidget {
  const _TermBar({required this.loan, required this.tipHeight});
  final ProtocolLoan loan;
  final int tipHeight;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final progress = loan.termProgress(tipHeight);
    final left = protocolBlocksLeftLabel(loan.blocksLeft);
    final due = loan.dueAtEstimate;
    final start = loan.startHeight;
    final term = loan.termHeight;

    final leftText = progress == null
        ? (loan.state == ProtocolLoanState.originating
            ? 'Term starts when the opening transaction confirms'
            : 'No term yet')
        : 'Block ${_g(start)} → ${_g(term)}';
    final rightText = [
      if (left.isNotEmpty) left,
      if (due != null) 'due ≈ ${_localShort(due)}',
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.schedule_rounded, size: 14, color: s.inkFaint),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text(leftText,
                  style: AppTypography.caption.copyWith(color: s.inkFaint),
                  overflow: TextOverflow.ellipsis),
            ),
            if (rightText.isNotEmpty) ...[
              const SizedBox(width: AppSpacing.sm),
              Text(rightText,
                  key: const Key('loan-time-left'),
                  style: AppTypography.caption.copyWith(
                    color: progress != null && progress >= 1
                        ? s.warning
                        : s.inkSecondary,
                    fontWeight: FontWeight.w600,
                  )),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 6,
            child: Stack(
              children: [
                Container(color: s.panelInset),
                if (progress != null)
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: progress == 0 ? 0.004 : progress,
                    child: Container(
                      color: progress >= 1 ? s.warning : s.liquid,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static String _g(int? n) => n == null ? '—' : protocolGroupDigits('$n');
}

/// Where the money sits, as arrows: collateral into the escrow, principal
/// to the borrower, what closes the loan back to the lender. Read from the
/// role, so a lender and a borrower see the same loan from their own side.
class _FlowStrip extends StatelessWidget {
  const _FlowStrip({required this.loan});
  final ProtocolLoan loan;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final lender = loan.role == 'lender';
    final you = 'You';
    final other = lender ? 'Borrower' : 'Lender';
    final closed = !loan.state.isOpen;
    final rows = <_FlowRowData>[
      if (loan.collateral != null)
        _FlowRowData(
          icon: Icons.lock_outline_rounded,
          tint: s.warning,
          from: lender ? other : you,
          to: 'Escrow',
          what: 'Collateral',
          amount: loan.collateral!.display,
          done: loan.state != ProtocolLoanState.originating,
        ),
      if (loan.principal != null)
        _FlowRowData(
          icon: Icons.payments_outlined,
          tint: s.liquid,
          from: lender ? you : other,
          to: lender ? other : you,
          what: 'Principal',
          amount: loan.principal!.display,
          done: loan.state != ProtocolLoanState.originating,
        ),
      if (loan.owed != null && !closed)
        _FlowRowData(
          icon: Icons.undo_rounded,
          tint: s.accent,
          from: lender ? other : you,
          to: lender ? you : other,
          what: lender ? 'Repayment due' : 'To repay',
          amount: loan.owed!.display,
          done: false,
        ),
      if (closed && loan.state == ProtocolLoanState.repaid && loan.owed != null)
        _FlowRowData(
          icon: Icons.check_rounded,
          tint: s.success,
          from: lender ? other : you,
          to: lender ? you : other,
          what: 'Repaid',
          amount: loan.principal?.display ?? '',
          done: true,
        ),
      if (closed &&
          (loan.state == ProtocolLoanState.liquidated ||
              loan.state == ProtocolLoanState.defaulted) &&
          loan.collateral != null)
        _FlowRowData(
          icon: Icons.gavel_outlined,
          tint: s.danger,
          from: 'Escrow',
          to: lender ? you : other,
          what: 'Collateral claimed',
          amount: loan.collateral!.display,
          done: true,
        ),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.xs),
          _FlowRow(data: rows[i]),
        ],
      ],
    );
  }
}

class _FlowRowData {
  const _FlowRowData({
    required this.icon,
    required this.tint,
    required this.from,
    required this.to,
    required this.what,
    required this.amount,
    required this.done,
  });
  final IconData icon;
  final Color tint;
  final String from;
  final String to;
  final String what;
  final String amount;

  /// Already happened on chain (solid) or still ahead (dashed look).
  final bool done;
}

class _FlowRow extends StatelessWidget {
  const _FlowRow({required this.data});
  final _FlowRowData data;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final d = data;
    final faint = AppTypography.caption.copyWith(color: s.inkFaint);
    final party = AppTypography.caption.copyWith(
      color: s.ink,
      fontWeight: FontWeight.w600,
    );
    return Row(
      children: [
        ListIconTile(icon: d.icon, tint: d.tint, size: 28),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(d.what, style: faint),
              Row(
                children: [
                  Text(d.from, style: party),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(
                      d.done ? Icons.arrow_forward_rounded : Icons.arrow_right_alt_rounded,
                      size: 16,
                      color: d.done ? d.tint : s.inkFaint,
                    ),
                  ),
                  Text(d.to, style: party),
                  if (!d.done) ...[
                    const SizedBox(width: AppSpacing.xs),
                    Text('pending', style: faint),
                  ],
                ],
              ),
            ],
          ),
        ),
        Amount(
          d.amount,
          style: AppTypography.numericSmall.copyWith(
            color: s.ink,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// Owed first and largest; interest and the Templar fee as a quiet grid.
class _Amounts extends StatelessWidget {
  const _Amounts({required this.loan});
  final ProtocolLoan loan;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final owed = loan.owed;
    final rows = <(String, String)>[
      if (loan.principal != null) ('Principal', loan.principal!.display),
      if (loan.collateral != null) ('Collateral', loan.collateral!.display),
      if (loan.interest != null)
        (
          'Interest',
          '${loan.interest!.display}'
              '${loan.interest!.rateBps != null ? ' · ${protocolBpsLabel(loan.interest!.rateBps!)}' : ''}'
        ),
      if (loan.templarFee != null)
        (
          'Templar fee',
          '${loan.templarFee!.display}'
              '${(loan.templarFee!.payer ?? '').isNotEmpty ? ' · paid by ${loan.templarFee!.payer}' : ''}'
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (owed != null && loan.state.isOpen)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  loan.role == 'lender' ? 'OWED TO YOU' : 'YOU OWE',
                  style: AppTypography.navSection
                      .copyWith(color: s.inkFaint, letterSpacing: 1.2),
                ),
                const Spacer(),
                Amount(
                  protocolGroupDigits(owed.amount),
                  style: AppTypography.numericLarge.copyWith(
                    color: s.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                Text(owed.ticker,
                    style: AppTypography.caption.copyWith(color: s.inkSecondary)),
              ],
            ),
          ),
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 96,
                  child: Text(label,
                      style:
                          AppTypography.caption.copyWith(color: s.inkSecondary)),
                ),
                Expanded(
                  child: Amount(
                    value,
                    textAlign: TextAlign.end,
                    style: AppTypography.numericSmall.copyWith(color: s.ink),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Escrow address and transaction ids: the facts someone checks against an
/// explorer, folded until asked for.
class _Details extends StatelessWidget {
  const _Details({required this.loan});
  final ProtocolLoan loan;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final tx = loan.txids;
    final rows = <(String, String)>[
      if ((loan.escrowAddress ?? '').isNotEmpty) ('Escrow', loan.escrowAddress!),
      if ((tx.origination ?? '').isNotEmpty) ('Opened in', tx.origination!),
      if ((tx.repayment ?? '').isNotEmpty) ('Repaid in', tx.repayment!),
      if ((tx.liquidation ?? '').isNotEmpty) ('Liquidated in', tx.liquidation!),
      if (loan.openedAt != null) ('Opened', _localShort(loan.openedAt!)),
    ];
    if (rows.isEmpty) {
      return Text('The site sent no details for this loan yet.',
          style: AppTypography.caption.copyWith(color: s.inkSecondary));
    }
    return DataWell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: AppSpacing.md, color: s.edge),
            CopyRow(label: rows[i].$1, value: rows[i].$2, mono: rows[i].$1 != 'Opened'),
          ],
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.loan,
    required this.phone,
    required this.busy,
    required this.details,
    required this.onToggleDetails,
    this.onSign,
    this.onOpen,
  });
  final ProtocolLoan loan;
  final bool phone;
  final bool busy;
  final bool details;
  final VoidCallback onToggleDetails;
  final VoidCallback? onSign;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final sign = onSign == null
        ? null
        : PrimaryButton(
            key: Key('loan-sign-${loan.id}'),
            label: 'Sign now',
            icon: Icons.draw_outlined,
            onPressed: busy ? null : onSign,
            isFullWidth: phone,
          );
    final open = onOpen == null
        ? null
        : SecondaryButton(
            key: Key('loan-open-${loan.id}'),
            label: 'Open on Templar Protocol',
            icon: Icons.open_in_new,
            onPressed: busy ? null : onOpen,
            isLoading: busy,
            isFullWidth: phone,
          );
    final more = GhostButton(
      key: Key('loan-details-${loan.id}'),
      label: details ? 'Hide details' : 'Details',
      icon: details ? Icons.expand_less_rounded : Icons.expand_more_rounded,
      onPressed: onToggleDetails,
      isFullWidth: phone,
    );
    final buttons = <Widget>[?sign, ?open, more];
    if (phone) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.sm),
            buttons[i],
          ],
        ],
      );
    }
    return Row(
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          if (i > 0) const SizedBox(width: AppSpacing.sm),
          if (i == buttons.length - 1) const Spacer(),
          buttons[i],
        ],
      ],
    );
  }
}

/// `3 Oct, 14:32` in the local zone — enough to recognise a day and an hour.
String _localShort(DateTime t) {
  final l = t.toLocal();
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final hh = l.hour.toString().padLeft(2, '0');
  final mm = l.minute.toString().padLeft(2, '0');
  final now = DateTime.now();
  final year = l.year == now.year ? '' : ' ${l.year}';
  return '${l.day} ${months[l.month - 1]}$year, $hh:$mm';
}
