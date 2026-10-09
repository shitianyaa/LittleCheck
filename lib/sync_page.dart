import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'storage.dart';
import 'sync_auth.dart';
import 'sync_identity.dart';
import 'sync_transport.dart';

class SyncPage extends StatefulWidget {
  const SyncPage({super.key, required this.store});
  final LocalStore store;
  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  SyncIdentity? _identity;
  SyncPeer? _peer;
  LanSyncServer? _server;
  LanSyncClient? _client;
  List<SyncNetworkAddress> _addresses = [];
  String? _host;
  String _status = '正在加载设备信息';
  bool _busy = true;
  bool _cancelled = false;
  bool get _desktop => defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    unawaited(_run(_load));
  }

  Future<void> _load() async {
    _identity = await SyncIdentity.load();
    _peer = await SyncPeer.load();
    if (_desktop) {
      final remembered = widget.store.settings['lanSyncHost'];
      _host = remembered is String ? remembered : null;
      await _loadAddresses();
    }
    _status = _desktop
        ? '开启后请保持此页面打开'
        : _peer == null
        ? '请扫描电脑上的配对二维码'
        : '已配对，可手动同步';
  }

  Future<void> _loadAddresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    _addresses = sortedSyncAddresses([
      for (final interface in interfaces)
        for (final address in interface.addresses)
          (address: address.address, interfaceName: interface.name),
    ]);
    if (!_addresses.any((a) => a.address == _host)) {
      _host = _addresses.firstOrNull?.address;
    }
  }

  void _setStatus(String value) {
    if (mounted && !_cancelled) setState(() => _status = value);
  }

  Future<void> _run(Future<void> Function() task) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _cancelled = false;
    });
    try {
      await task();
    } catch (error) {
      if (mounted && !_cancelled) {
        _setStatus(
          error is FormatException
              ? error.message
              : error is TimeoutException
              ? '连接超时（60 秒），请检查两端网络并重试'
              : error is HandshakeException
              ? '加密连接或电脑身份核验失败，请核对配对设备，必要时重新扫码'
              : error is FileSystemException
              ? '本地文件保存失败，请检查磁盘空间与权限；保留恢复记录，下次同步会重试'
              : error is PlatformException
              ? '系统安全存储或相机不可用，请检查系统权限；原配对凭据已保留'
              : '连接或保存失败，请检查同一局域网、电脑服务及防火墙后重试。已保存的数据保留。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String message) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _start() async {
    if (_host == null || _identity == null) {
      throw const FormatException('未找到局域网地址，请连接 Wi-Fi 或网线');
    }
    final server = LanSyncServer(
      store: widget.store,
      identity: _identity!,
      peer: _peer,
      approvePair: (id) =>
          _confirm('允许手机配对？', '设备标识：$id\n确认是你的手机后，允许它同步笔记、待办和文件夹。'),
      savePeer: (peer) async {
        await peer.save();
        _peer = peer;
      },
      onStatus: _setStatus,
    );
    await widget.store.setSettings(extra: {'lanSyncHost': _host!});
    await server.start(_host!);
    if (!mounted) {
      await server.close();
      return;
    }
    _server = server;
    _setStatus('已开启，等待手机连接；首次连接可允许 Windows 专用网络防火墙提示');
  }

  Future<void> _stop() async {
    await _server?.close();
    _server = null;
    _setStatus('同步服务已关闭');
  }

  Future<void> _pair(String text) async {
    if (text.length > 4096) throw const FormatException('配对信息过长');
    final raw = jsonDecode(text);
    if (raw is! Map<String, dynamic>) throw const FormatException('配对信息格式无效');
    final invite = SyncPairingInvite.fromJson(raw);
    if (_peer != null &&
        (_peer!.deviceId != invite.deviceId ||
            _peer!.fingerprint !=
                invite.certificateFingerprint?.toLowerCase())) {
      throw const FormatException('与已配对电脑身份不同，请先解除配对并核对新电脑');
    }
    final peer = await LanSyncClient.pair(
      _identity!.deviceId,
      invite,
      onStatus: _setStatus,
    );
    if (!mounted) return;
    await peer.save();
    _peer = peer;
    _setStatus('配对成功，点击立即同步');
  }

  Future<void> _pastePair() async {
    final controller = TextEditingController();
    try {
      final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('输入配对信息'),
          content: TextField(
            controller: controller,
            minLines: 3,
            maxLines: 6,
            maxLength: 4096,
            decoration: const InputDecoration(hintText: '粘贴电脑「复制配对信息」的内容'),
            autocorrect: false,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('配对'),
            ),
          ],
        ),
      );
      if (value != null && mounted) await _run(() => _pair(value));
    } finally {
      controller.dispose();
    }
  }

  Future<void> _scan() async {
    final value = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _ScanPage()),
    );
    if (value != null && mounted) await _run(() => _pair(value));
  }

  Future<bool> _preview(SyncPreview preview) async {
    if (!mounted || _cancelled) return false;
    final changes = preview.changes;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认同步'),
            content: SizedBox(
              width: 480,
              height: 320,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${changes.length} 项变化 · ${preview.merge.conflicts} 处冲突\n冲突保留双方正文，副本在笔记列表标记。',
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: changes.isEmpty
                        ? const Text('两端内容一致，将确认同步状态。')
                        : ListView.builder(
                            itemCount: changes.length,
                            itemBuilder: (_, index) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Text(changes[index]),
                            ),
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('同步'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _sync() async {
    final client = LanSyncClient(_identity!.deviceId, _peer!);
    _client = client;
    _setStatus('正在连接电脑并比较变化');
    try {
      final result = await client.sync(
        widget.store,
        confirm: _preview,
        onStatus: _setStatus,
      );
      _setStatus(
        result.conflicts == 0 ? '同步完成' : '同步完成，保留了 ${result.conflicts} 处冲突副本',
      );
    } finally {
      client.close();
      _client = null;
    }
  }

  Future<void> _forget() async {
    if (!await _confirm('解除配对？', '本地笔记不会删除。两端均解除配对后，可绑定新设备。')) return;
    await _run(() async {
      await _stop();
      final peer = _peer;
      if (peer != null) {
        await widget.store.forgetSyncPeer(peer.deviceId);
      }
      await SyncPeer.forget();
      _peer = null;
      _setStatus('已解除配对');
    });
  }

  @override
  void dispose() {
    _cancelled = true;
    _client?.close();
    unawaited(_server?.close() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final invite = _server?.invite;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('设备同步')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Icon(
                  Icons.devices_rounded,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  _desktop ? '与 Android 同步' : '与 Windows 同步',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  '两端连接同一局域网，电脑保持同步页面打开。同步笔记、待办、文件夹和回收站；AI 密钥、订阅和图片缓存各端保留。',
                ),
                const SizedBox(height: 20),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_status, key: const Key('sync-status')),
                        if (_busy) ...[
                          const SizedBox(height: 12),
                          const LinearProgressIndicator(),
                        ],
                        if (_peer != null) ...[
                          const SizedBox(height: 8),
                          Text('已配对设备：${_peer!.deviceId}'),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (_desktop) ...[
                  if (_addresses.isNotEmpty)
                    DropdownButtonFormField<String>(
                      key: ValueKey(_host),
                      initialValue: _host,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '电脑局域网地址'),
                      items: [
                        for (final address in _addresses)
                          DropdownMenuItem(
                            value: address.address,
                            child: Text(
                              '${address.interfaceName} · ${address.address}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: _busy || _server != null
                          ? null
                          : (value) => setState(() => _host = value),
                    ),
                  TextButton.icon(
                    onPressed: _busy || _server != null
                        ? null
                        : () => _run(() async {
                            await _loadAddresses();
                            _setStatus('地址已刷新；请选择手机能访问的实际网卡');
                          }),
                    icon: const Icon(Icons.refresh),
                    label: const Text('刷新网卡地址'),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(_server == null ? _start : _stop),
                    icon: Icon(
                      _server == null ? Icons.wifi : Icons.stop_circle_outlined,
                    ),
                    label: Text(_server == null ? '开启局域网同步' : '关闭局域网同步'),
                  ),
                  if (invite != null) ...[
                    const SizedBox(height: 20),
                    Center(
                      child: Container(
                        color: Colors.white,
                        padding: const EdgeInsets.all(12),
                        child: QrImageView(
                          data: jsonEncode(invite.toJson()),
                          size: 260,
                          eyeStyle: const QrEyeStyle(color: Colors.black),
                          dataModuleStyle: const QrDataModuleStyle(
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '手机扫码后，在电脑确认。邀请 5 分钟有效，仅使用一次。请勿把配对信息发给他人。',
                      textAlign: TextAlign.center,
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              await Clipboard.setData(
                                ClipboardData(
                                  text: jsonEncode(invite.toJson()),
                                ),
                              );
                              _setStatus('配对信息已复制；可在手机手动输入');
                            },
                      child: const Text('复制配对信息'),
                    ),
                  ],
                  if (_server != null)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _server!.renewInvite(_host!);
                            }),
                      child: const Text('重新生成配对二维码'),
                    ),
                ] else ...[
                  FilledButton.icon(
                    onPressed: _busy || _identity == null ? null : _scan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: Text(_peer == null ? '扫描电脑二维码' : '扫码更新连接地址'),
                  ),
                  TextButton(
                    onPressed: _busy || _identity == null ? null : _pastePair,
                    child: const Text('手动输入配对信息'),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: _busy || _peer == null
                        ? null
                        : () => _run(_sync),
                    icon: const Icon(Icons.sync),
                    label: const Text('立即同步'),
                  ),
                  if (_busy && _client != null)
                    TextButton(
                      onPressed: () {
                        _cancelled = true;
                        _client?.close();
                        setState(() => _status = '已中止连接；对端可能已经保存，请再次同步核对');
                      },
                      child: const Text('中止同步'),
                    ),
                ],
                if (_peer != null)
                  TextButton(
                    onPressed: _busy ? null : _forget,
                    child: const Text('解除配对'),
                  ),
                const SizedBox(height: 20),
                const Text(
                  '连接失败时：确认两端网络互通，Windows 防火墙允许此应用的专用网络连接。访客 Wi-Fi 或 VPN 可能隔离设备。请求超过 60 秒会报错，可重新同步。',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ScanPage extends StatefulWidget {
  const _ScanPage();
  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  final _controller = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool _done = false;
  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('扫描电脑配对二维码')),
    body: MobileScanner(
      controller: _controller,
      onDetect: (capture) {
        if (_done) return;
        final text = capture.barcodes.firstOrNull?.rawValue;
        if (text == null) return;
        _done = true;
        Navigator.pop(context, text);
      },
      errorBuilder: (context, error) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('无法使用相机。请在系统设置允许相机权限，或返回选择手动输入配对信息。'),
        ),
      ),
    ),
  );
}
