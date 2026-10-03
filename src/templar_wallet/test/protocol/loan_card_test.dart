// A loan card with a signature waiting: what it says, what it offers, and
// that "Sign now" hands back the loan's own templar:// link — nothing else.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:templar_wallet/app/app_state.dart';
import 'package:templar_wallet/features/loans/loan_card.dart';
import 'package:templar_wallet/features/protocol/models/protocol_portfolio.dart';
import 'package:templar_wallet/theme/app_theme.dart';

final Uri _link = Uri.parse(
    'templar://sign?url=https%3A%2F%2Fhost%2Fwallet%2Frequests%2Freq_1&nonce=abc');

ProtocolLoan _loan({
  ProtocolPendingRequest? pending,
  ProtocolLoanState state = ProtocolLoanState.active,
  int? blocksLeft = 50,
}) =>
    ProtocolLoan(
      id: 1,
      ref: 'SQ-1',
      role: 'borrower',
      state: state,
      rawState: state.name,
      principal: const ProtocolMoney(ticker: 'rUSDt', amount: '10000'),
      collateral: const ProtocolMoney(ticker: 'rLBTC', amount: '0.5'),
      interest: const ProtocolMoney(ticker: 'rUSDt', amount: '200', rateBps: 200),
      templarFee:
          const ProtocolMoney(ticker: 'rUSDt', amount: '50', payer: 'borrower'),
      owed: const ProtocolMoney(ticker: 'rUSDt', amount: '10200'),
      startHeight: 118,
      termHeight: 168,
      blocksLeft: blocksLeft,
      dueAtEstimate: DateTime.utc(2026, 10, 3, 6, 30),
      nextAction: ProtocolNextAction(
        kind: pending != null ? ProtocolNextKind.sign : ProtocolNextKind.repay,
        rawKind: pending != null ? 'sign' : 'repay',
        label: pending != null
            ? 'Sign the repayment of SQ-1'
            : 'Repay 10,200 rUSDt before ≈ 50 min',
        url: Uri.parse('https://host/loans/1'),
      ),
      pendingRequest: pending,
      txids: const ProtocolLoanTxids(origination: 'aa11'),
      escrowAddress: 'el1qqescrow',
    );

ProtocolPendingRequest _pending() => ProtocolPendingRequest(
      id: 'req_1',
      action: 'repayment',
      link: _link,
      expiresAt: DateTime.utc(2026, 10, 3, 9, 0),
    );

