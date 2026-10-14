import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'sync_auth.dart';

const _storage = FlutterSecureStorage();
const _identityKey = 'littlecheck-lan-identity-v1';
const _peerKey = 'littlecheck-lan-peer-v1';

class SyncIdentity {
  const SyncIdentity(this.deviceId, this.certificate, this.privateKey);
  final String deviceId;
  final String certificate;
  final String privateKey;

  String get fingerprint {
    final der = base64Decode(
      certificate.replaceAll(RegExp(r'-----[^-]+-----|\s'), ''),
    );
    return sha256.convert(der).toString();
  }

  SecurityContext get context => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certificate))
    ..usePrivateKeyBytes(utf8.encode(privateKey));

  static Future<SyncIdentity> load() async {
    final existing = await _storage.read(key: _identityKey);
    if (existing != null) {
      final value = jsonDecode(existing) as Map<String, dynamic>;
      final identity = SyncIdentity(
        value['deviceId'] as String,
        value['certificate'] as String,
        value['privateKey'] as String,
      );
      identity.context;
      return identity;
    }
    final identity = await compute(generateSyncIdentity, 0);
    await _storage.write(
      key: _identityKey,
      value: jsonEncode({
        'deviceId': identity.deviceId,
        'certificate': identity.certificate,
        'privateKey': identity.privateKey,
      }),
    );
    return identity;
  }
}

SyncIdentity generateSyncIdentity(int _) {
  final pair = CryptoUtils.generateRSAKeyPair();
  final privateKey = pair.privateKey as RSAPrivateKey;
  final publicKey = pair.publicKey as RSAPublicKey;
  final id = randomSyncToken(bytes: 18);
  final csr = X509Utils.generateRsaCsrPem(
    {'CN': 'Little Check $id'},
    privateKey,
    publicKey,
  );
  final certificate = X509Utils.generateSelfSignedCertificate(
    privateKey,
    csr,
    3650,
  );
  return SyncIdentity(
    id,
    certificate,
    CryptoUtils.encodeRSAPrivateKeyToPem(privateKey),
  );
}

class SyncPeer {
  const SyncPeer({
    required this.deviceId,
    required this.host,
    required this.port,
    required this.fingerprint,
    required this.secret,
  });
  final String deviceId, host, fingerprint, secret;
  final int port;
  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'host': host,
    'port': port,
    'fingerprint': fingerprint,
    'secret': secret,
  };
  factory SyncPeer.fromJson(Map<String, dynamic> value) {
    final peer = SyncPeer(
      deviceId: value['deviceId'] as String,
      host: value['host'] as String,
      port: value['port'] as int,
      fingerprint: value['fingerprint'] as String,
      secret: value['secret'] as String,
    );
    if (!RegExp(r'^[a-zA-Z0-9_-]{8,80}$').hasMatch(peer.deviceId) ||
        peer.secret.length < 32 ||
        peer.secret.length > 256 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(peer.fingerprint) ||
        peer.port < 1 ||
        peer.port > 65535) {
      throw const FormatException('配对记录损坏，请重新配对');
    }
    return peer;
  }
  static Future<SyncPeer?> load() async {
    final value = await _storage.read(key: _peerKey);
    return value == null
        ? null
        : SyncPeer.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  Future<void> save() =>
      _storage.write(key: _peerKey, value: jsonEncode(toJson()));
  static Future<void> forget() => _storage.delete(key: _peerKey);
}
