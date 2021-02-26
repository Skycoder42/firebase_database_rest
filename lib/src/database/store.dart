import 'dart:async';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:meta/meta.dart';

import '../common/api_constants.dart';
import '../common/filter.dart';
import '../rest/models/db_response.dart';
import '../rest/models/post_response.dart';
import '../rest/rest_api.dart';
import 'etag_receiver.dart';
import 'store_event.dart';
import 'store_helpers/callback_store.dart';
import 'store_helpers/map_transform.dart';
import 'store_helpers/store_event_transformer.dart';
import 'store_helpers/store_key_event_transformer.dart';
import 'store_helpers/store_patchset.dart';
import 'store_helpers/store_transaction.dart';
import 'store_helpers/store_value_event_transformer.dart';
import 'transaction.dart';

typedef DataFromJsonCallback<T> = T Function(dynamic json);

typedef DataToJsonCallback<T> = dynamic Function(T data);

typedef PatchDataCallback<T> = T Function(
  T data,
  Map<String, dynamic> updatedFields,
);

typedef PatchSetFactory<T> = PatchSet<T> Function(Map<String, dynamic> data);

abstract class FirebaseStore<T> with MapTransform<T> {
  final RestApi restApi;
  final List<String> subPaths;

  String get path => _buildPath();

  @protected
  FirebaseStore({
    required FirebaseStore<dynamic> parent,
    required String path,
  })   : restApi = parent.restApi,
        subPaths = [...parent.subPaths, path];

  @protected
  FirebaseStore.api({
    required this.restApi,
    required this.subPaths,
  });

  factory FirebaseStore.create({
    required FirebaseStore<dynamic> parent,
    required String path,
    required DataFromJsonCallback<T> onDataFromJson,
    required DataToJsonCallback<T> onDataToJson,
    required PatchDataCallback<T> onPatchData,
  }) = CallbackFirebaseStore;

  factory FirebaseStore.apiCreate({
    required RestApi restApi,
    required List<String> subPaths,
    required DataFromJsonCallback<T> onDataFromJson,
    required DataToJsonCallback<T> onDataToJson,
    required PatchDataCallback<T> onPatchData,
  }) = CallbackFirebaseStore.api;

  FirebaseStore<U> subStore<U>({
    required String path,
    required DataFromJsonCallback<U> onDataFromJson,
    required DataToJsonCallback<U> onDataToJson,
    required PatchDataCallback<U> onPatchData,
  }) =>
      FirebaseStore.create(
        parent: this,
        path: path,
        onDataFromJson: onDataFromJson,
        onDataToJson: onDataToJson,
        onPatchData: onPatchData,
      );

  Future<List<String>> keys({ETagReceiver? eTagReceiver}) async {
    final response = await restApi.get(
      path: _buildPath(),
      shallow: eTagReceiver == null,
      eTag: eTagReceiver != null,
    );
    _applyETag(eTagReceiver, response);
    return (response.data as Map<String, dynamic>?)?.keys.toList() ?? [];
  }

  Future<Map<String, T>> all({ETagReceiver? eTagReceiver}) async {
    final response = await restApi.get(
      path: _buildPath(),
      eTag: eTagReceiver != null,
    );
    _applyETag(eTagReceiver, response);
    return mapTransform(response.data, dataFromJson);
  }

  Future<T?> read(String key, {ETagReceiver? eTagReceiver}) async {
    final response = await restApi.get(
      path: _buildPath(key),
      eTag: eTagReceiver != null,
    );
    _applyETag(eTagReceiver, response);
    return response.data != null ? dataFromJson(response.data!) : null;
  }

  Future<T?> write(
    String key,
    T data, {
    bool silent = false,
    String? eTag,
    ETagReceiver? eTagReceiver,
  }) async {
    assert(
      !silent || eTag == null,
      'Cannot set silent and eTag at the same time',
    );
    final response = await restApi.put(
      dataToJson(data),
      path: _buildPath(key),
      printMode: silent ? PrintMode.silent : null,
      ifMatch: eTag,
      eTag: eTagReceiver != null,
    );
    _applyETag(eTagReceiver, response);
    return !silent && response.data != null
        ? dataFromJson(response.data!)
        : null;
  }

