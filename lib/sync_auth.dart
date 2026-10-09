import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class SyncPairingInvite {
  const SyncPairingInvite({
    required this.deviceId,
    required this.inviteId,
    required this.oneTimeSecret,
    required this.expiresAt,
    required this.host,
    required this.port,
    this.certificateFingerprint,
  });

  final String deviceId;
  final String inviteId;
  final String oneTimeSecret;
  final DateTime expiresAt;
  final String host;
  final int port;
  final String? certificateFingerprint;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'deviceId': deviceId,
    'inviteId': inviteId,
    'oneTimeSecret': oneTimeSecret,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'host': host,
    'port': port,
    'certificateFingerprint': certificateFingerprint,
  };

  factory SyncPairingInvite.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 ||
        json['deviceId'] is! String ||
        json['inviteId'] is! String ||
        json['oneTimeSecret'] is! String ||
        json['expiresAt'] is! String ||
        json['host'] is! String ||
        json['port'] is! int ||
        (json['certificateFingerprint'] != null &&
            json['certificateFingerprint'] is! String)) {
      throw const FormatException('配对邀请格式无效');
    }
    final invite = SyncPairingInvite(
      deviceId: json['deviceId'] as String,
      inviteId: json['inviteId'] as String,
      oneTimeSecret: json['oneTimeSecret'] as String,
      expiresAt: DateTime.parse(json['expiresAt'] as String).toUtc(),
      host: json['host'] as String,
      port: json['port'] as int,
      certificateFingerprint: json['certificateFingerprint'] as String?,
    );
    invite.validate(checkExpiry: false);
    return invite;
  }

  void validate({DateTime? now, bool checkExpiry = true}) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{8,80}$').hasMatch(deviceId) ||
        !RegExp(r'^[a-zA-Z0-9_-]{16,120}$').hasMatch(inviteId) ||
        !RegExp(r'^[a-zA-Z0-9_-]{32,160}$').hasMatch(oneTimeSecret) ||
        host.trim().isEmpty ||
        host.length > 255 ||
        port < 1 ||
        port > 65535) {
      throw const FormatException('配对邀请格式无效');
    }
    final fingerprint = certificateFingerprint;
    if (fingerprint != null &&
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(fingerprint)) {
      throw const FormatException('证书指纹格式无效');
    }
    if (checkExpiry && !expiresAt.isAfter((now ?? DateTime.now()).toUtc())) {
      throw const FormatException('配对邀请已过期');
    }
  }
}

String randomSyncToken({int bytes = 32, Random? random}) {
  if (bytes < 16 || bytes > 128) {
    throw const FormatException('随机令牌长度无效');
  }
  final source = random ?? Random.secure();
  final data = Uint8List.fromList(
    List<int>.generate(bytes, (_) => source.nextInt(256)),
  );
  return base64UrlEncode(data).replaceAll('=', '');
}

SyncPairingInvite createPairingInvite({
  required String deviceId,
  required String host,
  required int port,
  required DateTime now,
  Duration lifetime = const Duration(minutes: 5),
  String? certificateFingerprint,
  Random? random,
}) {
  final invite = SyncPairingInvite(
    deviceId: deviceId,
    inviteId: randomSyncToken(bytes: 18, random: random),
    oneTimeSecret: randomSyncToken(bytes: 32, random: random),
    expiresAt: now.toUtc().add(lifetime),
    host: host,
    port: port,
    certificateFingerprint: certificateFingerprint,
  );
  invite.validate(now: now);
  return invite;
}

class SyncRequestAuth {
  const SyncRequestAuth({
    required this.deviceId,
    required this.timestamp,
    required this.nonce,
    required this.bodyHash,
    required this.signature,
  });

  final String deviceId;
  final DateTime timestamp;
  final String nonce;
  final String bodyHash;
  final String signature;

  Map<String, String> toHeaders() => {
    'x-littlecheck-device': deviceId,
    'x-littlecheck-timestamp': timestamp.toUtc().toIso8601String(),
    'x-littlecheck-nonce': nonce,
    'x-littlecheck-body-sha256': bodyHash,
    'x-littlecheck-signature': signature,
  };

  factory SyncRequestAuth.fromHeaders(Map<String, String> headers) {
    final deviceId = headers['x-littlecheck-device'];
    final timestamp = headers['x-littlecheck-timestamp'];
    final nonce = headers['x-littlecheck-nonce'];
    final bodyHash = headers['x-littlecheck-body-sha256'];
    final signature = headers['x-littlecheck-signature'];
    if (deviceId == null ||
        timestamp == null ||
        nonce == null ||
        bodyHash == null ||
        signature == null) {
      throw const FormatException('同步请求缺少认证信息');
    }
    return SyncRequestAuth(
      deviceId: deviceId,
      timestamp: DateTime.parse(timestamp).toUtc(),
      nonce: nonce,
      bodyHash: bodyHash,
      signature: signature,
    );
  }
}

