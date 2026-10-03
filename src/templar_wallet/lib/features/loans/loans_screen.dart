// Loans — the wallet's view of its Templar Protocol loans, fed by the site
// (`GET /connector/portfolio`, connector-protocol.md §7).
//
// The wallet knows nothing about a loan on its own: it signs what the site
// asks and keeps a thin history. This screen asks the site, with the token
// the connect callback handed back, and shows the answer as it is — role,
// state, next step, time left, amounts — plus the two things the wallet can
// do about it: sign the pending request in-app, or open the loan on the
// site. Nothing here is stored; the site is the ledger and this is a window.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../app/routes.dart';
import '../../services/protocol_link_service.dart';
import '../../services/protocol_portfolio_service.dart';
import '../../services/protocol_store.dart';
import '../../shared/relative_time.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/expander.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/list_rows.dart';
import '../../shared/widgets/page_header.dart';
import '../../shared/widgets/privacy.dart';
import '../../shared/widgets/segmented_switch.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../protocol/models/protocol_link.dart';
import '../protocol/models/protocol_portfolio.dart';
import '../protocol/models/protocol_records.dart';
import 'loan_card.dart';

class LoansScreen extends StatefulWidget {
  const LoansScreen({super.key, this.service, this.store});

  /// Injectable for tests; the app passes nothing and gets the singletons.
  final ProtocolPortfolioService? service;
  final ProtocolStore? store;

  @override
  State<LoansScreen> createState() => _LoansScreenState();
}

class _LoansScreenState extends State<LoansScreen> {
  ProtocolPortfolioService get _service =>
      widget.service ?? ProtocolPortfolioService.instance;
  ProtocolStore get _store => widget.store ?? ProtocolStore.instance;

