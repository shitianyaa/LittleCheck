import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'storage.dart';
import 'sync_auth.dart';
import 'sync_identity.dart';
import 'sync_merge.dart';
import 'sync_models.dart';

const syncTimeout = Duration(seconds: 60);
const _maxMessage = 40 * 1024 * 1024;
const _pairMaxMessage = 8 * 1024;
const _controlMaxMessage = 1024 * 1024;
const _pairReadTimeout = Duration(seconds: 10);

int _requestMaxBytes(String path) => switch (path) {
  '/pair' || '/begin' || '/ack' => _pairMaxMessage,
  '/contents' => _controlMaxMessage,
  '/commit' => _maxMessage,
  _ => throw const FormatException('未知同步操作'),
};

typedef SyncNetworkAddress = ({String address, String interfaceName});

List<SyncNetworkAddress> sortedSyncAddresses(
  Iterable<SyncNetworkAddress> addresses,
) {
  int priority(SyncNetworkAddress value) {
    if (value.address.startsWith('169.254.')) return 2;
    if (RegExp(
      r'vmware|vmnet|virtual|vbox|hyper-v|wsl|vpn|tailscale|wireguard|bluetooth|蓝牙',
      caseSensitive: false,
    ).hasMatch(value.interfaceName)) {
      return 1;
    }
    return 0;
  }

  final result =
      addresses
          .where(
            (a) => !a.address.startsWith('127.') && isSyncLanAddress(a.address),
          )
          .toList()
        ..sort((a, b) {
          final order = priority(a).compareTo(priority(b));
          return order != 0 ? order : a.address.compareTo(b.address);
        });
  final seen = <String>{};
  return result.where((a) => seen.add(a.address)).toList();
}

Future<List<int>> _readBytes(
  Stream<List<int>> stream, {
  int maxBytes = _maxMessage,
  Duration timeout = syncTimeout,
}) async {
  final bytes = <int>[];
  final iterator = StreamIterator(stream);
  final elapsed = Stopwatch()..start();
  try {
    while (true) {
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('同步请求读取超时');
      }
      if (!await iterator.moveNext().timeout(remaining)) break;
      final chunk = iterator.current;
      if (bytes.length + chunk.length > maxBytes) {
        throw const FormatException('同步消息超过该操作允许的大小');
      }
      bytes.addAll(chunk);
    }
  } finally {
    await iterator.cancel();
  }
  return bytes;
}

Future<Map<String, dynamic>> _readJson(Stream<List<int>> stream) async {
  final bytes = await _readBytes(stream);
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, dynamic>) throw const FormatException('同步消息格式无效');
  return decoded;
}

Map<String, String> _hashes(Object? raw) {
  if (raw is! Map || raw.length > 10000) {
    throw const FormatException('同步基线格式无效');
  }
  final result = <String, String>{};
  for (final entry in raw.entries) {
    validateSyncId(entry.key);
    if (entry.value is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.value)) {
      throw const FormatException('同步基线哈希无效');
    }
    result[entry.key as String] = entry.value as String;
  }
  return result;
}

Map<String, String> _contents(Object? raw) {
  if (raw is! Map || raw.length > 10000) {
    throw const FormatException('同步正文格式无效');
  }
  final result = <String, String>{};
  for (final entry in raw.entries) {
    validateSyncId(entry.key);
    if (entry.value is! String ||
        utf8.encode(entry.value).length > 2 * 1024 * 1024) {
      throw const FormatException('同步正文无效或超过 2 MiB');
    }
    result[entry.key as String] = entry.value as String;
  }
  return result;
}

class LanSyncServer {
  LanSyncServer({
    required this.store,
    required this.identity,
    required this.approvePair,
    required this.savePeer,
    this.peer,
    this.onStatus,
  });
  final LocalStore store;
  final SyncIdentity identity;
  final Future<bool> Function(String deviceId) approvePair;
  final Future<void> Function(SyncPeer peer) savePeer;
  final void Function(String status)? onStatus;
  SyncPeer? peer;
  HttpServer? _server;
  SyncPairingInvite? invite;
  final _nonces = SyncNonceCache();
  bool _busy = false;
  int _failedPairings = 0;
  String? _session;
  DateTime? _sessionExpires;
  SyncSnapshot? _snapshot;
  String? _committedHash;
  bool get running => _server != null;
  int get port => _server!.port;