  Future<String> create(T data, {ETagReceiver? eTagReceiver}) async {
    final response = await restApi.post(
      dataToJson(data),
      path: _buildPath(),
      eTag: eTagReceiver != null,
    );
    _applyETag(eTagReceiver, response);
    final result = PostResponse.fromJson(response.data as Map<String, dynamic>);
    return result.name;
  }

  Future<T?> update(
    String key,
    Map<String, dynamic> updateFields, {
    T? currentData,
  }) async {
    final response = await restApi.patch(
      updateFields,
      path: _buildPath(key),
      printMode: currentData == null ? PrintMode.silent : null,
    );
    return currentData != null
        ? patchData(currentData, response.data as Map<String, dynamic>)
        : null;
  }

  Future<void> delete(
    String key, {
    String? eTag,
    ETagReceiver? eTagReceiver,
  }) async {
    final response = await restApi.delete(
      path: _buildPath(key),
      printMode: eTag == null ? PrintMode.silent : null,
      ifMatch: eTag,
      eTag: eTagReceiver != null,
    );
    _applyETag(eTagReceiver, response);
  }

  Future<Map<String, T>> query(Filter filter) async {
    final response = await restApi.get(
      path: _buildPath(),
      filter: filter,
    );
    return mapTransform(response.data, dataFromJson);
  }

  Future<List<String>> queryKeys(Filter filter) async {
    final response = await restApi.get(
      path: _buildPath(),
      filter: filter,
    );
    return (response.data as Map<String, dynamic>?)?.keys.toList() ?? [];
  }

  Future<FirebaseTransaction<T>> transaction(
    String key, {
    ETagReceiver? eTagReceiver,
  }) async {
    final response = await restApi.get(
      path: _buildPath(key),
      eTag: true,
    );
    return StoreTransaction(
      store: this,
      key: key,
      value: response.data != null ? dataFromJson(response.data!) : null,
      eTag: response.eTag!,
      eTagReceiver: eTagReceiver,
    );
  }

  Future<Stream<StoreEvent<T>>> streamAll() async {
    final stream = await restApi.stream(
      path: _buildPath(),
    );
    return stream.transform(StoreEventTransformer(
      dataFromJson: dataFromJson,
      patchSetFactory: (data) => StorePatchSet(store: this, data: data),
    ));
  }

  Future<Stream<KeyEvent>> streamKeys() async {
    final stream = await restApi.stream(
      path: _buildPath(),
      shallow: true,
    );
    return stream.transform(const StoreKeyEventTransformer());
  }

  Future<Stream<ValueEvent<T>>> streamEntry(String key) async {
    final stream = await restApi.stream(
      path: _buildPath(key),
    );
    return stream.transform(StoreValueEventTransformer(
      dataFromJson: dataFromJson,
      patchSetFactory: (data) => StorePatchSet(store: this, data: data),
    ));
  }

  Future<Stream<StoreEvent<T>>> streamQuery(Filter filter) async {
    final stream = await restApi.stream(
      path: _buildPath(),
      filter: filter,
    );
    return stream.transform(StoreEventTransformer(
      dataFromJson: dataFromJson,
      patchSetFactory: (data) => StorePatchSet(store: this, data: data),
    ));
  }

  Future<Stream<KeyEvent>> streamQueryKeys(Filter filter) async {
    final stream = await restApi.stream(
      path: _buildPath(),
      filter: filter,
    );
    return stream.transform(const StoreKeyEventTransformer());
  }

  Future<void> destroy({
    String? eTag,
    ETagReceiver? eTagReceiver,
  }) async {
    final response = await restApi.delete(
      path: _buildPath(),
      printMode: eTag == null ? PrintMode.silent : null,
      ifMatch: eTag,
      eTag: eTagReceiver != null,
    );
    _applyETag(eTagReceiver, response);
  }

  @protected
  T dataFromJson(dynamic json); // json cannot be null

  @protected
  dynamic dataToJson(T data); // return cannot be null

  @protected
  T patchData(T data, Map<String, dynamic> updatedFields);

  String _buildPath([String? key]) =>
      (key != null ? [...subPaths, key] : subPaths).join('/');

  void _applyETag(ETagReceiver? eTagReceiver, DbResponse response) {
    if (eTagReceiver != null) {
      assert(
        response.eTag != null,
        'ETag-Header must not be null when an ETag has been requested',
      );
      eTagReceiver.eTag = response.eTag;
    }
  }
}
