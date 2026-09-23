import 'package:hermes_android/core/services/compression_restore_store.dart';

final class InMemoryCompressionRestoreStorage
    implements CompressionRestoreStorage {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    this.value = value;
  }
}

CompressionRestoreStore testCompressionRestoreStore() =>
    CompressionRestoreStore(storage: InMemoryCompressionRestoreStorage());