  Future<void> start(String host, {int listenPort = 43821}) async {
    if (running) throw const FormatException('同步服务已开启');
    final address = InternetAddress.tryParse(host);
    if (address == null ||
        address.type != InternetAddressType.IPv4 ||
        !isSyncLanAddress(host)) {
      throw const FormatException('请选择 IPv4 局域网地址');
    }
    _server = await HttpServer.bindSecure(
      address,
      listenPort,
      identity.context,
    );
    _server!.idleTimeout = syncTimeout;
    _server!.listen(
      (request) {
        unawaited(_handle(request));
      },
      onError: (Object error) {
        onStatus?.call('同步服务连接失败，请关闭后重新开启');
      },
    );
    renewInvite(host);
  }

  void renewInvite(String host) {
    _failedPairings = 0;
    invite = createPairingInvite(
      deviceId: identity.deviceId,
      host: host,
      port: port,
      now: DateTime.now(),
      certificateFingerprint: identity.fingerprint,
    );
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    invite = null;
    _session = null;
    _snapshot = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method != 'POST' ||
          request.uri.query.isNotEmpty ||
          !running) {
        throw const FormatException('无效的同步请求');
      }
      final path = request.uri.path;
      final maxBytes = _requestMaxBytes(path);
      if (path != '/pair' &&
          (peer == null ||
              request.headers.value('x-littlecheck-device') !=
                  peer!.deviceId)) {
        throw const FormatException('设备尚未配对或身份不匹配');
      }
      if (request.contentLength > maxBytes) {
        throw const FormatException('同步消息超过该操作允许的大小');
      }
      final bytes = await _readBytes(
        request,
        maxBytes: maxBytes,
        timeout: path == '/pair' ? _pairReadTimeout : syncTimeout,
      );
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('同步请求格式无效');
      }
      if (_busy) {
        request.response.statusCode = HttpStatus.conflict;
        throw const FormatException('另一同步操作正在进行，请稍后重试');
      }
      _busy = true;
      try {
        Map<String, dynamic> result;
        if (path == '/pair') {
          result = await _pair(raw);
        } else {
          final boundPeer = peer;
          if (boundPeer == null) throw const FormatException('设备尚未配对');
          final headers = <String, String>{};
          request.headers.forEach((name, values) {
            if (values.length == 1) headers[name] = values.single;
          });
          final auth = SyncRequestAuth.fromHeaders(headers);
          if (auth.deviceId != boundPeer.deviceId) {
            throw const FormatException('配对身份不匹配');
          }
          verifySyncRequest(
            auth: auth,
            pairSecret: boundPeer.secret,
            method: request.method,
            path: path,
            body: bytes,
            now: DateTime.now(),
          );
          _nonces.consume(auth.deviceId, auth.nonce, DateTime.now());
          result = await _dispatch(path, raw);
        }
        request.response.headers.contentType = ContentType.json;
        final response = utf8.encode(jsonEncode(result));
        if (response.length > _maxMessage) {
          throw const FormatException('同步响应超过 40 MiB，未截断内容');
        }
        request.response.add(response);
      } finally {
        _busy = false;
      }
    } catch (error) {
      if (request.response.statusCode == HttpStatus.ok) {
        request.response.statusCode = HttpStatus.badRequest;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'error': error is FormatException
              ? error.message
              : '连接、文件写入或配对失败，请重试；本地数据已保留',
        }),
      );
      onStatus?.call('同步未完成，请查看手机提示并重试');
    } finally {
      try {
        await request.response.close();
      } catch (_) {
        /* Disconnected peer. */
      }
    }
  }

  Future<Map<String, dynamic>> _pair(Map<String, dynamic> raw) async {
    final active = invite;
    if (active == null) throw const FormatException('配对邀请失效，请在电脑重新生成');
    active.validate();
    if (raw['inviteId'] != active.inviteId) {
      throw const FormatException('配对信息不正确');
    }
    if (raw['secret'] != active.oneTimeSecret) {
      if (++_failedPairings >= 5) invite = null;
      throw const FormatException('配对信息不正确');
    }
    final deviceId = raw['deviceId'];
    if (deviceId is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{8,80}$').hasMatch(deviceId) ||
        deviceId == identity.deviceId) {
      throw const FormatException('配对设备身份无效');
    }
    if (peer != null && peer!.deviceId != deviceId) {
      throw const FormatException('电脑已配对其他设备，请先解除配对');
    }
    invite = null;
    if (!await approvePair(deviceId).timeout(syncTimeout)) {
      throw const FormatException('电脑未同意配对');
    }
    if (!running) throw const FormatException('同步服务已关闭');
    final next = SyncPeer(
      deviceId: deviceId,
      host: active.host,
      port: active.port,
      fingerprint: identity.fingerprint,
      secret: randomSyncToken(),
    );
    await savePeer(next);
    peer = next;
    onStatus?.call('手机已配对，可在手机点击立即同步');
    return {'deviceId': identity.deviceId, 'secret': next.secret};
  }

  Future<Map<String, dynamic>> _dispatch(
    String path,
    Map<String, dynamic> raw,
  ) async {
    if (path == '/begin') {
      _snapshot = await store.syncSnapshot();
      _session = randomSyncToken();
      _sessionExpires = DateTime.now().add(const Duration(minutes: 10));
      _committedHash = null;
      onStatus?.call('手机已连接，正在比较变化');
      return {
        'session': _session,
        'manifest': _snapshot!.manifest.toJson(),
        'notes': store.syncBaseline(peer!.deviceId, kind: 'notes'),
        'folders': store.syncBaseline(peer!.deviceId, kind: 'folders'),
      };
    }
    if (raw['session'] != _session ||
        _session == null ||
        _sessionExpires == null ||
        !DateTime.now().isBefore(_sessionExpires!)) {
      throw const FormatException('同步会话已失效，请重新同步');
    }
    final snapshot = _snapshot!;
    if (path == '/contents') {
      final ids = raw['ids'];
      if (ids is! List ||
          ids.length > 10000 ||
          ids.any((id) => !snapshot.contents.containsKey(id))) {
        throw const FormatException('请求的笔记不存在');
      }
      return {
        'contents': {for (final id in ids) id as String: snapshot.contents[id]},
      };
    }
    if (path == '/commit') {
      final manifest = SyncManifest.fromJson(
        Map<String, dynamic>.from(raw['manifest'] as Map),
      );
      final changed = _contents(raw['contents']);
      final contents = <String, String>{};
      for (final entry in manifest.notes.entries) {
        final body = changed[entry.key] ?? snapshot.contents[entry.key];
        if (body == null) throw const FormatException('缺少上传正文');
        contents[entry.key] = body;
      }
      final target = SyncSnapshot(manifest, contents);
      await store.applySyncSnapshot(
        target,
        expectedFingerprint: snapshot.manifest.fingerprint,
      );
      _committedHash = manifest.fingerprint;
      onStatus?.call('电脑已保存，等待手机确认');
      return {'fingerprint': manifest.fingerprint};
    }
    if (path == '/ack') {
      final current = await store.syncManifest();
      if (_committedHash == null ||
          raw['fingerprint'] != _committedHash ||
          current.fingerprint != _committedHash) {
        throw const FormatException('确认前电脑内容有变化，请重新同步');
      }
      await store.saveSyncBaseline(
        peer!.deviceId,
        notes: syncBaselineHashes(current, 'notes'),
        folders: syncBaselineHashes(current, 'folders'),
      );
      _session = null;
      _snapshot = null;
      onStatus?.call('同步完成');
      return {'ok': true};
    }
    throw const FormatException('未知同步操作');
  }
}

