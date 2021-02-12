import 'package:firebase_auth_rest/firebase_auth_rest.dart';
import 'package:firebase_database_rest/src/database/database.dart';
import 'package:firebase_database_rest/src/database/etag_receiver.dart';
import 'package:firebase_database_rest/src/database/store.dart';
import 'package:firebase_database_rest/src/database/transaction.dart';
import 'package:firebase_database_rest/src/rest/api_constants.dart';
import 'package:firebase_database_rest/src/rest/models/db_exception.dart';
import 'package:firebase_database_rest/src/rest/models/filter.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:http/http.dart';
import 'package:test/test.dart';
import 'package:tuple/tuple.dart';

import 'test_config.dart';
import 'test_data.dart';

part 'integration_test.freezed.dart';
part 'integration_test.g.dart';

@freezed
abstract class TestModel with _$TestModel {
  const TestModel._();

  // ignore: sort_unnamed_constructors_first
  const factory TestModel({
    required int id,
    String? data,
    @Default(false) bool extra,
  }) = _TestModel;

  factory TestModel.fromJson(Map<String, dynamic> json) =>
      _$TestModelFromJson(json);

  TestModel patch(Map<String, dynamic> json) => (this as dynamic).copyWith(
        id: json.containsKey('id') ? json['id'] : freezed,
        data: json.containsKey('data') ? json['data'] : freezed,
        extra: json.containsKey('extra') ? json['extra'] : freezed,
      ) as TestModel;
}

class TestStore extends FirebaseStore<TestModel> {
  TestStore(FirebaseStore<dynamic> parent, int caseCtr)
      : super(
          parent: parent,
          path: '_test_path_$caseCtr',
        );

  @override
  TestModel? dataFromJson(dynamic json) =>
      json != null ? TestModel.fromJson(json as Map<String, dynamic>) : null;

  @override
  dynamic dataToJson(TestModel? data) => data?.toJson();

  @override
  TestModel patchData(TestModel data, Map<String, dynamic> updatedFields) =>
      data.patch(updatedFields);
}

