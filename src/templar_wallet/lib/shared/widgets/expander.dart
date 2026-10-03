// A card whose body folds away: one hairline row with the title, a count or
// caption on the right and a chevron that turns; the body below it when
// open. For the things a page must keep but need not show first — closed
// loans, the long "how it works" — so the fact the page exists for stays
// above the fold (design.md: chrome recedes).

import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

class ExpanderCard extends StatefulWidget {
  const ExpanderCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.initiallyExpanded = false,
    this.padding,
  });

  final String title;

  /// One quiet line under the title, visible folded or not.
  final String? subtitle;

  /// A count or a chip on the right of the title row, before the chevron.
  final Widget? trailing;
  final Widget child;
  final bool initiallyExpanded;

  /// Body inset; defaults to the card padding of the window at hand.
  final EdgeInsetsGeometry? padding;

  @override
  State<ExpanderCard> createState() => _ExpanderCardState();
}

class _ExpanderCardState extends State<ExpanderCard> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final pad = phone ? AppSpacing.cardPaddingSmall : AppSpacing.cardPadding;
    final reduced = AppMotion.reduced(context);
    final sub = widget.subtitle;

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: s.surfaceGlass,
        borderRadius: BorderRadius.circular(
            phone ? AppSpacing.radiusLg : AppSpacing.radiusMd),
        border: Border.all(color: s.edge),
        boxShadow: s.panelShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () => setState(() => _open = !_open),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(pad, pad, pad - 4, pad),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.title,
                                style: AppTypography.sectionTitleOf(context)
                                    .copyWith(color: s.ink)),
                            if (sub != null)
                              Padding(
                                padding:
                                    const EdgeInsets.only(top: AppSpacing.xs),
                                child: Text(sub,
                                    style: AppTypography.caption
                                        .copyWith(color: s.inkSecondary)),
                              ),
                          ],
                        ),
                      ),
                      if (widget.trailing != null) ...[
                        const SizedBox(width: AppSpacing.sm),
                        widget.trailing!,
                      ],
                      const SizedBox(width: AppSpacing.xs),
                      AnimatedRotation(
                        turns: _open ? 0.5 : 0,
                        duration: reduced ? Duration.zero : AppMotion.standard,
                        curve: AppMotion.settle,
                        child: Icon(Icons.expand_more_rounded,
                            size: 22, color: s.inkFaint),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // The body is built only while open: a folded card holds nothing
          // a screen reader or a finder could still reach.
          AnimatedSize(
            duration: reduced ? Duration.zero : AppMotion.standard,
            curve: AppMotion.settle,
            alignment: Alignment.topCenter,
            child: _open
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Divider(height: 1, color: s.edge),
                      Padding(
                        padding: widget.padding ?? EdgeInsets.all(pad),
                        child: widget.child,
                      ),
                    ],
                  )
                : const SizedBox(width: double.infinity, height: 0),
          ),
        ],
      ),
    );
  }
}