bool isSyncLanAddress(String host) {
  final parts = host.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((p) => p == null || p < 0 || p > 255)) {
    return false;
  }
  return parts[0] == 10 ||
      parts[0] == 127 ||
      (parts[0] == 192 && parts[1] == 168) ||
      (parts[0] == 172 && parts[1]! >= 16 && parts[1]! <= 31) ||
      (parts[0] == 169 && parts[1] == 254);
}

class LanSyncClient {
  LanSyncClient(this.deviceId, this.peer) {
    if (!isSyncLanAddress(peer.host)) {
      throw const FormatException('同步地址必须是 IPv4 局域网地址');
    }
    _http = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 10)
      ..badCertificateCallback = ((cert, host, port) =>
          host == peer.host &&
          port == peer.port &&
          sha256.convert(cert.der).toString() == peer.fingerprint);
  }
  final String deviceId;
  final SyncPeer peer;
  late final HttpClient _http;
  void close() => _http.close(force: true);

  Future<Map<String, dynamic>> request(
    String path,
    Map<String, dynamic> data, {
    bool authenticate = true,
    void Function()? onConnected,
  }) async {
    final body = utf8.encode(jsonEncode(data));
    if (body.length > _requestMaxBytes(path)) {
      throw const FormatException('同步消息超过该操作允许的大小');
    }
    final HttpClientRequest request;
    try {
      request = await _http
          .postUrl(
            Uri(scheme: 'https', host: peer.host, port: peer.port, path: path),
          )
          .timeout(syncTimeout);
    } on SocketException {
      throw FormatException(
        '无法连接电脑 ${peer.host}:${peer.port}。请核对电脑监听地址；同一 Wi-Fi 也可能禁止设备互通，可用手机热点测试。',
      );
    } on TimeoutException {
      throw FormatException('连接电脑 ${peer.host}:${peer.port} 超时，尚未进入配对或同步。');
    }
    onConnected?.call();
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    if (authenticate) {
      signSyncRequest(
        deviceId: deviceId,
        pairSecret: peer.secret,
        method: 'POST',
        path: path,
        body: body,
        now: DateTime.now(),
      ).toHeaders().forEach(request.headers.set);
    }
    request.add(body);
    final response = await request.close().timeout(syncTimeout);
    final cert = response.certificate;
    if (cert == null ||
        sha256.convert(cert.der).toString() != peer.fingerprint) {
      throw const FormatException('电脑身份有变化，请重新扫码核对');
    }
    if (response.isRedirect) throw const FormatException('同步服务不允许重定向');
    final result = await _readJson(response).timeout(syncTimeout);
    if (response.statusCode != HttpStatus.ok) {
      throw FormatException(
        result['error'] is String ? result['error'] as String : '同步请求失败',
      );
    }
    return result;
  }

  static Future<SyncPeer> pair(
    String deviceId,
    SyncPairingInvite invite, {
    void Function(String status)? onStatus,
  }) async {
    invite.validate();
    if (invite.certificateFingerprint == null) {
      throw const FormatException('配对信息缺少电脑证书身份');
    }
    final provisional = SyncPeer(
      deviceId: invite.deviceId,
      host: invite.host,
      port: invite.port,
      fingerprint: invite.certificateFingerprint!.toLowerCase(),
      secret: invite.oneTimeSecret,
    );
    final client = LanSyncClient(deviceId, provisional);
    try {
      onStatus?.call('正在连接电脑 ${invite.host}:${invite.port}');
      final result = await client.request(
        '/pair',
        {
          'deviceId': deviceId,
          'inviteId': invite.inviteId,
          'secret': invite.oneTimeSecret,
        },
        authenticate: false,
        onConnected: () => onStatus?.call('已连接电脑，请在电脑确认配对（最多 60 秒）'),
      );
      if (result['deviceId'] != invite.deviceId ||
          result['secret'] is! String) {
        throw const FormatException('配对响应无效');
      }
      return SyncPeer.fromJson({
        ...provisional.toJson(),
        'secret': result['secret'],
      });
    } finally {
      client.close();
    }
  }

  Future<SyncMerge> sync(
    LocalStore store, {
    required Future<bool> Function(SyncPreview preview) confirm,
    void Function(String)? onStatus,
  }) async {
    var local = await store.syncSnapshot();
    final begin = await request('/begin', {});
    final session = begin['session'];
    if (session is! String) throw const FormatException('同步会话格式无效');
    final remote = SyncManifest.fromJson(
      Map<String, dynamic>.from(begin['manifest'] as Map),
    );
    final pending = await store.readSyncTransfer();
    if (pending != null) {
      final pendingTarget = SyncSnapshot(
        SyncManifest.fromJson(
          Map<String, dynamic>.from(pending['manifest'] as Map),
        ),
        _contents(pending['contents']),
      );
      pendingTarget.validate();
      if (pending['peerId'] == peer.deviceId &&
          remote.fingerprint == pendingTarget.manifest.fingerprint &&
          local.manifest.fingerprint == pending['expectedFingerprint']) {
        onStatus?.call('正在恢复上次电脑已保存的同步');
        await store.applySyncSnapshot(
          pendingTarget,
          expectedFingerprint: local.manifest.fingerprint,
        );
        local = await store.syncSnapshot();
      }
      await store.clearSyncTransfer();
    }
    final missing = remote.notes.keys
        .where(
          (id) =>
              local.manifest.notes[id]?.contentHash !=
              remote.notes[id]!.contentHash,
        )
        .toList();
    final downloaded = missing.isEmpty
        ? <String, String>{}
        : _contents(
            (await request('/contents', {
              'session': session,
              'ids': missing,
            }))['contents'],
          );
    final remoteContents = {
      for (final id in remote.notes.keys)
        id: downloaded[id] ?? local.contents[id]!,
    };
    final merge = mergeSyncSnapshots(
      leftDeviceId: deviceId,
      rightDeviceId: peer.deviceId,
      left: local,
      right: SyncSnapshot(remote, remoteContents),
      noteBaseline: commonSyncBaseline(
        store.syncBaseline(peer.deviceId, kind: 'notes'),
        _hashes(begin['notes']),
      ),
      folderBaseline: commonSyncBaseline(
        store.syncBaseline(peer.deviceId, kind: 'folders'),
        _hashes(begin['folders']),
      ),
    );
    final remoteSnapshot = SyncSnapshot(remote, remoteContents);
    if (!await confirm(SyncPreview(local, remoteSnapshot, merge))) {
      throw const FormatException('已取消本次同步');
    }
    final current = await store.syncManifest();
    if (store.hasOpenNotes ||
        current.fingerprint != local.manifest.fingerprint) {
      throw const FormatException('手机内容已变化，请重新同步');
    }
    onStatus?.call('正在保存到电脑');
    final target = merge.snapshot;
    await store.saveSyncTransfer(
      peer.deviceId,
      local.manifest.fingerprint,
      target,
    );
    final changed = {
      for (final id in target.manifest.notes.keys)
        if (remote.notes[id]?.contentHash !=
            target.manifest.notes[id]!.contentHash)
          id: target.contents[id],
    };
    final committed = await request('/commit', {
      'session': session,
      'manifest': target.manifest.toJson(),
      'contents': changed,
    });
    if (committed['fingerprint'] != target.manifest.fingerprint) {
      throw const FormatException('电脑确认结果不一致');
    }
    onStatus?.call('电脑已保存，正在保存到手机');
    await store.applySyncSnapshot(
      target,
      expectedFingerprint: local.manifest.fingerprint,
    );
    await request('/ack', {
      'session': session,
      'fingerprint': target.manifest.fingerprint,
    });
    await store.saveSyncBaseline(
      peer.deviceId,
      notes: syncBaselineHashes(target.manifest, 'notes'),
      folders: syncBaselineHashes(target.manifest, 'folders'),
    );
    await store.clearSyncTransfer();
    onStatus?.call('同步完成');
    return merge;
  }
}