void main() {
  late final Client client;
  late final FirebaseAccount account;
  late final FirebaseDatabase database;

  setUpAll(() async {
    client = Client();
    final auth = FirebaseAuth(client, TestConfig.apiKey);
    account = await auth.signUpAnonymous(autoRefresh: false);
    database = FirebaseDatabase(
      account: account,
      database: TestConfig.projectId,
      basePath: 'firebase_database_rest/${account.localId}',
      client: client,
    );
  });

  tearDownAll(() async {
    await account.delete();
    await database.dispose();
    client.close();
  });

  var caseCtr = 0;
  late TestStore store;

  setUp(() {
    store = TestStore(database.rootStore, caseCtr++);
  });

  tearDown(() async {
    await database.rootStore.delete(store.subPaths.last);
  });

  test('setUp and tearDown run without errors', () async {
    await store.keys();
  });

  test('create and then read an entry', () async {
    const localData = TestModel(id: 42);
    final key = await store.create(localData);
    expect(key, isNotNull);

    final remoteData = await store.read(key);
    expect(remoteData, localData);
  });

  test('write and then read entry with custom key', () async {
    const key = 'test_key';
    const localData = TestModel(id: 3, data: 'data', extra: true);
    final writeData = await store.write(key, localData);
    expect(writeData, localData);
    final readData = await store.read(key);
    expect(readData, localData);
  });

  test('write, read, delete, read entry, with key existance check', () async {
    const key = 'test_key';
    const localData = TestModel(id: 77);

    var keys = await store.keys();
    expect(keys, isEmpty);

    final silentData = await store.write(key, localData, silent: true);
    expect(silentData, isNull);

    keys = await store.keys();
    expect(keys, [key]);
    final remoteData = await store.read(key);
    expect(remoteData, localData);

    await store.delete(key);
    keys = await store.keys();
    expect(keys, isEmpty);

    final deletedData = await store.read(key);
    expect(deletedData, isNull);
  });

  test('create, update, read works as excepted', () async {
    const localData = TestModel(id: 99, data: 'oldData');
    final updateLocal1 = localData.copyWith(
      data: 'newData',
      extra: true,
    );
    final updateLocal2 = updateLocal1.copyWith(
      data: 'veryNewData',
    );
    final key = await store.create(localData);
    expect(key, isNotNull);

    final updateRes = await store.update(key, <String, dynamic>{
      'data': 'newData',
      'extra': true,
    });
    expect(updateRes, isNull);

    final updateRemote1 = await store.read(key);
    expect(updateRemote1, updateLocal1);

    final updateRemote2 = await store.update(
      key,
      <String, dynamic>{'data': 'veryNewData'},
      currentData: updateLocal1,
    );
    expect(updateRemote2, updateLocal2);
  });

  test('all and keys report all data', () async {
    expect(TestConfig.allTestLimit, greaterThanOrEqualTo(5));

    for (var i = 0; i < TestConfig.allTestLimit; ++i) {
      await store.write('_$i', TestModel(id: i));
    }

    expect(
      await store.keys(),
      unorderedEquals(<String>[
        for (var i = 0; i < TestConfig.allTestLimit; ++i) '_$i',
      ]),
    );

    expect(
      await store.all(),
      {
        for (var i = 0; i < TestConfig.allTestLimit; ++i)
          '_$i': TestModel(id: i),
      },
    );

    await store.delete('_3');

    expect(
      await store.keys(),
      unorderedEquals(<String>[
        for (var i = 0; i < TestConfig.allTestLimit; ++i)
          if (i != 3) '_$i',
      ]),
    );

    expect(
      await store.all(),
      {
        for (final i in List<int>.generate(TestConfig.allTestLimit, (i) => i))
          if (i != 3) '_$i': TestModel(id: i),
      },
    );
  });

  test('reports and respects eTags', () async {
    const localData1 = TestModel(id: 11);
    const localData2 = TestModel(id: 12);
    const localData3 = TestModel(id: 13);
    final receiver = ETagReceiver();
    String? _getTag() {
      expect(receiver.eTag, isNotNull);
      final tag = receiver.eTag;
      receiver.eTag = null;
      return tag;
    }

    final key = await store.create(localData1, eTagReceiver: receiver);
    final createTag = _getTag();
    expect(createTag, isNot(ApiConstants.nullETag));

    await store.read(key, eTagReceiver: receiver);
    final readTag = _getTag();
    expect(readTag, createTag);

    await store.keys(eTagReceiver: receiver);
    final keysTag1 = _getTag();
    expect(keysTag1, isNot(ApiConstants.nullETag));
    await store.all(eTagReceiver: receiver);
    final allTag1 = _getTag();
    expect(allTag1, keysTag1);

    await store.write(
      key,
      localData2,
      eTag: createTag,
      eTagReceiver: receiver,
    );
    final writeTag = _getTag();
    expect(writeTag, isNot(createTag));
    expect(writeTag, isNot(ApiConstants.nullETag));

    await store.keys(eTagReceiver: receiver);
    final keysTag2 = _getTag();
    expect(keysTag2, isNot(ApiConstants.nullETag));
    expect(keysTag2, isNot(keysTag1));
    await store.all(eTagReceiver: receiver);
    final allTag2 = _getTag();
    expect(allTag2, keysTag2);

    await expectLater(
      () => store.write(
        key,
        localData3,
        eTag: createTag,
        eTagReceiver: receiver,
      ),
      throwsA(const DbException(
        statusCode: ApiConstants.statusCodeETagMismatch,
      )),
    );

    await expectLater(
      () => store.write(
        key,
        localData3,
        eTag: ApiConstants.nullETag,
        eTagReceiver: receiver,
      ),
      throwsA(const DbException(
        statusCode: ApiConstants.statusCodeETagMismatch,
      )),
    );

    await expectLater(
      () => store.delete(key, eTag: createTag),
      throwsA(const DbException(
        statusCode: ApiConstants.statusCodeETagMismatch,
      )),
    );

    await store.delete(key, eTag: writeTag, eTagReceiver: receiver);
    final deleteTag = _getTag();
    expect(deleteTag, ApiConstants.nullETag);

    await store.keys(eTagReceiver: receiver);
    final keysTag3 = _getTag();
    expect(keysTag3, ApiConstants.nullETag);
    await store.all(eTagReceiver: receiver);
    final allTag3 = _getTag();
    expect(allTag3, keysTag3);

    await store.write(
      key,
      localData3,
      eTag: deleteTag,
      eTagReceiver: receiver,
    );
    final writeTag2 = _getTag();
    expect(writeTag2, isNot(deleteTag));
    expect(writeTag2, isNot(writeTag));
    expect(writeTag2, isNot(createTag));
  });

  group('query', () {
    testData<
        Tuple2<FilterBuilder<int> Function(FilterBuilder<int>), List<int>>>(
      'property',
      [
        Tuple2((b) => b.limitToFirst(3), const [0, 1, 2]),
        Tuple2((b) => b.limitToLast(3), const [2, 3, 4]),
        Tuple2((b) => b.startAt(3), const [3, 4]),
        Tuple2((b) => b.endAt(1), const [0, 1]),
        Tuple2((b) => b.equalTo(2), const [2]),
        Tuple2((b) => b.startAt(2).limitToLast(2), const [3, 4]),
        Tuple2((b) => b.startAt(2).limitToFirst(2), const [2, 3]),
        Tuple2((b) => b.endAt(2).limitToLast(2), const [1, 2]),
        Tuple2((b) => b.endAt(2).limitToFirst(2), const [0, 1]),
      ],
      (fixture) async {
        for (var i = 0; i < 5; ++i) {
          await store.write(
            '_$i',
            TestModel(id: 4 - i),
          );
        }

        final filter = fixture.item1(Filter.property<int>('id')).build();

        expect(
          await store.queryKeys(filter),
          unorderedEquals(fixture.item2.map<String>((e) => '_${4 - e}')),
        );

        expect(
          await store.query(filter),
          {
            for (final i in fixture.item2) '_${4 - i}': TestModel(id: i),
          },
        );
      },
      fixtureToString: (fixture) =>
          // ignore: lines_longer_than_80_chars
          '${fixture.item1(Filter.property<int>('id')).build()} -> ${fixture.item2}',
    );

    testData<
        Tuple2<FilterBuilder<String> Function(FilterBuilder<String>),
            List<int>>>(
      'key',
      [
        Tuple2((b) => b.limitToFirst(3), const [0, 1, 2]),
        Tuple2((b) => b.limitToLast(3), const [2, 3, 4]),
        Tuple2((b) => b.startAt('_3'), const [3, 4]),
        Tuple2((b) => b.endAt('_1'), const [0, 1]),
        Tuple2((b) => b.equalTo('_2'), const [2]),
        Tuple2((b) => b.startAt('_2').limitToLast(2), const [3, 4]),
        Tuple2((b) => b.startAt('_2').limitToFirst(2), const [2, 3]),
        Tuple2((b) => b.endAt('_2').limitToLast(2), const [1, 2]),
        Tuple2((b) => b.endAt('_2').limitToFirst(2), const [0, 1]),
      ],
      (fixture) async {
        for (var i = 0; i < 5; ++i) {
          await store.write(
            '_$i',
            TestModel(id: 4 - i),
          );
        }

        final filter = fixture.item1(Filter.key()).build();

        expect(
          await store.queryKeys(filter),
          unorderedEquals(fixture.item2.map<String>((e) => '_$e')),
        );

        expect(
          await store.query(filter),
          {
            for (final i in fixture.item2) '_$i': TestModel(id: 4 - i),
          },
        );
      },
      fixtureToString: (fixture) =>
          // ignore: lines_longer_than_80_chars
          '${fixture.item1(Filter.key()).build()} -> ${fixture.item2}',
    );

    testData<
        Tuple2<FilterBuilder<int> Function(FilterBuilder<int>), List<int>>>(
      'valueXX',
      [
        Tuple2((b) => b.limitToFirst(3), const [0, 1, 2]),
        Tuple2((b) => b.limitToLast(3), const [2, 3, 4]),
        Tuple2((b) => b.startAt(3), const [3, 4]),
        Tuple2((b) => b.endAt(1), const [0, 1]),
        Tuple2((b) => b.equalTo(2), const [2]),
        Tuple2(
          (b) => b.startAt(2).limitToLast(2),
          const [3, 4],
        ),
        Tuple2(
          (b) => b.startAt(2).limitToFirst(2),
          const [2, 3],
        ),
        Tuple2(
          (b) => b.endAt(2).limitToLast(2),
          const [1, 2],
        ),
        Tuple2(
          (b) => b.endAt(2).limitToFirst(2),
          const [0, 1],
        ),
      ],
      (fixture) async {
        final intStore = database.rootStore.subStore<int>(
          path: store.subPaths.last,
          onDataFromJson: (dynamic j) => j as int?,
          onDataToJson: (d) => d,
          onPatchData: (_, __) => throw UnimplementedError(),
        );
        for (var i = 0; i < 5; ++i) {
          await intStore.write('_${14 - i}', i);
        }
        final filter = fixture.item1(Filter.value<int>()).build();

        expect(
          await intStore.queryKeys(filter),
          unorderedEquals(fixture.item2.map<String>((e) => '_${14 - e}')),
        );

        expect(
          await intStore.query(filter),
          {
            for (final i in fixture.item2) '_${14 - i}': i,
          },
        );
      },
      fixtureToString: (fixture) =>
          // ignore: lines_longer_than_80_chars
          '${fixture.item1(Filter.value<int>()).build()} -> ${fixture.item2}',
    );
  });

  group('transaction', () {
    const localData = TestModel(id: 111);

    test('create new entry', () async {
      const key = 'test_key';

      final transaction = await store.transaction(key);
      expect(transaction.key, key);
      expect(transaction.value, isNull);
      expect(transaction.eTag, ApiConstants.nullETag);

      final transData = await transaction.commitUpdate(localData);
      expect(transData, localData);

      final readData = await store.read(key);
      expect(readData, localData);
    });

    test('modify existing entry', () async {
      final updateData = localData.copyWith(data: 'transacted');

      final key = await store.create(localData);

      final transaction = await store.transaction(key);
      expect(transaction.key, key);
      expect(transaction.value, localData);
      expect(transaction.eTag, isNot(ApiConstants.nullETag));

      final transData = await transaction.commitUpdate(updateData);
      expect(transData, updateData);

      final readData = await store.read(key);
      expect(readData, updateData);
    });

    test('modify after data was mutated', () async {
      final updateData1 = localData.copyWith(data: 'mutated');
      final updateData2 = localData.copyWith(data: 'transacted');

      final key = await store.create(localData);

      final transaction = await store.transaction(key);
      expect(transaction.key, key);
      expect(transaction.value, localData);
      expect(transaction.eTag, isNot(ApiConstants.nullETag));

      final receiver = ETagReceiver();
      await store.write(key, updateData1, eTagReceiver: receiver);
      expect(receiver.eTag, isNotNull);
      expect(receiver.eTag, isNot(transaction.eTag));

      expect(
        () => transaction.commitUpdate(updateData2),
        throwsA(isA<TransactionFailedException>()),
      );

      final readData = await store.read(key);
      expect(readData, updateData1);
    });

    test('delete existing entry', () async {
      final key = await store.create(localData);

      final transaction = await store.transaction(key);
      expect(transaction.key, key);
      expect(transaction.value, localData);
      expect(transaction.eTag, isNot(ApiConstants.nullETag));

      await transaction.commitDelete();

      final readData = await store.read(key);
      expect(readData, isNull);
    });

    test('delete mutated entry', () async {
      final updateData = localData.copyWith(data: 'mutated');

      final key = await store.create(localData);

      final transaction = await store.transaction(key);
      expect(transaction.key, key);
      expect(transaction.value, localData);
      expect(transaction.eTag, isNot(ApiConstants.nullETag));

      final receiver = ETagReceiver();
      await store.write(key, updateData, eTagReceiver: receiver);
      expect(receiver.eTag, isNotNull);
      expect(receiver.eTag, isNot(transaction.eTag));

      expect(
        () => transaction.commitDelete(),
        throwsA(isA<TransactionFailedException>()),
      );

      final readData = await store.read(key);
      expect(readData, updateData);
    });
  });
}

// TODO write fuzzy test?