  List<ProtocolConnectedSite> _sites = const [];
  String? _siteKey;
  bool _sitesLoaded = false;
  String? _walletId;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onService);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSites());
  }

  @override
  void dispose() {
    _service.removeListener(_onService);
    super.dispose();
  }

  void _onService() {
    if (mounted) setState(() {});
  }

  ProtocolConnectedSite? get _site {
    for (final s in _sites) {
      if (s.key == _siteKey) return s;
    }
    return null;
  }

  Future<void> _loadSites() async {
    final walletId = context.read<AppState>().activeWalletId;
    _walletId = walletId;
    final sites = walletId == null
        ? <ProtocolConnectedSite>[]
        : await _store.sitesForWallet(walletId);
    if (!mounted) return;
    // The site with a token first; a pre-v1.1 one only when it is all there is.
    final preferred = sites.where((s) => s.hasPortfolio).firstOrNull ??
        sites.firstOrNull;
    setState(() {
      _sites = sites;
      _siteKey = sites.any((s) => s.key == _siteKey) ? _siteKey : preferred?.key;
      _sitesLoaded = true;
    });
    final site = _site;
    if (site != null && site.hasPortfolio && _service.snapshot(site.key) == null) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    var site = _site;
    if (site == null) return;
    // The record may have changed under us (a reconnect stored a token).
    final fresh = (await _store.sitesForWallet(site.walletId))
        .where((s) => s.key == site!.key)
        .firstOrNull;
    if (fresh != null) site = fresh;
    if (!mounted) return;
    if (!site.hasPortfolio) {
      await _loadSites();
      return;
    }
    try {
      await _service.refresh(site);
    } on ProtocolPortfolioError {
      // The snapshot carries it; a 401 also dropped the token, so re-read.
      if (mounted) await _loadSites();
    }
  }

  void _sign(ProtocolPendingRequest request) {
    // The same door a browser link comes through: the request screen fetches
    // the request, shows both readings and asks for the gate and the
    // password. Nothing is signed from here.
    ProtocolLinkService.instance.inject(request.link);
  }

  /// Opens the loan (or the site) in the browser. The one-time session link
  /// of §8 arrives with the next deliverable; until then this is the plain
  /// page, where the site asks the browser to sign in on its own.
  Future<void> _open(ProtocolLoan? loan) async {
    final site = _site;
    if (site == null) return;
    final target = loan?.nextAction?.url ?? Uri.tryParse(site.origin);
    if (target == null) return;
    await launchUrl(target, mode: LaunchMode.externalApplication);
  }

  Future<void> _openSite() async {
    final site = _site;
    if (site == null) return;
    final uri = Uri.tryParse(site.origin);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final phone = AppLayout.isPhone(context);
    final pad = AppSpacing.pagePadding(context);
    final st = context.watch<AppState>();
    final site = _site;
    final snap = site == null ? null : _service.snapshot(site.key);
    final portfolio = snap?.portfolio;
    final walletName = st.activeWalletName ?? site?.walletName ?? '';
    final network = portfolio?.network ?? site?.network ?? st.liquidNetwork?.network ?? '';
    final subtitle = site == null
        ? 'Templar Protocol'
        : [
            site.site,
            if (walletName.isNotEmpty) walletName,
            if (network.isNotEmpty) protocolNetworkLabel(network),
          ].join(' · ');
    final loading = snap?.loading ?? false;

    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!phone)
          PageHeader(
            title: 'Loans',
            subtitle: subtitle,
            actions: [
              const PrivacyToggle(),
              GhostButton(
                key: const Key('loans-settings'),
                label: 'Templar Protocol',
                icon: Icons.tune_rounded,
                onPressed: () => context.go(AppRoutes.settingsProtocol),
              ),
              if (site != null && site.hasPortfolio)
                SecondaryButton(
                  key: const Key('loans-refresh'),
                  label: 'Refresh',
                  icon: Icons.refresh_rounded,
                  dense: true,
                  isLoading: loading,
                  onPressed: loading ? null : _refresh,
                ),
            ],
          )
        else
          _PhoneHeader(
            subtitle: subtitle,
            loading: loading,
            canRefresh: site != null && site.hasPortfolio,
            onRefresh: _refresh,
            onSettings: () => context.go(AppRoutes.settingsProtocol),
          ),
        if (_sites.length > 1) ...[
          SegmentedSwitch<String>(
            selected: _siteKey ?? _sites.first.key,
            expand: true,
            dense: phone,
            onChanged: (k) {
              setState(() => _siteKey = k);
              final s = _site;
              if (s != null && s.hasPortfolio && _service.snapshot(s.key) == null) {
                _refresh();
              }
            },
            options: [
              for (final s in _sites)
                SegOption(value: s.key, label: s.site, icon: Icons.link_rounded),
            ],
          ),
          SizedBox(height: phone ? AppSpacing.md : AppSpacing.lg),
        ],
      ],
    );

    return Scaffold(
      body: PageBackground.flat(
        child: ListView(
          padding: EdgeInsets.fromLTRB(pad, phone ? AppSpacing.lg : pad, pad, pad + AppSpacing.xl),
          children: [
            header,
            ..._body(site: site, snap: snap, phone: phone),
          ],
        ),
      ),
    );
  }

  List<Widget> _body({
    required ProtocolConnectedSite? site,
    required ProtocolPortfolioSnapshot? snap,
    required bool phone,
  }) {
    if (!_sitesLoaded) {
      return const [
        Padding(
          padding: EdgeInsets.all(AppSpacing.xxl),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (site == null) {
      return [
        _Empty(
          key: const Key('loans-no-site'),
          icon: Icons.link_off_rounded,
          title: 'No site connected to this wallet',
          body: _walletId == null
              ? 'Open a wallet first.'
              : 'A Templar Protocol site learns about this wallet when you click '
                  '"Connect Templar Wallet" there. Once connected, its loans show '
                  'up here.',
          action: SecondaryButton(
            label: 'Templar Protocol settings',
            icon: Icons.tune_rounded,
            onPressed: () => context.go(AppRoutes.settingsProtocol),
            isFullWidth: phone,
          ),
        ),
      ];
    }
    final portfolio = snap?.portfolio;
    final error = snap?.error;
    if (!site.hasPortfolio) {
      return [
        _Empty(
          key: const Key('loans-reconnect'),
          icon: Icons.sync_problem_rounded,
          title: 'Reconnect to see your loans',
          body: error?.kind == ProtocolPortfolioErrorKind.needsReconnect &&
                  error != null
              ? error.message
              : '${site.site} was connected before this wallet could show '
                  'loans, or has since revoked its access. Connect it again '
                  'from the site: the loans you already have come back with it.',
          action: PrimaryButton(
            key: const Key('loans-open-site'),
            label: 'Open ${site.site}',
            icon: Icons.open_in_new,
            onPressed: _openSite,
            isFullWidth: phone,
          ),
        ),
      ];
    }
    if (portfolio == null) {
      if (error != null) {
        return [
          _Empty(
            key: const Key('loans-error'),
            icon: Icons.cloud_off_rounded,
            title: switch (error.kind) {
              ProtocolPortfolioErrorKind.rateLimited => 'Asked too often',
              ProtocolPortfolioErrorKind.offline => 'The site did not answer',
              _ => 'Could not load the loans',
            },
            body: error.message,
            action: SecondaryButton(
              key: const Key('loans-retry'),
              label: 'Try again',
              icon: Icons.refresh_rounded,
              onPressed: _refresh,
              isFullWidth: phone,
            ),
          ),
        ];
      }
      return const [
        Padding(
          padding: EdgeInsets.all(AppSpacing.xxl),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    final open = portfolio.openLoans;
    final closed = portfolio.closedLoans;
    final offers = portfolio.offers;
    final s = AppScheme.of(context);
    final gap = SizedBox(height: phone ? AppSpacing.md : AppSpacing.lg);

    return [
      if (error != null) ...[
        WarningBanner(
          title: 'Showing the last answer',
          message: '${error.message} Below is what ${site.site} said '
              '${snap?.fetchedAt != null ? relativeTimeShort(snap!.fetchedAt!) : 'earlier'}.',
        ),
        gap,
      ],
      ListSectionLabel(
        label: open.isEmpty
            ? 'Active loans'
            : 'Active loans · ${open.length}'
                '${portfolio.pendingCount > 0 ? ' · ${portfolio.pendingCount} to sign' : ''}',
      ),
      if (open.isEmpty)
        _Empty(
          key: const Key('loans-empty'),
          icon: Icons.handshake_outlined,
          title: 'No loans yet',
          body: 'Open the site to find one. Offers you take or that are taken '
              'from you show up here, with every step that needs your '
              'signature.',
          action: SecondaryButton(
            key: const Key('loans-open-site'),
            label: 'Open ${site.site}',
            icon: Icons.open_in_new,
            onPressed: () => _open(null),
            isFullWidth: phone,
          ),
        )
      else
        for (var i = 0; i < open.length; i++) ...[
          if (i > 0) gap,
          LoanCard(
            loan: open[i],
            tipHeight: portfolio.tipHeight,
            onSign: _sign,
            onOpen: () => _open(open[i]),
          ),
        ],
      if (offers.isNotEmpty) ...[
        SizedBox(height: phone ? AppSpacing.xl : AppSpacing.xxl),
        ListSectionLabel(label: 'Your offers · ${offers.length}'),
        ListCard(
          children: [
            for (final o in offers) _OfferRow(offer: o),
          ],
        ),
      ],
      if (closed.isNotEmpty) ...[
        SizedBox(height: phone ? AppSpacing.xl : AppSpacing.xxl),
        ExpanderCard(
          key: const Key('loans-closed'),
          title: 'Closed loans',
          subtitle: 'Repaid, defaulted or liquidated — kept for the record.',
          trailing: TagChip(label: '${closed.length}', color: s.inkSecondary),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < closed.length; i++) ...[
                if (i > 0) gap,
                LoanCard(
                  loan: closed[i],
                  tipHeight: portfolio.tipHeight,
                  onOpen: () => _open(closed[i]),
                ),
              ],
            ],
          ),
        ),
      ],
      SizedBox(height: phone ? AppSpacing.lg : AppSpacing.xl),
      Text(
        'As of ${_asOf(portfolio.asOf)} · block ${protocolGroupDigits('${portfolio.tipHeight}')}'
        '${portfolio.wallet.label.isNotEmpty ? ' · known to ${site.site} as "${portfolio.wallet.label}"' : ''}'
        '${portfolio.wallet.escrowFingerprint.isNotEmpty ? ' · loan key ${portfolio.wallet.escrowFingerprint}' : ''}',
        key: const Key('loans-as-of'),
        style: AppTypography.caption.copyWith(color: s.inkFaint),
      ),
    ];
  }

  static String _asOf(DateTime t) {
    final l = t.toLocal();
    final hh = l.hour.toString().padLeft(2, '0');
    final mm = l.minute.toString().padLeft(2, '0');
    final ss = l.second.toString().padLeft(2, '0');
    return '${relativeTimeShort(l)} ($hh:$mm:$ss)';
  }
}

// ── Pieces ────────────────────────────────────────────────────────────────────

/// The phone's header: the shell already names the wallet above, so this is
/// the site line as an eyebrow with the two actions at its right.
class _PhoneHeader extends StatelessWidget {
  const _PhoneHeader({
    required this.subtitle,
    required this.loading,
    required this.canRefresh,
    required this.onRefresh,
    required this.onSettings,
  });
  final String subtitle;
  final bool loading;
  final bool canRefresh;
  final VoidCallback onRefresh;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('LOANS',
                    style: AppTypography.navSection
                        .copyWith(color: s.inkFaint, letterSpacing: 1.3)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: AppTypography.bodySmall.copyWith(color: s.inkSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const PrivacyToggle(),
          IconButton(
            tooltip: 'Templar Protocol settings',
            onPressed: onSettings,
            icon: Icon(Icons.tune_rounded, color: s.inkSecondary),
          ),
          if (canRefresh)
            IconButton(
              key: const Key('loans-refresh'),
              tooltip: 'Refresh',
              onPressed: loading ? null : onRefresh,
              icon: loading
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(Icons.refresh_rounded, color: s.inkSecondary),
            ),
        ],
      ),
    );
  }
}

