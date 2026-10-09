import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:little_check/storage.dart';
import 'package:little_check/sync_auth.dart';
import 'package:little_check/sync_merge.dart';
import 'package:little_check/sync_models.dart';
import 'package:little_check/sync_planner.dart';

SyncEntityState live(String id, String hash) =>
    SyncEntityState.live(id: id, stateHash: hash);

void main() {
  group('sync entity resolution', () {
    test('single-sided change replaces unchanged baseline', () {
      final result = resolveSyncEntity(
        kind: 'note',
        entityId: 'note',
        leftDeviceId: 'desktop',
        rightDeviceId: 'phone',
        left: live('note', 'base'),
        right: live('note', 'phone-new'),
        baselineHash: 'base',
      );
      expect(result.isInvalid, isFalse);
      expect(result.isConflict, isFalse);
      expect(result.originalSource, SyncSource.right);
      expect(result.originalDeleted, isFalse);
    });

    test('same concurrent result converges without conflict', () {
      final result = resolveSyncEntity(
        kind: 'note',
        entityId: 'note',
        leftDeviceId: 'desktop',
        rightDeviceId: 'phone',
        left: live('note', 'same-new'),
        right: live('note', 'same-new'),
        baselineHash: 'base',
      );
      expect(result.isConflict, isFalse);
      expect(result.originalSource, SyncSource.left);
    });

    test('two divergent edits use deterministic conflict identity', () {
      final first = resolveSyncEntity(
        kind: 'note',
        entityId: 'note',
        leftDeviceId: 'desktop',
        rightDeviceId: 'phone',
        left: live('note', 'desktop-new'),
        right: live('note', 'phone-new'),
        baselineHash: 'base',
      );
      final swapped = resolveSyncEntity(
        kind: 'note',
        entityId: 'note',
        leftDeviceId: 'phone',
        rightDeviceId: 'desktop',
        left: live('note', 'phone-new'),
        right: live('note', 'desktop-new'),
        baselineHash: 'base',
      );

      expect(first.isConflict, isTrue);
      expect(first.originalSource, SyncSource.left);
      expect(first.conflictSource, SyncSource.right);
      expect(first.conflictId, swapped.conflictId);
      expect(first.conflictId, startsWith('conflict_'));
      expect(first.conflictId, hasLength(49));
      expect(swapped.originalSource, SyncSource.right);
      expect(swapped.conflictSource, SyncSource.left);
    });

    test('delete versus edit keeps tombstone and copies edited side', () {
      final result = resolveSyncEntity(
        kind: 'note',
        entityId: 'note',
        leftDeviceId: 'desktop',
        rightDeviceId: 'phone',
        left: SyncEntityState.tombstone(kind: 'note', id: 'note'),
        right: live('note', 'phone-new'),
        baselineHash: 'base',
      );
      expect(result.isConflict, isTrue);
      expect(result.originalDeleted, isTrue);
      expect(result.originalSource, SyncSource.left);
      expect(result.conflictSource, SyncSource.right);
      expect(result.conflictId, isNotNull);
    });

    test('baseline entity cannot disappear without tombstone', () {
      final result = resolveSyncEntity(
        kind: 'note',
        entityId: 'note',
        leftDeviceId: 'desktop',
        rightDeviceId: 'phone',
        left: null,
        right: live('note', 'base'),
        baselineHash: 'base',
      );
      expect(result.isInvalid, isTrue);
    });
  });

  group('LocalStore sync state', () {
    late Directory directory;
    late LocalStore store;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('little-check-sync-');
      store = LocalStore(directory);
      await store.init();
    });

    tearDown(() async {
      await directory.delete(recursive: true);
    });

    test(
      'manifest hashes note content and metadata but not trash timestamp',
      () async {
        await store.putFolder('work', '工作');
        await store.saveNote('note', '# A');
        await store.moveNote('note', 'work');
        final active = (await store.syncManifest()).notes['note']!;

        await store.trashNote('note');
        final trashed = (await store.syncManifest()).notes['note']!;
        expect(trashed.contentHash, active.contentHash);
        expect(trashed.stateHash, isNot(active.stateHash));

        final stateBefore = trashed.stateHash;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        await store.trashNote('note');
        final trashedAgain = (await store.syncManifest()).notes['note']!;
        expect(trashedAgain.stateHash, stateBefore);
      },
    );

    test('permanent note deletion writes persistent tombstone first', () async {
      await store.saveNote('note', '# A');
      await store.trashNote('note');
      await store.deleteNotePermanently('note');

      expect(await store.noteFile('note').exists(), isFalse);
      expect(store.noteTombstones, contains('note'));
      expect((await store.syncManifest()).noteTombstones, contains('note'));

      final reopened = LocalStore(directory);
      await reopened.init();
      expect(reopened.noteTombstones, contains('note'));
      expect((await reopened.syncManifest()).notes, isNot(contains('note')));
    });

    test('folder deletion writes persistent tombstone', () async {
      await store.putFolder('work', '工作');
      await store.deleteFolder('work', trashContents: false);

      expect(store.folderTombstones, contains('work'));
      final reopened = LocalStore(directory);
      await reopened.init();
      expect(reopened.folderTombstones, contains('work'));
      expect(reopened.folders, isNot(contains('work')));
    });

    test(
      'sync mutation refuses to overwrite an actively edited note',
      () async {
        await store.saveNote('note', '# Local');
        store.beginEditing('note');
        addTearDown(() => store.endEditing('note'));

        await expectLater(
          store.applySyncNoteMutation(
            const SyncNoteMutation.live(
              id: 'note',
              operationId: 'remote:1',
              content: '# Remote',
              trashed: false,
            ),
          ),
          throwsFormatException,
        );
        expect(await store.noteFile('note').readAsString(), '# Local');
      },
    );

    test('duplicate permanent delete operation is idempotent', () async {
      await store.saveNote('note', '# Local');
      const mutation = SyncNoteMutation.delete(
        id: 'note',
        operationId: 'remote:delete:1',
      );
      await store.applySyncNoteMutation(mutation);
      await store.applySyncNoteMutation(mutation);

      expect(store.noteTombstones, {'note'});
      expect(await store.noteFile('note').exists(), isFalse);
    });

    test('sync baseline persists by peer', () async {
      final hash = syncHash({'value': 1});
      await store.saveSyncBaseline(
        'peer-1',
        notes: {'note': hash},
        folders: const {},
      );

      final reopened = LocalStore(directory);
      await reopened.init();
      expect(reopened.syncBaseline('peer-1', kind: 'notes'), {'note': hash});
    });

    test(
      'saving a new peer baseline drops stale single-peer baseline',
      () async {
        final first = syncHash({'value': 1});
        final second = syncHash({'value': 2});
        await store.saveSyncBaseline(
          'peer-1',
          notes: {'note': first},
          folders: const {},
        );
        await store.saveSyncBaseline(
          'peer-2',
          notes: {'note': second},
          folders: const {},
        );

        expect(store.syncBaseline('peer-1', kind: 'notes'), isEmpty);
        expect(store.syncBaseline('peer-2', kind: 'notes'), {'note': second});
      },
    );

    test('forgetting a peer removes baseline and pending transfer', () async {
      final hash = syncHash({'value': 1});
      await store.saveSyncBaseline(
        'peer-1',
        notes: {'note': hash},
        folders: const {},
      );
      await store.saveNote('note', '# A');
      final snapshot = await store.syncSnapshot();
      await store.saveSyncTransfer(
        'peer-1',
        snapshot.manifest.fingerprint,
        snapshot,
      );

      await store.forgetSyncPeer('peer-1');

      expect(store.syncBaseline('peer-1', kind: 'notes'), isEmpty);
      expect(await store.readSyncTransfer(), isNull);
    });

    test(
      'sync snapshot rejects oversized file before reading its contents',
      () async {
        final file = store.noteFile('huge');
        await file.writeAsBytes(List<int>.filled(2 * 1024 * 1024 + 1, 0x61));

        await expectLater(store.syncSnapshot(), throwsFormatException);
        expect(await file.length(), 2 * 1024 * 1024 + 1);
      },
    );
  });

  test('merge never overwrites a real note that occupies a conflict id', () {
    const leftDevice = 'desktop_1234';
    const rightDevice = 'phone_1234';
    final baseHash = syncHash({'base': true});
    final leftContent = '# Desktop edit';
    final rightContent = '# Phone edit';
    final leftNote = SyncNoteVersion(
      id: 'note',
      contentHash: syncBodyHashForTest(leftContent),
      trashed: false,
    );
    final rightNote = SyncNoteVersion(
      id: 'note',
      contentHash: syncBodyHashForTest(rightContent),
      trashed: false,
    );
    final collisionId = deterministicConflictId(
      kind: 'note',
      originalId: 'note',
      baselineHash: baseHash,
      leftDeviceId: leftDevice,
      leftStateHash: leftNote.stateHash,
      rightDeviceId: rightDevice,
      rightStateHash: rightNote.stateHash,
    );
    const existingContent = '# Existing real note';
    final existing = SyncNoteVersion(
      id: collisionId,
      contentHash: syncBodyHashForTest(existingContent),
      trashed: false,
    );
    final left = SyncSnapshot(
      SyncManifest(
        notes: {'note': leftNote, collisionId: existing},
        folders: const {},
        noteTombstones: const {},
        folderTombstones: const {},
      ),
      {'note': leftContent, collisionId: existingContent},
    );
    final right = SyncSnapshot(
      SyncManifest(
        notes: {'note': rightNote, collisionId: existing},
        folders: const {},
        noteTombstones: const {},
        folderTombstones: const {},
      ),
      {'note': rightContent, collisionId: existingContent},
    );

    final merged = mergeSyncSnapshots(
      leftDeviceId: leftDevice,
      rightDeviceId: rightDevice,
      left: left,
      right: right,
      noteBaseline: {'note': baseHash},
      folderBaseline: const {},
    ).snapshot;

    expect(merged.contents[collisionId], existingContent);
    expect(merged.contents.values, containsAll([leftContent, rightContent]));
    expect(merged.contents, hasLength(3));
  });

  group('sync plan', () {
    SyncManifest manifest({
      Map<String, SyncNoteVersion> notes = const {},
      Map<String, SyncFolderVersion> folders = const {},
      Set<String> noteTombstones = const {},
      Set<String> folderTombstones = const {},
    }) => SyncManifest(
      notes: notes,
      folders: folders,
      noteTombstones: noteTombstones,
      folderTombstones: folderTombstones,
    );

    test('manifest plan resolves one-sided additions and deletions', () {
      const note = SyncNoteVersion(
        id: 'note',
        contentHash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        trashed: false,
      );
      final plan = buildSyncPlan(
        leftDeviceId: 'desktop',
        rightDeviceId: 'phone',
        left: manifest(notes: const {'note': note}),
        right: manifest(),
      );
      expect(plan.hasInvalidEntries, isFalse);
      expect(plan.notes['note']!.originalSource, SyncSource.left);

      final deleted = buildSyncPlan(
        leftDeviceId: 'desktop',
        rightDeviceId: 'phone',
        left: manifest(noteTombstones: const {'note'}),
        right: manifest(notes: const {'note': note}),
        noteBaseline: {'note': note.stateHash},
      );
      expect(deleted.notes['note']!.originalDeleted, isTrue);
      expect(deleted.notes['note']!.isConflict, isFalse);
    });

    test('plan is symmetric and reports deterministic conflicts', () {
      const desktop = SyncNoteVersion(
        id: 'note',
        contentHash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        trashed: false,
      );
      const phone = SyncNoteVersion(
        id: 'note',
        contentHash:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        trashed: false,
      );
      const baseline =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      final first = buildSyncPlan(
        leftDeviceId: 'desktop',
        rightDeviceId: 'phone',
        left: manifest(notes: const {'note': desktop}),
        right: manifest(notes: const {'note': phone}),
        noteBaseline: const {'note': baseline},
      );
      final swapped = buildSyncPlan(
        leftDeviceId: 'phone',
        rightDeviceId: 'desktop',
        left: manifest(notes: const {'note': phone}),
        right: manifest(notes: const {'note': desktop}),
        noteBaseline: const {'note': baseline},
      );
      expect(first.conflictCount, 1);
      expect(
        first.notes['note']!.conflictId,
        swapped.notes['note']!.conflictId,
      );
    });

    test('missing baseline entity without tombstone is invalid', () {
      const note = SyncNoteVersion(
        id: 'note',
        contentHash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        trashed: false,
      );
      final plan = buildSyncPlan(
        leftDeviceId: 'desktop',
        rightDeviceId: 'phone',
        left: manifest(),
        right: manifest(notes: const {'note': note}),
        noteBaseline: {'note': note.stateHash},
      );
      expect(plan.hasInvalidEntries, isTrue);
      expect(plan.notes['note']!.invalidReason, isNotNull);
    });

    test('live entity and tombstone on one side is invalid', () {
      const note = SyncNoteVersion(
        id: 'note',
        contentHash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        trashed: false,
      );
      final plan = buildSyncPlan(
        leftDeviceId: 'desktop',
        rightDeviceId: 'phone',
        left: manifest(
          notes: const {'note': note},
          noteTombstones: const {'note'},
        ),
        right: manifest(),
      );
      expect(plan.hasInvalidEntries, isTrue);
    });
  });

  group('sync request auth', () {
    test(
      'nonce cache preserves replay protection when capacity is reached',
      () {
        final now = DateTime.utc(2026, 10, 4, 12);
        final cache = SyncNonceCache(maxEntries: 1);
        cache.consume('phone_1234', 'first_nonce', now);
        expect(
          () => cache.consume('phone_1234', 'new_nonce', now),
          throwsFormatException,
        );
        expect(
          () => cache.consume('phone_1234', 'first_nonce', now),
          throwsFormatException,
        );
        expect(
          () => cache.consume(
            'phone_1234',
            'new_nonce',
            now.add(const Duration(minutes: 6)),
          ),
          returnsNormally,
        );
      },
    );
    test('pairing invite round-trips and expires', () {
      final now = DateTime.utc(2026, 10, 4, 12);
      final invite = createPairingInvite(
        deviceId: 'desktop_1234',
        host: '192.168.1.20',
        port: 43821,
        now: now,
        certificateFingerprint:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      final decoded = SyncPairingInvite.fromJson(invite.toJson());
      expect(decoded.deviceId, 'desktop_1234');
      expect(decoded.port, 43821);
      expect(
        () => decoded.validate(now: now.add(const Duration(minutes: 6))),
        throwsFormatException,
      );
    });

    test('signed request verifies body and signature', () {
      final now = DateTime.utc(2026, 10, 4, 12);
      const secret =
          'pair_secret_pair_secret_pair_secret_pair_secret_pair_secret';
      final body = utf8.encode('{"hello":"world"}');
      final auth = signSyncRequest(
        deviceId: 'phone_1234',
        pairSecret: secret,
        method: 'POST',
        path: '/sync/manifest',
        body: body,
        now: now,
        nonce: 'abcdefghijklmnop',
      );
      expect(
        () => verifySyncRequest(
          auth: auth,
          pairSecret: secret,
          method: 'POST',
          path: '/sync/manifest',
          body: body,
          now: now.add(const Duration(seconds: 30)),
        ),
        returnsNormally,
      );
      expect(
        () => verifySyncRequest(
          auth: auth,
          pairSecret: secret,
          method: 'POST',
          path: '/sync/manifest',
          body: utf8.encode('{"hello":"changed"}'),
          now: now,
        ),
        throwsFormatException,
      );
    });

    test('request auth rejects stale and replayed requests', () {
      final now = DateTime.utc(2026, 10, 4, 12);
      const secret =
          'pair_secret_pair_secret_pair_secret_pair_secret_pair_secret';
      final auth = signSyncRequest(
        deviceId: 'phone_1234',
        pairSecret: secret,
        method: 'POST',
        path: '/sync',
        body: const [],
        now: now,
        nonce: 'abcdefghijklmnop',
      );
      expect(
        () => verifySyncRequest(
          auth: auth,
          pairSecret: secret,
          method: 'POST',
          path: '/sync',
          body: const [],
          now: now.add(const Duration(minutes: 3)),
        ),
        throwsFormatException,
      );

      final cache = SyncNonceCache();
      cache.consume(auth.deviceId, auth.nonce, now);
      expect(
        () => cache.consume(auth.deviceId, auth.nonce, now),
        throwsFormatException,
      );
    });
  });
}

String syncBodyHashForTest(String text) =>
    sha256.convert(utf8.encode(text)).toString();