class SyncPreview {
  const SyncPreview(this.local, this.remote, this.merge);
  final SyncSnapshot local, remote;
  final SyncMerge merge;

  String _title(String content) {
    final first = content
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .firstOrNull;
    if (first == null) return '未命名笔记';
    final title = first.replaceFirst(RegExp(r'^\s*#+\s*'), '').trim();
    return title.isEmpty ? '未命名笔记' : title;
  }

  List<String> get changes {
    final result = <String>[];
    void compare(String label, SyncSnapshot before) {
      for (final note in merge.snapshot.manifest.notes.values) {
        final previous = before.manifest.notes[note.id];
        if (previous?.stateHash == note.stateHash) continue;
        final text = _title(merge.snapshot.contents[note.id]!);
        final action = note.id.startsWith('conflict_')
            ? '冲突副本'
            : previous == null
            ? '新增'
            : previous.trashed != note.trashed
            ? (note.trashed ? '移入回收站' : '从回收站恢复')
            : previous.folderId != note.folderId &&
                  previous.contentHash == note.contentHash
            ? '移动文件夹'
            : '更新';
        result.add('$label · $action · $text');
      }
      for (final id in merge.snapshot.manifest.noteTombstones) {
        if (before.manifest.notes.containsKey(id)) {
          final content = before.contents[id];
          result.add(
            '$label · 永久删除 · ${content == null ? id : _title(content)}',
          );
        }
      }
      for (final folder in merge.snapshot.manifest.folders.values) {
        if (before.manifest.folders[folder.id]?.stateHash != folder.stateHash) {
          result.add('$label · 文件夹 · ${folder.name}');
        }
      }
      for (final id in merge.snapshot.manifest.folderTombstones) {
        if (before.manifest.folders.containsKey(id)) {
          result.add('$label · 删除文件夹 · ${before.manifest.folders[id]!.name}');
        }
      }
    }

    compare('手机', local);
    compare('电脑', remote);
    return result;
  }
}
