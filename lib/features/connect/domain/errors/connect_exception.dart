class ConnectException implements Exception {
  final String message;
  final String? code;
  final Object? cause;

  const ConnectException(
    this.message, {
    this.code,
    this.cause,
  });

  @override
  String toString() =>
      'ConnectException(${code != null ? '$code: ' : ''}$message)';
}

