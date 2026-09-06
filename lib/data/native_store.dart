import 'package:sqflite/sqflite.dart';

import '../domain/domain.dart';
import 'sqlite_store.dart';

/// Pass a path in the app's private data directory. The composition root chooses
/// the initial device reporting zone and pinned metadata before opening storage.
Future<Result<SqliteStore>> openNativeStore({
  required String path,
  required CurrencyMetadata currencies,
  required AppSettings initialSettings,
}) => SqliteStore.open(
  path: path,
  factory: databaseFactory,
  currencies: currencies,
  initialSettings: initialSettings,
);
