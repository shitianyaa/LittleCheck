import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:little_check/storage.dart';
import 'package:little_check/sync_identity.dart';
import 'package:little_check/sync_merge.dart';
import 'package:little_check/sync_models.dart';
import 'package:little_check/sync_transport.dart';

void main() {
  late SyncIdentity identity;
  late Directory directory;
  late LocalStore desktop;
  late LocalStore phone;
  late LanSyncServer server;
  late LanSyncClient client;
  late SyncPeer paired;

  setUpAll(() {
    identity = generateSyncIdentity(0);
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lan-sync-test-');
    desktop = LocalStore(Directory('${directory.path}/desktop'));
    phone = LocalStore(Directory('${directory.path}/phone'));
    await desktop.init();
    await phone.init();
    server = LanSyncServer(
      store: desktop,
      identity: identity,
      approvePair: (_) async => true,
      savePeer: (_) async {},
    );
    await server.start('127.0.0.1', listenPort: 0);
    paired = await LanSyncClient.pair('phone_1234', server.invite!);
    client = LanSyncClient('phone_1234', paired);
  });
  tearDown(() async {
    client.close();
    await server.close();
    await directory.delete(recursive: true);
  });
  Future<void> sync() async {
    await client.sync(phone, confirm: (_) async => true);
  }

  test(
    'network choices prefer physical interfaces without hiding hotspots',
    () {
      final addresses = sortedSyncAddresses([
        (
          address: '192.168.127.1',
          interfaceName: 'VMware Network Adapter VMnet1',
        ),
        (
          address: '192.168.137.1',
          interfaceName: 'Microsoft Wi-Fi Direct Virtual Adapter',
        ),
        (address: '169.254.1.2', interfaceName: 'Ethernet'),
        (address: '10.61.7.242', interfaceName: 'WLAN'),
        (address: '127.0.0.1', interfaceName: 'Loopback'),
        (address: '8.8.8.8', interfaceName: 'Public'),
      ]);
      expect(addresses.first.address, '10.61.7.242');
      expect(addresses.map((a) => a.address), contains('192.168.137.1'));
      expect(addresses.last.address, '169.254.1.2');
      expect(addresses, hasLength(4));
    },
  );

  test(
    'unreachable listener reports its address before pairing approval',
    () async {
      server.renewInvite('127.0.0.1');
      final invite = server.invite!;
      await server.close();
      final statuses = <String>[];
      await expectLater(
        LanSyncClient.pair('phone_1234', invite, onStatus: statuses.add),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('127.0.0.1:${invite.port}'),
          ),
        ),
      );
      expect(statuses, ['正在连接电脑 127.0.0.1:${invite.port}']);
    },
  );

  test(
    'real TLS pairing, bidirectional notes, folders and task edits converge',
    () async {
      await desktop.putFolder('desktop_folder', '工作');
      await phone.putFolder('phone_folder', '工作');
      await desktop.saveNote('desktop_note', '# Desktop\n- [ ] task');
      await desktop.moveNote('desktop_note', 'desktop_folder');
      await phone.saveNote('phone_note', '# Phone');
      await phone.moveNote('phone_note', 'phone_folder');
      await sync();
      expect(
        (await desktop.syncManifest()).fingerprint,
        (await phone.syncManifest()).fingerprint,
      );
      expect(desktop.folders.values.toSet(), hasLength(2));
      await phone.saveNote('desktop_note', '# Desktop\n- [x] task');
      await sync();
      expect(
        await desktop.noteFile('desktop_note').readAsString(),
        contains('- [x] task'),
      );
      final before = (await phone.syncManifest()).fingerprint;
      var changes = -1;
      await client.sync(
        phone,
        confirm: (preview) async {
          changes = preview.changes.length;
          return true;
        },
      );
      expect(changes, 0);
      expect((await phone.syncManifest()).fingerprint, before);
    },
  );

  test(
    'concurrent edits preserve both exact Markdown versions and stable copies',
    () async {
      await phone.saveNote('note', '# Original');
      await sync();
      await phone.saveNote('note', '# Phone edit');
      await desktop.saveNote('note', '# Desktop edit');
      final result = await client.sync(phone, confirm: (_) async => true);
      expect(result.conflicts, 1);
      final snapshot = await phone.syncSnapshot();
      expect(snapshot.contents.values.toSet(), {
        '# Phone edit',
        '# Desktop edit',
      });
      expect(
        snapshot.contents.keys.where((id) => id.startsWith('conflict_')),
        hasLength(1),
      );
      await sync();
      expect((await phone.syncSnapshot()).contents, snapshot.contents);
    },
  );

  test(
    'trash restore and delete-versus-edit preserve edited content',
    () async {
      await phone.saveNote('note', '# Original');
      await sync();
      await desktop.trashNote('note');
      await sync();
      expect(await phone.loadNotes(), isEmpty);
      await phone.trashNote('note', restore: true);
      await sync();
      expect(await desktop.loadNotes(), hasLength(1));
      await desktop.trashNote('note');
      await desktop.deleteNotePermanently('note');
      await phone.saveNote('note', '# Offline edit');
      await sync();
      expect(phone.noteTombstones, contains('note'));
      expect((await phone.loadNotes()).single.content, '# Offline edit');
      await sync();
      final reopened = LocalStore(phone.directory);
      await reopened.init();
      expect(reopened.noteTombstones, contains('note'));
      expect(await reopened.loadNotes(), hasLength(1));
    },
  );

  test(
    'preview cancellation and changes during preview do not overwrite',
    () async {
      await desktop.saveNote('note', '# Remote');
      await expectLater(
        client.sync(phone, confirm: (_) async => false),
        throwsFormatException,
      );
      expect(await phone.loadNotes(), isEmpty);
      await expectLater(
        client.sync(
          phone,
          confirm: (_) async {
            await phone.saveNote('new_note', '# Local during sync');
            return true;
          },
        ),
        throwsFormatException,
      );
      expect(await desktop.loadNotes(), hasLength(1));
      expect((await phone.loadNotes()).single.content, '# Local during sync');
    },
  );

  test('server changed after snapshot rejects commit', () async {
    await phone.saveNote('note', '# Phone');
    await expectLater(
      client.sync(
        phone,
        confirm: (_) async {
          await desktop.saveNote('new_note', '# Desktop during sync');
          return true;
        },
      ),
      throwsFormatException,
    );
    expect((await desktop.loadNotes()).single.content, '# Desktop during sync');
  });

  test('interruption after server commit can retry without duplicate note conflicts', () async {
    await phone.saveNote('note', '# Original');
    await sync();
    await phone.saveNote('note', '# Phone edit');
    await desktop.saveNote('note', '# Desktop edit');
    final local = await phone.syncSnapshot();
    final remote = await desktop.syncSnapshot();
    final target = mergeSyncSnapshots(
      leftDeviceId: 'phone_1234',
      rightDeviceId: identity.deviceId,
      left: local,
      right: remote,
      noteBaseline: phone.syncBaseline(identity.deviceId, kind: 'notes'),
      folderBaseline: phone.syncBaseline(identity.deviceId, kind: 'folders'),
    ).snapshot;
    final begin = await client.request('/begin', {});
    await client.request('/commit', {
      'session': begin['session'],
      'manifest': target.manifest.toJson(),
      'contents': target.contents,
    });
    // Mobile process disappears before saving or acknowledging. Reopen client and retry.
    client.close();
    client = LanSyncClient('phone_1234', paired);
    await sync();
    expect((await phone.syncSnapshot()).contents.values.toSet(), {
      '# Phone edit',
      '# Desktop edit',
    });
    expect(await phone.loadNotes(), hasLength(2));
    await sync();
    expect(await phone.loadNotes(), hasLength(2));
  });

  test('interrupted initial folder merge resumes the approved target without extra copies', () async {
    await phone.putFolder('phone_folder', '工作');
    await desktop.putFolder('desktop_folder', '工作');
    await phone.saveNote('phone_note', '# Phone');
    await phone.moveNote('phone_note', 'phone_folder');
    await desktop.saveNote('desktop_note', '# Desktop');
    await desktop.moveNote('desktop_note', 'desktop_folder');
    final local = await phone.syncSnapshot();
    final target = mergeSyncSnapshots(
      leftDeviceId: 'phone_1234',
      rightDeviceId: identity.deviceId,
      left: local,
      right: await desktop.syncSnapshot(),
      noteBaseline: {},
      folderBaseline: {},
    ).snapshot;
    await phone.saveSyncTransfer(
      identity.deviceId,
      local.manifest.fingerprint,
      target,
    );
    final begin = await client.request('/begin', {});
    await client.request('/commit', {
      'session': begin['session'],
      'manifest': target.manifest.toJson(),
      'contents': target.contents,
    });
    await sync();
    expect(
      (await phone.syncSnapshot()).manifest.fingerprint,
      target.manifest.fingerprint,
    );
    expect(phone.folders, hasLength(2));
    expect(await phone.loadNotes(), hasLength(2));
    expect(await phone.readSyncTransfer(), isNull);
    await sync();
    expect(phone.folders, hasLength(2));
  });

  test('wrong certificate, wrong secret and reused pairing invitation are rejected', () async {
    final wrongCert = LanSyncClient(
      'phone_1234',
      SyncPeer(
        deviceId: paired.deviceId,
        host: paired.host,
        port: paired.port,
        fingerprint: '0' * 64,
        secret: paired.secret,
      ),
    );
    try {
      await expectLater(
        wrongCert.request('/begin', {}),
        throwsA(isA<HandshakeException>()),
      );
    } finally {
      wrongCert.close();
    }
    final wrongSecret = LanSyncClient(
      'phone_1234',
      SyncPeer(
        deviceId: paired.deviceId,
        host: paired.host,
        port: paired.port,
        fingerprint: paired.fingerprint,
        secret: 'wrong-secret' * 4,
      ),
    );
    try {
      await expectLater(
        wrongSecret.request('/begin', {}),
        throwsFormatException,
      );
    } finally {
      wrongSecret.close();
    }
    expect(server.invite, isNull);
    server.renewInvite('127.0.0.1');
    final invite = server.invite!;
    await LanSyncClient.pair('phone_1234', invite);
    await expectLater(
      LanSyncClient.pair('phone_1234', invite),
      throwsFormatException,
    );
  });

  test(
    'wrong invite ids do not exhaust the active pairing invitation',
    () async {
      server.renewInvite('127.0.0.1');
      final invite = server.invite!;
      final attacker = LanSyncClient(
        'attacker_1234',
        SyncPeer(
          deviceId: invite.deviceId,
          host: invite.host,
          port: invite.port,
          fingerprint: invite.certificateFingerprint!.toLowerCase(),
          secret: invite.oneTimeSecret,
        ),
      );
      try {
        for (var i = 0; i < 6; i++) {
          await expectLater(
            attacker.request('/pair', {
              'deviceId': 'attacker_1234',
              'inviteId': 'wrong_invite_id_$i',
              'secret': 'x' * 43,
            }, authenticate: false),
            throwsFormatException,
          );
        }
        expect(server.invite?.inviteId, invite.inviteId);
      } finally {
        attacker.close();
      }
    },
  );

  test(
    'permanent-delete preview shows the note title instead of only its id',
    () async {
      await phone.saveNote('note_internal_id', '# Visible title\nbody');
      await sync();
      await desktop.trashNote('note_internal_id');
      await desktop.deleteNotePermanently('note_internal_id');
      late List<String> changes;

      await client.sync(
        phone,
        confirm: (preview) async {
          changes = preview.changes;
          return true;
        },
      );

      expect(changes, contains('手机 · 永久删除 · Visible title'));
    },
  );

  test(
    'open editor prevents sync and service shutdown rejects network request',
    () async {
      phone.beginEditing('note');
      await expectLater(sync(), throwsFormatException);
      phone.endEditing('note');
      await server.close();
      await expectLater(client.request('/begin', {}), throwsA(anything));
    },
  );

  test(
    'failed journal is recovered before later save, which survives restart',
    () async {
      await phone.saveNote('note', '# Original');
      final obstruction = Directory('${phone.directory.path}/sync-state.json');
      await obstruction.create();
      await expectLater(
        phone.applySyncNoteMutation(
          const SyncNoteMutation.live(
            id: 'note',
            operationId: 'remote:1',
            content: '# Remote',
            trashed: false,
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );
      await obstruction.delete();
      await phone.saveNote('note', '# Later local edit');
      final reopened = LocalStore(phone.directory);
      await reopened.init();
      expect(
        await reopened.noteFile('note').readAsString(),
        '# Later local edit',
      );
    },
  );

  test(
    'recreated AI folder uses new ID and retains the old tombstone',
    () async {
      await phone.saveAiNote('translate', 'First', 'A');
      await phone.deleteFolder('ai_translate', trashContents: false);
      await phone.saveAiNote('translate', 'Second', 'B');
      final manifest = await phone.syncManifest();
      expect(manifest.folderTombstones, contains('ai_translate'));
      expect(manifest.folders.containsKey('ai_translate'), isFalse);
      expect(phone.folders.values, contains('AI 翻译'));
      await sync();
    },
  );

  test('manifest validates paths, hashes, tombstones and missing folder references', () {
    final data = SyncManifest(
      notes: const {},
      folders: const {},
      noteTombstones: {},
      folderTombstones: {},
    ).toJson();
    expect(
      () => SyncManifest.fromJson({
        ...data,
        'noteTombstones': ['../escape'],
      }),
      throwsFormatException,
    );
    expect(
      () => SyncManifest.fromJson({...data, 'protocolVersion': 99}),
      throwsFormatException,
    );
    const note = SyncNoteVersion(
      id: 'note',
      contentHash:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      trashed: false,
      folderId: 'missing',
    );
    expect(
      () => SyncManifest.fromJson({
        ...data,
        'notes': {'note': note.toJson()},
      }),
      throwsFormatException,
    );
    expect(
      () => SyncSnapshot(
        SyncManifest(
          notes: {'note': note.copyWith(clearFolder: true)},
          folders: const {},
          noteTombstones: {},
          folderTombstones: {},
        ),
        {'note': 'wrong'},
      ).validate(),
      throwsFormatException,
    );
  });

  test('oversize notes fail explicitly rather than truncate', () async {
    await phone.saveNote('note', 'x' * (2 * 1024 * 1024 + 1));
    await expectLater(phone.syncSnapshot(), throwsFormatException);
    expect(await phone.noteFile('note').length(), 2 * 1024 * 1024 + 1);
  });

  test(
    'recovery journal rolls forward a multi-note batch on restart',
    () async {
      await phone.saveNote('old_note', '# Old');
      final a = SyncNoteVersion(
        id: 'a',
        contentHash: syncBodyHashForTest('# A'),
        trashed: false,
      );
      final b = SyncNoteVersion(
        id: 'b',
        contentHash: syncBodyHashForTest('# B'),
        trashed: false,
      );
      final target = SyncSnapshot(
        SyncManifest(
          notes: {'a': a, 'b': b},
          folders: {},
          noteTombstones: {'old_note'},
          folderTombstones: {},
        ),
        {'a': '# A', 'b': '# B'},
      );
      final obstruction = Directory('${phone.directory.path}/sync-state.json');
      await obstruction.create();
      await expectLater(
        phone.applySyncSnapshot(
          target,
          expectedFingerprint: (await phone.syncManifest()).fingerprint,
        ),
        throwsA(isA<FileSystemException>()),
      );
      await obstruction.delete();
      final reopened = LocalStore(phone.directory);
      await reopened.init();
      expect(
        (await reopened.syncSnapshot()).manifest.fingerprint,
        target.manifest.fingerprint,
      );
      expect(await reopened.noteFile('old_note').exists(), isFalse);
    },
  );
}

String syncBodyHashForTest(String text) {
  return sha256.convert(utf8.encode(text)).toString();
}
