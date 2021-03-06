import 'package:firebase_database_rest/src/common/api_constants.dart';
import 'package:firebase_database_rest/src/common/db_exception.dart';
import 'package:firebase_database_rest/src/database/etag_receiver.dart';
import 'package:firebase_database_rest/src/database/store.dart';
import 'package:firebase_database_rest/src/database/store_helpers/store_transaction.dart';
import 'package:firebase_database_rest/src/database/transaction.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockFirebaseStore extends Mock implements FirebaseStore<int> {}

// ignore: avoid_implementing_value_types
class FakeETagReceiver extends Fake implements ETagReceiver {}

void main() {
  const key = 'key';
  const value = 42;
  const eTag = 'e_tag';
  final mockFirebaseStore = MockFirebaseStore();
  final fakeETagReceiver = FakeETagReceiver();

  late StoreTransaction<int> sut;

  setUp(() {
    reset(mockFirebaseStore);

    sut = StoreTransaction(
      store: mockFirebaseStore,
      key: key,
      value: value,
      eTag: eTag,
      eTagReceiver: fakeETagReceiver,
    );
  });

  test('properties are set correctly', () {
    expect(sut.key, key);
    expect(sut.value, value);
    expect(sut.eTag, eTag);
  });

  group('commitUpdate', () {
    setUp(() {
      when(() => mockFirebaseStore.write(
            any(),
            any(),
            eTag: any(named: 'eTag'),
            eTagReceiver: any(named: 'eTagReceiver'),
          )).thenAnswer((i) async => 0);
    });

    test('calls store.write', () async {
      await sut.commitUpdate(13);

      verify(() => mockFirebaseStore.write(
            key,
            13,
            eTag: eTag,
            eTagReceiver: fakeETagReceiver,
          ));
    });

    test('forwards store.write result', () async {
      when(() => mockFirebaseStore.write(
            any(),
            any(),
            eTag: any(named: 'eTag'),
            eTagReceiver: any(named: 'eTagReceiver'),
          )).thenAnswer((i) async => 31);

      final res = await sut.commitUpdate(13);
      expect(res, 31);
    });

    test('transforms etag mismatch exceptions', () async {
      when(() => mockFirebaseStore.write(
            any(),
            any(),
            eTag: any(named: 'eTag'),
            eTagReceiver: any(named: 'eTagReceiver'),
          )).thenThrow(
        const DbException(statusCode: ApiConstants.statusCodeETagMismatch),
      );

      expect(
        () => sut.commitUpdate(13),
        throwsA(isA<TransactionFailedException>()),
      );
    });

    test('forwards other exceptions', () async {
      when(() => mockFirebaseStore.write(
            any(),
            any(),
            eTag: any(named: 'eTag'),
            eTagReceiver: any(named: 'eTagReceiver'),
          )).thenThrow(Exception('test'));

      expect(
        () => sut.commitUpdate(13),
        throwsA(isA<Exception>().having(
          (e) => (e as dynamic).message,
          'message',
          'test',
        )),
      );
    });

    test('throws when trying to commit twice', () async {
      await sut.commitUpdate(1);
      expect(() => sut.commitUpdate(2), throwsA(isA<AlreadyComittedError>()));
    });
  });

  group('commitDelete', () {
    setUp(() {
      when(() => mockFirebaseStore.delete(
            any(),
            eTag: any(named: 'eTag'),
            eTagReceiver: any(named: 'eTagReceiver'),
          )).thenAnswer((i) => Future.value());
    });

    test('calls store.delete', () async {
      await sut.commitDelete();

      verify(() => mockFirebaseStore.delete(
            key,
            eTag: eTag,
            eTagReceiver: fakeETagReceiver,
          ));
    });

    test('transforms etag mismatch exceptions', () async {
      when(() => mockFirebaseStore.delete(
            any(),
            eTag: any(named: 'eTag'),
            eTagReceiver: any(named: 'eTagReceiver'),
          )).thenThrow(
        const DbException(statusCode: ApiConstants.statusCodeETagMismatch),
      );

      expect(
        () => sut.commitDelete(),
        throwsA(isA<TransactionFailedException>()),
      );
    });

    test('forwards other exceptions', () async {
      when(() => mockFirebaseStore.delete(
            any(),
            eTag: any(named: 'eTag'),
            eTagReceiver: any(named: 'eTagReceiver'),
          )).thenThrow(Exception('test'));

      expect(
        () => sut.commitDelete(),
        throwsA(isA<Exception>().having(
          (e) => (e as dynamic).message,
          'message',
          'test',
        )),
      );
    });

    test('throws when trying to commit twice', () {
      sut.commitDelete();
      expect(() => sut.commitDelete(), throwsA(isA<AlreadyComittedError>()));
    });
  });
}
