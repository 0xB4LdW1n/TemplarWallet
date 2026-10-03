// The wallet's calls to a Templar Protocol site (connector-protocol.md
// §7–§8), against a scripted HTTP client: what goes on the wire — the token
// in the Authorization header and nowhere else — and what each answer turns
// into for the Loans screen.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:templar_wallet/features/protocol/models/protocol_records.dart';
import 'package:templar_wallet/services/protocol_portfolio_service.dart';
import 'package:templar_wallet/services/protocol_store.dart';

const _token = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_ABCDE';
const _origin = 'http://127.0.0.1:8087';

ProtocolConnectedSite _site({bool token = true}) => ProtocolConnectedSite(
      site: 'Templar Protocol',
      origin: _origin,
      network: 'liquid-regtest',
      walletId: 'w1',
      walletName: 'Alice',
      connectedAt: DateTime.utc(2026, 10, 3, 10),
      portfolioUrl: token ? '$_origin/connector/portfolio' : null,
      portfolioToken: token ? _token : null,
    );

const _portfolioJson =
    '{"version":1,"site":"Templar Protocol","network":"liquid-regtest","tip_height":10,'
    '"as_of":1759480000,"wallet":{"label":"Templar — Alice","escrow_fingerprint":"73c5da0a"},'
    '"loans":[{"id":1,"ref":"SQ-1","role":"borrower","state":"active"}],"offers":[]}';

