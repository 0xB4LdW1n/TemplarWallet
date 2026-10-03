// Proof of key on the app side (connector-protocol.md §9): the challenge
// rides on both request kinds and is kept verbatim, a `proof` request is
// recognised, the bridge's two answers decode, and the wallet rule now lets
// a Jade connect while every proof route tells it why it cannot prove yet.

import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/features/protocol/models/protocol_link.dart';
import 'package:templar_wallet/features/protocol/models/protocol_proof.dart';
import 'package:templar_wallet/features/protocol/models/protocol_wallet_fit.dart';
import 'package:templar_wallet/features/wallet_picker/models/wallet_summary.dart';

const _challenge = 'Templar Protocol · access · http://127.0.0.1:8087 · '
    'nonce=AAAAAAAAAAAAAAAAAAAAAA · expires=2026-10-03T10:15:00Z · '
    'this signature never moves funds';

Map<String, dynamic> _connect({Object? challenge = _challenge}) => {
      'version': 1,
      'kind': 'connect',
      'site': 'Templar Protocol',
      'network': 'liquid-regtest',
      'nonce': 'n1',
      'callback': 'http://127.0.0.1:8087/wallet/connect/t',
      'expires_at': 1900000000,
      'challenge': ?challenge,
    };

Map<String, dynamic> _proofSign() => {
      'version': 1,
      'kind': 'sign',
      'id': 'prf_1',
      'site': 'Templar Protocol',
      'network': 'liquid-regtest',
      'nonce': 'n2',
      'action': 'proof',
      'loan_ref': '',
      'summary': {
        'role': 'owner',
        'lines': [
          {'label': 'This signature never moves funds', 'amount': ''},
          {'label': 'Site', 'amount': 'http://127.0.0.1:8087'},
        ],
      },
      'pset': 'cHNldP8B',
      'challenge': _challenge,
      'callback': 'http://127.0.0.1:8087/wallet/requests/prf_1/signed',
      'expires_at': 1900000000,
    };

WalletSummary _wallet({
  bool hardware = false,
  String? model,
  bool liquid = true,
}) =>
    WalletSummary(
      id: 'w',
      name: hardware ? 'Jade' : 'Alice',
      type: WalletType.singlesig,
      network: WalletNetwork.testnet,
      balanceSats: 0,
      txCount: 0,
      lastSyncAt: DateTime.utc(2026, 10, 3),
      typeLabel: hardware ? 'Hardware (${model ?? 'Jade'})' : 'Software',
      liquidEnabled: liquid,
      deviceModel: hardware ? (model ?? 'Blockstream Jade') : null,
      masterFingerprint: '73c5da0a',
    );

void main() {
  group('the challenge on a request', () {
    test('a v1.1 connect carries it, verbatim', () {
      final r = ProtocolRequest.fromJson(_connect());
      expect(r.challenge, _challenge);
      expect(r.isProof, isFalse);
    });

    test('a v1 connect has none, and a blank one counts as none', () {
      expect(ProtocolRequest.fromJson(_connect(challenge: null)).challenge, isNull);
      expect(ProtocolRequest.fromJson(_connect(challenge: '  ')).challenge, isNull);
      expect(ProtocolRequest.fromJson(_connect(challenge: 42)).challenge, isNull);
    });

    test('a proof signing request is recognised, with the 0.1.0 fields optional',
        () {
      final r = ProtocolRequest.fromJson(_proofSign());
      expect(r.isProof, isTrue);
      expect(r.actionLabel, 'Proof of key');
      expect(r.challenge, _challenge);
      expect(r.escrow, isNull);
      expect(r.loanRef, '');
      expect(r.summary!.role, 'owner');
      // It still has to pass the ordinary checks: id, pset, network, origin.
      final link = ProtocolLink.parse(
          'templar://sign?url=http%3A%2F%2F127.0.0.1%3A8087%2Fwallet%2Frequests%2Fprf_1&nonce=n2');
      validateProtocolRequest(link, r, activeNetwork: 'liquid-regtest');
    });

    test('surrounding whitespace is part of the challenge, not trimmed', () {
      final r = ProtocolRequest.fromJson(_connect(challenge: ' $_challenge '));
      expect(r.challenge, ' $_challenge ');
    });
  });

  group('action labels', () {
    test('proof joins the vocabulary; empty is the generic request', () {
      expect(protocolActionLabel('proof'), 'Proof of key');
      expect(protocolActionLabel('origination'), 'Loan origination');
      expect(protocolActionLabel(''), 'Signing request');
      expect(protocolActionLabel('custom'), 'custom');
    });
  });

  group('bridge answers', () {
    test('a check decodes', () {
      final c = ProtocolCheck.fromJson({
        'pset_base64': ' cHNldP8B ',
        'loan_key': '[73c5da0a/2121h/1h/0h]tpubX',
        'fingerprint': '73c5da0a',
      });
      expect(c.psetBase64, 'cHNldP8B');
      expect(c.loanKey, startsWith('[73c5da0a/'));
      expect(c.fingerprint, '73c5da0a');
    });

    test('a verdict decodes, and a missing flag is a refusal', () {
      final yes = ProtocolCheckVerdict.fromJson(
          {'is_check': true, 'reason': null, 'loan_key_fingerprint': '73c5da0a'});
      expect(yes.isCheck, isTrue);
      expect(yes.reason, isNull);
      expect(yes.loanKeyFingerprint, '73c5da0a');
      final no = ProtocolCheckVerdict.fromJson(
          {'is_check': false, 'reason': 'not a check PSET: worth something'});
      expect(no.isCheck, isFalse);
      expect(no.reason, contains('worth something'));
      expect(ProtocolCheckVerdict.fromJson({}).isCheck, isFalse);
    });
  });

  group('which wallets take part', () {
    test('a software Liquid wallet connects and signs', () {
      expect(protocolWalletFits(_wallet(), connect: true), isTrue);
      expect(protocolWalletFits(_wallet(), connect: false), isTrue);
      expect(protocolWalletFits(_wallet(liquid: false), connect: true), isFalse);
    });

    test('a Jade connects now (87h loan key) and signs; other devices do not',
        () {
      final jade = _wallet(hardware: true);
      expect(protocolWalletIsJade(jade), isTrue);
      expect(protocolWalletFits(jade, connect: true), isTrue);
      expect(protocolWalletFits(jade, connect: false), isTrue);
      final ledger = _wallet(hardware: true, model: 'Ledger Nano S');
      expect(protocolWalletIsJade(ledger), isFalse);
      expect(protocolWalletFits(ledger, connect: true), isFalse);
      expect(protocolWalletFits(ledger, connect: false), isFalse);
    });

    test('the Jade proof message says what is missing and what to do', () {
      expect(kProtocolJadeProofUnsupported, contains('not supported yet'));
      expect(kProtocolJadeProofUnsupported, contains('software wallet'));
      expect(kProtocolProofStatement, 'This signature never moves funds');
    });
  });
}