String syncBodyHash(List<int> body) => sha256.convert(body).toString();

SyncRequestAuth signSyncRequest({
  required String deviceId,
  required String pairSecret,
  required String method,
  required String path,
  required List<int> body,
  required DateTime now,
  String? nonce,
}) {
  _validateRequestIdentity(deviceId, pairSecret);
  final bodyHash = syncBodyHash(body);
  final requestNonce = nonce ?? randomSyncToken(bytes: 18);
  final timestamp = now.toUtc();
  final signature = _syncSignature(
    pairSecret: pairSecret,
    method: method,
    path: path,
    deviceId: deviceId,
    timestamp: timestamp,
    nonce: requestNonce,
    bodyHash: bodyHash,
  );
  return SyncRequestAuth(
    deviceId: deviceId,
    timestamp: timestamp,
    nonce: requestNonce,
    bodyHash: bodyHash,
    signature: signature,
  );
}

void verifySyncRequest({
  required SyncRequestAuth auth,
  required String pairSecret,
  required String method,
  required String path,
  required List<int> body,
  required DateTime now,
  Duration allowedClockSkew = const Duration(minutes: 2),
}) {
  _validateRequestIdentity(auth.deviceId, pairSecret);
  if (!RegExp(r'^[a-zA-Z0-9_-]{16,160}$').hasMatch(auth.nonce) ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(auth.bodyHash) ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(auth.signature)) {
    throw const FormatException('同步请求认证格式无效');
  }
  final delta = now.toUtc().difference(auth.timestamp).abs();
  if (delta > allowedClockSkew) {
    throw const FormatException('同步请求时间已失效');
  }
  final actualBodyHash = syncBodyHash(body);
  if (!_constantTimeEquals(actualBodyHash, auth.bodyHash)) {
    throw const FormatException('同步请求正文校验失败');
  }
  final expected = _syncSignature(
    pairSecret: pairSecret,
    method: method,
    path: path,
    deviceId: auth.deviceId,
    timestamp: auth.timestamp,
    nonce: auth.nonce,
    bodyHash: auth.bodyHash,
  );
  if (!_constantTimeEquals(expected, auth.signature)) {
    throw const FormatException('同步请求签名无效');
  }
}

String _syncSignature({
  required String pairSecret,
  required String method,
  required String path,
  required String deviceId,
  required DateTime timestamp,
  required String nonce,
  required String bodyHash,
}) {
  final canonical = [
    method.toUpperCase(),
    path,
    deviceId,
    timestamp.toUtc().toIso8601String(),
    nonce,
    bodyHash,
  ].join('\n');
  return Hmac(
    sha256,
    utf8.encode(pairSecret),
  ).convert(utf8.encode(canonical)).toString();
}

void _validateRequestIdentity(String deviceId, String pairSecret) {
  if (!RegExp(r'^[a-zA-Z0-9_-]{8,80}$').hasMatch(deviceId) ||
      pairSecret.length < 32 ||
      pairSecret.length > 256) {
    throw const FormatException('同步设备认证信息无效');
  }
}

bool _constantTimeEquals(String left, String right) {
  final a = utf8.encode(left);
  final b = utf8.encode(right);
  var difference = a.length ^ b.length;
  final length = max(a.length, b.length);
  for (var i = 0; i < length; i++) {
    difference |= (i < a.length ? a[i] : 0) ^ (i < b.length ? b[i] : 0);
  }
  return difference == 0;
}

class SyncNonceCache {
  SyncNonceCache({
    this.ttl = const Duration(minutes: 5),
    this.maxEntries = 2048,
  });

  final Duration ttl;
  final int maxEntries;
  final Map<String, DateTime> _seen = {};

  void consume(String deviceId, String nonce, DateTime now) {
    final current = now.toUtc();
    _seen.removeWhere((_, timestamp) => current.difference(timestamp) > ttl);
    final key = '$deviceId:$nonce';
    if (_seen.containsKey(key)) {
      throw const FormatException('同步请求已处理，拒绝重复请求');
    }
    if (_seen.length >= maxEntries) {
      throw const FormatException('同步请求过于频繁，请稍后重试');
    }
    _seen[key] = current;
  }
}