/// A JSON answer as the site sends it: UTF-8 (the wallet label carries an
/// em dash) with the content type that says so.
http.Response _json(String body, [int status = 200]) => http.Response.bytes(
      utf8.encode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ProtocolStore.instance.resetCacheForTest();
  });

  ProtocolPortfolioService service(MockClientHandler handler) =>
      ProtocolPortfolioService.withClient(MockClient(handler),
          store: ProtocolStore.instance);

  group('GET /connector/portfolio', () {
    test('sends the bearer header to the stored URL and parses the answer',
        () async {
      http.Request? seen;
      final svc = service((req) async {
        seen = req;
        return _json(_portfolioJson);
      });
      final p = await svc.refresh(_site());
      expect(p.loans.single.ref, 'SQ-1');
      expect(seen!.method, 'GET');
      expect(seen!.url.toString(), '$_origin/connector/portfolio');
      expect(seen!.headers['Authorization'], 'Bearer $_token');
      expect(seen!.headers['Accept'], 'application/json');
      // Never in the URL.
      expect(seen!.url.toString(), isNot(contains(_token)));

      final snap = svc.snapshot(_site().key)!;
      expect(snap.portfolio, same(p));
      expect(snap.loading, isFalse);
      expect(snap.error, isNull);
      expect(snap.fetchedAt, isNotNull);
    });

    test('a record without a token asks for a reconnect without a request',
        () async {
      var calls = 0;
      final svc = service((_) async {
        calls++;
        return http.Response('{}', 200);
      });
      await expectLater(
        svc.refresh(_site(token: false)),
        throwsA(isA<ProtocolPortfolioError>().having(
            (e) => e.kind, 'kind', ProtocolPortfolioErrorKind.needsReconnect)),
      );
      expect(calls, 0);
    });

    test('401 drops the token from the record and says reconnect', () async {
      await ProtocolStore.instance.recordConnect(_site());
      final svc = service((_) async => http.Response(
          '{"ok":false,"error":"unknown or revoked token; connect the wallet again"}',
          401));
      await expectLater(
        svc.refresh(_site()),
        throwsA(isA<ProtocolPortfolioError>()
            .having((e) => e.kind, 'kind', ProtocolPortfolioErrorKind.needsReconnect)
            .having((e) => e.message, 'message', contains('revoked token'))),
      );
      final stored = (await ProtocolStore.instance.sites()).single;
      expect(stored.hasPortfolio, isFalse);
      expect(svc.snapshot(_site().key)!.error!.kind,
          ProtocolPortfolioErrorKind.needsReconnect);
    });

    test('429 is a rate limit, 500 a server error; the last answer stays',
        () async {
      var status = 200;
      final svc = service((_) async =>
          _json(status == 200 ? _portfolioJson : '{"ok":false,"error":"x"}', status));
      await svc.refresh(_site());

      status = 429;
      await expectLater(
        svc.refresh(_site()),
        throwsA(isA<ProtocolPortfolioError>()
            .having((e) => e.kind, 'kind', ProtocolPortfolioErrorKind.rateLimited)
            .having((e) => e.message, 'message', contains('minute'))),
      );
      final snap = svc.snapshot(_site().key)!;
      expect(snap.portfolio, isNotNull, reason: 'stale data kept');
      expect(snap.error!.kind, ProtocolPortfolioErrorKind.rateLimited);

      status = 500;
      await expectLater(
        svc.refresh(_site()),
        throwsA(isA<ProtocolPortfolioError>()
            .having((e) => e.kind, 'kind', ProtocolPortfolioErrorKind.server)
            .having((e) => e.message, 'message', contains('HTTP 500'))),
      );
      // The token is still there: only a 401 is final.
      expect(_site().hasPortfolio, isTrue);
    });

    test('a site that cannot be reached is offline, not broken', () async {
      final svc = service((_) async => throw http.ClientException('refused'));
      await expectLater(
        svc.refresh(_site()),
        throwsA(isA<ProtocolPortfolioError>()
            .having((e) => e.kind, 'kind', ProtocolPortfolioErrorKind.offline)
            .having((e) => e.message, 'message', contains('127.0.0.1'))),
      );
    });

    test('a 200 that is not a portfolio is malformed', () async {
      final svc = service((_) async => http.Response('<html>', 200));
      await expectLater(
        svc.refresh(_site()),
        throwsA(isA<ProtocolPortfolioError>()
            .having((e) => e.kind, 'kind', ProtocolPortfolioErrorKind.malformed)),
      );
      final svc2 = service((_) async => http.Response('{"version":1}', 200));
      await expectLater(
        svc2.refresh(_site()),
        throwsA(isA<ProtocolPortfolioError>()
            .having((e) => e.message, 'message', contains('"loans"'))),
      );
    });

    test('two refreshes at once are one request', () async {
      var calls = 0;
      final svc = service((_) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return _json(_portfolioJson);
      });
      await Future.wait([svc.refresh(_site()), svc.refresh(_site())]);
      expect(calls, 1);
    });
  });

  group('POST /connector/open', () {
    test('asks for a link to the loan, token in the header only', () async {
      http.Request? seen;
      final svc = service((req) async {
        seen = req;
        return http.Response(
            '{"url":"$_origin/connector/open/ONETIMEsecret","expires_at":1759480120}',
            200);
      });
      final link = await svc.openLink(_site(), to: '/loans/7');
      expect(link.toString(), '$_origin/connector/open/ONETIMEsecret');
      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), '$_origin/connector/open');
      expect(seen!.headers['Authorization'], 'Bearer $_token');
      expect(seen!.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(seen!.body), {'to': '/loans/7'});
      expect(seen!.url.toString(), isNot(contains(_token)));
      expect(link.toString(), isNot(contains(_token)));
    });

    test('the default landing is the site root', () async {
      http.Request? seen;
      final svc = service((req) async {
        seen = req;
        return http.Response('{"url":"$_origin/connector/open/x"}', 200);
      });
      await svc.openLink(_site());
      expect(jsonDecode(seen!.body), {'to': '/'});
    });

    test('a link to another host is refused', () async {
      final svc = service((_) async =>
          http.Response('{"url":"https://evil.example/connector/open/x"}', 200));
      await expectLater(
        svc.openLink(_site()),
        throwsA(isA<ProtocolPortfolioError>()
            .having((e) => e.kind, 'kind', ProtocolPortfolioErrorKind.malformed)
            .having((e) => e.message, 'message', contains('another host'))),
      );
    });

    test('an expired token and an offline site are told in words', () async {
      final dead = service((_) async =>
          http.Response('{"ok":false,"error":"unknown or revoked token"}', 401));
      await expectLater(
        dead.openLink(_site()),
        throwsA(isA<ProtocolPortfolioError>()
            .having((e) => e.kind, 'kind', ProtocolPortfolioErrorKind.needsReconnect)
            .having((e) => e.message, 'message', contains('Connect the wallet again'))),
      );
      final offline = service((_) async => throw http.ClientException('down'));
      await expectLater(
        offline.openLink(_site()),
        throwsA(isA<ProtocolPortfolioError>()
            .having((e) => e.kind, 'kind', ProtocolPortfolioErrorKind.offline)),
      );
      final noToken = service((_) async => fail('no request without a token'));
      await expectLater(
        noToken.openLink(_site(token: false)),
        throwsA(isA<ProtocolPortfolioError>()
            .having((e) => e.kind, 'kind', ProtocolPortfolioErrorKind.needsReconnect)),
      );
    });

    test('the open endpoint sits beside the portfolio one', () {
      expect(
        ProtocolPortfolioService.openEndpoint(
                Uri.parse('https://lend.example/connector/portfolio'))
            .toString(),
        'https://lend.example/connector/open',
      );
      expect(
        ProtocolPortfolioService.openEndpoint(
                Uri.parse('https://host/under/path/connector/portfolio?x=1'))
            .toString(),
        'https://host/under/path/connector/open',
      );
      expect(
        ProtocolPortfolioService.openEndpoint(Uri.parse('http://127.0.0.1:8087/odd'))
            .toString(),
        'http://127.0.0.1:8087/connector/open',
      );
    });
  });

  group('DELETE /connector/portfolio', () {
    test('revoke sends the token once and reports the outcome', () async {
      http.Request? seen;
      final svc = service((req) async {
        seen = req;
        return http.Response('{"ok":true}', 200);
      });
      expect(await svc.revoke(_site()), isTrue);
      expect(seen!.method, 'DELETE');
      expect(seen!.headers['Authorization'], 'Bearer $_token');

      final down = service((_) async => throw http.ClientException('down'));
      expect(await down.revoke(_site()), isFalse);
      final none = service((_) async => fail('no token, no request'));
      expect(await none.revoke(_site(token: false)), isFalse);
    });
  });

  test('refreshOrigin fetches every tokened site at that origin, quietly',
      () async {
    await ProtocolStore.instance.recordConnect(_site());
    await ProtocolStore.instance.recordConnect(ProtocolConnectedSite(
      site: 'Other',
      origin: 'https://other.example',
      network: 'liquid-regtest',
      walletId: 'w1',
      walletName: 'Alice',
      connectedAt: DateTime.utc(2026, 10, 3),
      portfolioUrl: 'https://other.example/connector/portfolio',
      portfolioToken: _token,
    ));
    final hosts = <String>[];
    final svc = service((req) async {
      hosts.add(req.url.host);
      return http.Response('{"ok":false}', 500);
    });
    await svc.refreshOrigin(_origin);
    await Future<void>.delayed(Duration.zero);
    expect(hosts, ['127.0.0.1']);
    // The failure lives in the snapshot; nothing was thrown.
    expect(svc.snapshot(_site().key)!.error!.kind, ProtocolPortfolioErrorKind.server);
  });
}
