// The wallet's side of `GET /connector/portfolio` and
// `DELETE /connector/portfolio` (connector-protocol.md §7): one HTTP client,
// one in-memory cache per connected site, and the hooks the rest of the app
// pulls to keep the Loans screen current.
//
// What it refuses to do: persist a portfolio (the site is the ledger; this
// holds the last answer only while the app runs), put the bearer token
// anywhere but the `Authorization` header, or log it. A 401 is final for a
// token — the record forgets it and the screen asks for a reconnect; a 429
// and a network failure keep the last answer on screen with the reason.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../features/protocol/models/protocol_portfolio.dart';
import '../features/protocol/models/protocol_records.dart';
import 'protocol_store.dart';

/// Why a portfolio request did not produce a portfolio.
enum ProtocolPortfolioErrorKind {
  /// No token on the record (connected by Templar 0.1.0), or the site
  /// answered 401: the wallet must be connected again.
  needsReconnect,

  /// 429: the token is over the site's 60-a-minute budget.
  rateLimited,

  /// The site could not be reached, or did not answer in time.
  offline,

  /// Any other HTTP status.
  server,

  /// 2xx with a body that is not a portfolio.
  malformed,
}

class ProtocolPortfolioError implements Exception {
  const ProtocolPortfolioError(this.kind, this.message);
  final ProtocolPortfolioErrorKind kind;
  final String message;

  @override
  String toString() => message;
}

/// The last answer for one site, with how it was obtained.
class ProtocolPortfolioSnapshot {
  const ProtocolPortfolioSnapshot({
    required this.siteKey,
    this.portfolio,
    this.error,
    this.loading = false,
    this.fetchedAt,
  });

  final String siteKey;

  /// The last good answer, kept through a later failure so the screen can
  /// show stale data with the reason beside it.
  final ProtocolPortfolio? portfolio;
  final ProtocolPortfolioError? error;
  final bool loading;

  /// When [portfolio] was received, local clock.
  final DateTime? fetchedAt;

  ProtocolPortfolioSnapshot copyWith({
    ProtocolPortfolio? portfolio,
    ProtocolPortfolioError? error,
    bool? loading,
    DateTime? fetchedAt,
    bool clearError = false,
  }) =>
      ProtocolPortfolioSnapshot(
        siteKey: siteKey,
        portfolio: portfolio ?? this.portfolio,
        error: clearError ? null : (error ?? this.error),
        loading: loading ?? this.loading,
        fetchedAt: fetchedAt ?? this.fetchedAt,
      );
}

class ProtocolPortfolioService extends ChangeNotifier {
  ProtocolPortfolioService._({http.Client? client, ProtocolStore? store})
      : _client = client ?? http.Client(),
        _store = store ?? ProtocolStore.instance;

  static final ProtocolPortfolioService instance = ProtocolPortfolioService._();

  /// A service over an injected client, for tests.
  @visibleForTesting
  factory ProtocolPortfolioService.withClient(http.Client client,
          {ProtocolStore? store}) =>
      ProtocolPortfolioService._(client: client, store: store);

  final http.Client _client;
  final ProtocolStore _store;
  final Map<String, ProtocolPortfolioSnapshot> _snapshots = {};
  final Map<String, Future<ProtocolPortfolio>> _inFlight = {};

  static const Duration _timeout = Duration(seconds: 15);

  /// The last known state of a site, or null before the first fetch.
  ProtocolPortfolioSnapshot? snapshot(String siteKey) => _snapshots[siteKey];

  // ── Fetch ───────────────────────────────────────────────────────────────────

  /// Fetches the site's portfolio and records it. Throws
  /// [ProtocolPortfolioError]; the snapshot carries the same error, so a
  /// listener needs no try/catch of its own.
  Future<ProtocolPortfolio> refresh(ProtocolConnectedSite site) {
    final running = _inFlight[site.key];
    if (running != null) return running;
    final future = _refresh(site);
    _inFlight[site.key] = future;
    return future.whenComplete(() => _inFlight.remove(site.key));
  }

  Future<ProtocolPortfolio> _refresh(ProtocolConnectedSite site) async {
    final prev = _snapshots[site.key] ?? ProtocolPortfolioSnapshot(siteKey: site.key);
    _snapshots[site.key] = prev.copyWith(loading: true, clearError: true);
    notifyListeners();
    try {
      final p = await fetchPortfolio(site);
      _snapshots[site.key] = ProtocolPortfolioSnapshot(
        siteKey: site.key,
        portfolio: p,
        fetchedAt: DateTime.now(),
      );
      notifyListeners();
      return p;
    } on ProtocolPortfolioError catch (e) {
      if (e.kind == ProtocolPortfolioErrorKind.needsReconnect && site.hasPortfolio) {
        // Dead on the site's side: keep no secret that opens nothing.
        await _store.clearPortfolio(site.key);
      }
      _snapshots[site.key] = prev.copyWith(loading: false, error: e);
      notifyListeners();
      rethrow;
    }
  }

