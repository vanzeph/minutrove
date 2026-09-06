/// A command returns only committed state. Failures never represent partial writes.
sealed class Result<T> {
  const Result();
}

final class Success<T> extends Result<T> {
  const Success(this.value);
  final T value;
}

final class Failure<T> extends Result<T> {
  const Failure(this.error);
  final DomainError error;
}

sealed class DomainError implements Exception {
  const DomainError();
}

final class InvalidInput extends DomainError {
  const InvalidInput(this.field, this.reason);
  final String field;
  final String reason;
  @override
  String toString() => 'InvalidInput($field, $reason)';
}

final class NumericOverflow extends DomainError {
  const NumericOverflow(this.field);
  final String field;
}

final class InsufficientFunds extends DomainError {
  const InsufficientFunds({required this.coins, required this.gems});
  final bool coins;
  final bool gems;
}

final class ActiveSessionConflict extends DomainError {
  const ActiveSessionConflict();
}

final class StaleRevision extends DomainError {
  const StaleRevision();
}

final class AllowanceExceeded extends DomainError {
  const AllowanceExceeded();
}

final class StorageUnavailable extends DomainError {
  const StorageUnavailable({required this.retryable});
  final bool retryable;
}

final class UnsupportedBackupVersion extends DomainError {
  const UnsupportedBackupVersion(this.version);
  final int version;
}

final class UnsupportedDimensionalEdit extends DomainError {
  const UnsupportedDimensionalEdit();
}

final class NotFound extends DomainError {
  const NotFound();
}

final class InvalidSessionTransition extends DomainError {
  const InvalidSessionTransition();
}

final class InvalidBackup extends DomainError {
  const InvalidBackup(this.reason);
  final String reason;
}
