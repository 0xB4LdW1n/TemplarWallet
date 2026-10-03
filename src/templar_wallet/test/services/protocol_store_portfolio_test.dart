// The portfolio token on a connected-site record (connector-protocol.md §7):
// it round-trips, a record written before v1.1 reads back without one, and
// the store can set and drop it on its own.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:templar_wallet/features/protocol/models/protocol_records.dart';
import 'package:templar_wallet/services/protocol_store.dart';

const _token = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_ABCDE';
const _url = 'http://127.0.0.1:8087/connector/portfolio';

ProtocolConnectedSite _site({String? url, String? token, String walletId = 'w1'}) =>
    ProtocolConnectedSite(
      site: 'Templar Protocol',
      origin: 'http://127.0.0.1:8087',
      network: 'liquid-regtest',
      walletId: walletId,
      walletName: 'Alice',
      connectedAt: DateTime.utc(2026, 10, 3, 10),
      escrowFingerprint: '73c5da0a',
      portfolioUrl: url,
      portfolioToken: token,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = ProtocolStore.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store.resetCacheForTest();
  });

  test('url and token survive a restart, together or not at all', () async {
    await store.recordConnect(_site(url: _url, token: _token));
    store.resetCacheForTest();
    final s = (await store.sites()).single;
    expect(s.hasPortfolio, isTrue);
    expect(s.portfolioUrl, _url);
    expect(s.portfolioToken, _token);

    // Half an object is no object: the record says "reconnect".
    await store.recordConnect(_site(url: _url));
    store.resetCacheForTest();
    final half = (await store.sites()).single;
    expect(half.hasPortfolio, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('protocol_sites_v1'), isNot(contains('portfolio')));
  });

  test('a record from 0.1.0 reads back without a portfolio', () async {
    SharedPreferences.setMockInitialValues({
      'protocol_sites_v1': jsonEncode([
        {
          'site': 'Templar Protocol demo',
          'origin': 'http://127.0.0.1:8087',
          'network': 'liquid-regtest',
          'wallet_id': 'w1',
          'wallet_name': 'Alice',
          'at': '2026-09-17T10:00:00.000Z',
          'escrow_fingerprint': '73c5da0a',
          'receive_address': 'el1qq0000',
          'shared_descriptor': true,
        }
      ]),
    });
    store.resetCacheForTest();
    final s = (await store.sites()).single;
    expect(s.site, 'Templar Protocol demo');
    expect(s.hasPortfolio, isFalse);
    expect(s.portfolioUrl, isNull);
    expect(s.portfolioToken, isNull);
  });

  test('setPortfolio and clearPortfolio edit the one record', () async {
    await store.recordConnect(_site());
    await store.recordConnect(_site(walletId: 'w2'));
    await store.setPortfolio(_site().key, url: _url, token: _token);
    store.resetCacheForTest();

    final sites = await store.sites();
    expect(sites.firstWhere((s) => s.walletId == 'w1').hasPortfolio, isTrue);
    expect(sites.firstWhere((s) => s.walletId == 'w2').hasPortfolio, isFalse);
    expect((await store.sitesForWallet('w1')).single.portfolioToken, _token);

    // An unknown key changes nothing.
    await store.setPortfolio('https://nope|w9', url: _url, token: _token);
    expect(await store.sites(), hasLength(2));

    await store.clearPortfolio(_site().key);
    store.resetCacheForTest();
    expect((await store.sitesForWallet('w1')).single.hasPortfolio, isFalse);
    // Everything else about the record stays.
    expect((await store.sitesForWallet('w1')).single.escrowFingerprint, '73c5da0a');
  });

  test('the portfolio object of a connect answer is read strictly', () {
    expect(
      ProtocolConnectedSite.portfolioFromReply({'url': _url, 'token': _token}),
      (url: _url, token: _token),
    );
    expect(ProtocolConnectedSite.portfolioFromReply(null), isNull);
    expect(ProtocolConnectedSite.portfolioFromReply('x'), isNull);
    expect(ProtocolConnectedSite.portfolioFromReply({'url': _url}), isNull);
    expect(ProtocolConnectedSite.portfolioFromReply({'url': '', 'token': _token}),
        isNull);
    expect(
        ProtocolConnectedSite.portfolioFromReply({'url': 'not a url', 'token': _token}),
        isNull);
  });

  test('copyWith keeps the token unless told to drop it', () {
    final s = _site(url: _url, token: _token);
    expect(s.copyWith().hasPortfolio, isTrue);
    expect(s.copyWith(clearPortfolio: true).hasPortfolio, isFalse);
    expect(_site().copyWith(portfolioUrl: _url, portfolioToken: _token).hasPortfolio,
        isTrue);
  });
}