class _OfferRow extends StatelessWidget {
  const _OfferRow({required this.offer});
  final ProtocolOffer offer;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final o = offer;
    final side = switch (o.side) {
      'lend' => 'Lending',
      'borrow' => 'Borrowing',
      '' => 'Offer',
      final other => other,
    };
    final terms = [
      if (o.rateBps != null) protocolBpsLabel(o.rateBps!),
      if (o.durationBlocks != null) '${protocolGroupDigits('${o.durationBlocks}')} blocks',
      if (o.collateral != null) 'against ${o.collateral!.display}',
    ].join(' · ');
    return ListRow(
      icon: o.side == 'lend' ? Icons.call_made_rounded : Icons.call_received_rounded,
      tint: s.liquid,
      title: '$side${o.principal != null ? ' ${o.principal!.display}' : ''} · #${o.id}',
      subtitle: [if (o.state.isNotEmpty) o.state, if (terms.isNotEmpty) terms].join(' · '),
      trailing: o.state.isNotEmpty ? TagChip(label: o.state, color: s.inkSecondary) : null,
      chevron: o.url != null,
      onTap: o.url == null
          ? null
          : () => launchUrl(o.url!, mode: LaunchMode.externalApplication),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return FormCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ListIconTile(icon: icon, tint: s.inkSecondary, size: 56),
          const SizedBox(height: AppSpacing.md),
          Text(title,
              style: AppTypography.sectionTitleOf(context).copyWith(color: s.ink),
              textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.xs),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Text(body,
                style: AppTypography.caption.copyWith(color: s.inkSecondary),
                textAlign: TextAlign.center),
          ),
          if (action != null) ...[
            const SizedBox(height: AppSpacing.lg),
            action!,
          ],
        ],
      ),
    );
  }
}
