import 'package:freezed_annotation/freezed_annotation.dart';

part 'db_response.freezed.dart';

@freezed
abstract class DbResponse with _$DbResponse {
  const factory DbResponse({
    @required Map<String, dynamic> data,
    String eTag,
  }) = _DbResponse;
}