  /// One bare `GET /connector/portfolio`, no cache.
  Future<ProtocolPortfolio> fetchPortfolio(ProtocolConnectedSite site) async {
    final url = site.portfolioUrl;
    final token = site.portfolioToken;
    if (!site.hasPortfolio || url == null || token == null) {
      throw ProtocolPortfolioError(
        ProtocolPortfolioErrorKind.needsReconnect,
        '${site.site} was connected before this wallet could show loans. '
        'Connect it again from the site to see them here.',
      );
    }
    final uri = Uri.parse(url);
    final resp = await _send(() => _client.get(uri, headers: _headers(token)), uri);
    _checkStatus(resp, site, uri);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    } catch (_) {
      throw ProtocolPortfolioError(ProtocolPortfolioErrorKind.malformed,
          '${site.site} did not answer with JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw ProtocolPortfolioError(ProtocolPortfolioErrorKind.malformed,
          '${site.site} did not answer with a portfolio.');
    }
    try {
      return ProtocolPortfolio.fromJson(decoded);
    } on FormatException catch (e) {
      throw ProtocolPortfolioError(ProtocolPortfolioErrorKind.malformed, e.message);
    }
  }

  // ── Revoke (§7, «Forget site») ─────────────────────────────────────────────

  /// `DELETE /connector/portfolio`: tells the site to stop honouring the
  /// token. Best effort — a site that cannot be reached still loses the
  /// local record, and says so in the result.
  Future<bool> revoke(ProtocolConnectedSite site) async {
    final url = site.portfolioUrl;
    final token = site.portfolioToken;
    if (!site.hasPortfolio || url == null || token == null) return false;
    try {
      final uri = Uri.parse(url);
      final resp = await _client
          .delete(uri, headers: _headers(token))
          .timeout(_timeout);
      _snapshots.remove(site.key);
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  // ── Hooks ───────────────────────────────────────────────────────────────────

  /// A signature was answered for [origin]: every connected site at that
  /// origin with a token is fetched again in the background, so the Loans
  /// screen already shows the new step when the user comes back to it.
  /// Failures are kept in the snapshot, never thrown from here.
  Future<void> refreshOrigin(String origin) async {
    final sites = await _store.sites();
    for (final s in sites) {
      if (s.origin == origin && s.hasPortfolio) {
        // The snapshot keeps the error; nobody awaits this.
        unawaited(refresh(s).then<void>((_) {}, onError: (_) {}));
      }
    }
  }

  /// Drops what is held for a site (it was forgotten).
  void forget(String siteKey) {
    if (_snapshots.remove(siteKey) != null) notifyListeners();
  }

  /// Test seam.
  @visibleForTesting
  void resetForTest() {
    _snapshots.clear();
    _inFlight.clear();
  }

  // ── Plumbing ────────────────────────────────────────────────────────────────

  Map<String, String> _headers(String token) => {
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
      };

  Future<http.Response> _send(
      Future<http.Response> Function() call, Uri uri) async {
    try {
      return await call().timeout(_timeout);
    } on TimeoutException {
      throw ProtocolPortfolioError(ProtocolPortfolioErrorKind.offline,
          '${uri.host} did not answer within ${_timeout.inSeconds} seconds.');
    } on ProtocolPortfolioError {
      rethrow;
    } catch (e) {
      throw ProtocolPortfolioError(ProtocolPortfolioErrorKind.offline,
          'Could not reach ${uri.host}: ${_clean(e)}');
    }
  }

  void _checkStatus(http.Response resp, ProtocolConnectedSite site, Uri uri) {
    final code = resp.statusCode;
    if (code >= 200 && code < 300) return;
    final why = _errorText(resp);
    switch (code) {
      case 401:
        throw ProtocolPortfolioError(
          ProtocolPortfolioErrorKind.needsReconnect,
          '${site.site} no longer accepts this wallet\'s access token'
          '${why.isEmpty ? '' : ' ($why)'}. Connect the wallet again from the '
          'site to see your loans.',
        );
      case 429:
        throw ProtocolPortfolioError(
          ProtocolPortfolioErrorKind.rateLimited,
          '${site.site} is asking this wallet to slow down. Try again in a minute.',
        );
      default:
        throw ProtocolPortfolioError(
          ProtocolPortfolioErrorKind.server,
          '${site.site} answered HTTP $code${why.isEmpty ? '' : ': $why'}.',
        );
    }
  }

  static String _errorText(http.Response resp) {
    try {
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is Map && decoded['error'] is String) {
        return (decoded['error'] as String).trim();
      }
    } catch (_) {}
    return '';
  }

  static String _clean(Object e) =>
      e.toString().replaceFirst('Exception: ', '').replaceFirst('ClientException: ', '');
}