Widget _host(Widget child, {AppState? state}) => MaterialApp(
      theme: AppTheme.dark(),
      home: ChangeNotifierProvider<AppState>(
        create: (_) => state ?? AppState(),
        child: Scaffold(
          body: SingleChildScrollView(
            child: Padding(padding: const EdgeInsets.all(16), child: child),
          ),
        ),
      ),
    );

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  setUp(() {
    // AppState writes the privacy switch to prefs; without the mock the
    // write never completes and the test waits forever.
    SharedPreferences.setMockInitialValues({});
  });

  void desktop(WidgetTester t) {
    t.view.physicalSize = const Size(1200, 1600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
  }

  testWidgets('a pending request shows Sign now and hands back its link',
      (t) async {
    desktop(t);
    ProtocolPendingRequest? signed;
    var opened = 0;
    await t.pumpWidget(_host(LoanCard(
      loan: _loan(pending: _pending()),
      tipHeight: 143,
      now: DateTime.utc(2026, 10, 3, 8, 45),
      onSign: (r) => signed = r,
      onOpen: () => opened++,
    )));
    await t.pumpAndSettle();

    // Who, where, what next.
    expect(find.text('SQ-1'), findsOneWidget);
    expect(find.text('You are the borrower'), findsOneWidget);
    // The flow strip: collateral into the escrow, principal to you, what
    // closes the loan back to the lender.
    // "Collateral" names the flow row and the grid line.
    expect(find.text('Collateral'), findsNWidgets(2));
    expect(find.text('Escrow'), findsOneWidget);
    expect(find.text('To repay'), findsOneWidget);
    expect(find.text('Lender'), findsWidgets);
    // The term ring reads the progress: (143 − 118) / (168 − 118) = 50%.
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('ACTIVE'), findsOneWidget);
    expect(find.text('Your signature'), findsOneWidget);
    expect(find.text('Sign the repayment of SQ-1'), findsOneWidget);
    expect(find.textContaining('Repayment · request expires in 15 min'),
        findsOneWidget);

    // Time: half the term run, 50 blocks ≈ 50 min, the due estimate.
    expect(find.byKey(const Key('loan-time-left')), findsOneWidget);
    expect(find.textContaining('≈ 50 min left'), findsOneWidget);
    expect(find.textContaining('due ≈'), findsOneWidget);
    expect(find.textContaining('Block 118 → 168'), findsOneWidget);

    // Money, with the thousands grouped and the tickers beside.
    expect(find.text('YOU OWE'), findsOneWidget);
    expect(find.text('10,200'), findsOneWidget);
    expect(find.text('rUSDt'), findsOneWidget);
    // Principal and collateral appear in the flow strip and in the grid.
    expect(find.text('10,000 rUSDt'), findsNWidgets(2));
    expect(find.text('0.5 rLBTC'), findsNWidgets(2));
    expect(find.text('200 rUSDt · 2%'), findsOneWidget);
    expect(find.text('50 rUSDt · paid by borrower'), findsOneWidget);

    // Sign now goes through the card's callback with the request itself.
    final sign = find.byKey(const Key('loan-sign-1'));
    expect(sign, findsOneWidget);
    await t.tap(sign);
    await t.pump();
    expect(signed, isNotNull);
    expect(signed!.link, _link);
    expect(signed!.id, 'req_1');

    await t.tap(find.byKey(const Key('loan-open-1')));
    await t.pump();
    expect(opened, 1);

    // Details are folded until asked for.
    expect(find.text('el1qqescrow'), findsNothing);
    await t.tap(find.byKey(const Key('loan-details-1')));
    await t.pumpAndSettle();
    expect(find.text('el1qqescrow'), findsOneWidget);
    expect(find.text('aa11'), findsOneWidget);
  });

  testWidgets('no pending request: no Sign now, the next step still leads',
      (t) async {
    desktop(t);
    await t.pumpWidget(_host(LoanCard(
      loan: _loan(),
      tipHeight: 143,
      onSign: (_) => fail('nothing to sign'),
      onOpen: () {},
    )));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('loan-sign-1')), findsNothing);
    expect(find.text('Your signature'), findsNothing);
    expect(find.text('Repay 10,200 rUSDt before ≈ 50 min'), findsOneWidget);
    expect(find.byKey(const Key('loan-open-1')), findsOneWidget);
  });

  testWidgets('a closed loan has no time bar and no amount owed', (t) async {
    desktop(t);
    await t.pumpWidget(_host(LoanCard(
      loan: _loan(state: ProtocolLoanState.repaid, blocksLeft: 0),
      tipHeight: 500,
      onOpen: () {},
    )));
    await t.pumpAndSettle();

    expect(find.text('REPAID'), findsOneWidget);
    expect(find.byKey(const Key('loan-time-left')), findsNothing);
    expect(find.text('50%'), findsNothing, reason: 'no ring once closed');
    expect(find.text('YOU OWE'), findsNothing);
    expect(find.text('To repay'), findsNothing);
    expect(find.text('Repaid'), findsOneWidget);
    expect(find.text('10,000 rUSDt'), findsWidgets);
  });

  testWidgets('the privacy mask hides the figures, not the loan', (t) async {
    desktop(t);
    final state = AppState();
    await state.setBalancesHidden(true);
    await t.pumpWidget(_host(
      LoanCard(loan: _loan(pending: _pending()), tipHeight: 143, onSign: (_) {}),
      state: state,
    ));
    await t.pumpAndSettle();

    expect(find.text('10,200'), findsNothing);
    expect(find.text('10,000 rUSDt'), findsNothing);
    expect(find.text('••••••'), findsWidgets);
    expect(find.text('SQ-1'), findsOneWidget);
    expect(find.byKey(const Key('loan-sign-1')), findsOneWidget);
  });
}
