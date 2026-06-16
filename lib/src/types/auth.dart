/// Base type for the credentials accepted by `signin` and `signup`.
///
/// The concrete subtypes cover the different SurrealDB authentication levels:
/// root, namespace, database, and the access based variants (system user,
/// bearer key, and record access).
sealed class AnyAuth {
  const AnyAuth();

  /// The parameter object sent to the server for this set of credentials.
  Map<String, Object?> toJson();
}

Map<String, Object?> _withScope({
  String? namespace,
  String? database,
  String? access,
}) =>
    {
      if (namespace != null) 'NS': namespace,
      if (database != null) 'DB': database,
      if (access != null) 'AC': access,
    };

/// Root level credentials, granting access to the whole server.
final class RootAuth extends AnyAuth {
  const RootAuth({required this.username, required this.password});

  final String username;
  final String password;

  @override
  Map<String, Object?> toJson() => {'user': username, 'pass': password};
}

/// Namespace level credentials.
final class NamespaceAuth extends AnyAuth {
  const NamespaceAuth({
    required this.namespace,
    required this.username,
    required this.password,
  });

  final String namespace;
  final String username;
  final String password;

  @override
  Map<String, Object?> toJson() => {
        ..._withScope(namespace: namespace),
        'user': username,
        'pass': password,
      };
}

/// Database level credentials.
final class DatabaseAuth extends AnyAuth {
  const DatabaseAuth({
    required this.namespace,
    required this.database,
    required this.username,
    required this.password,
  });

  final String namespace;
  final String database;
  final String username;
  final String password;

  @override
  Map<String, Object?> toJson() => {
        ..._withScope(namespace: namespace, database: database),
        'user': username,
        'pass': password,
      };
}

/// Credentials for a system user scoped to a named access method.
final class AccessSystemAuth extends AnyAuth {
  const AccessSystemAuth({
    required this.access,
    required this.username,
    required this.password,
    this.namespace,
    this.database,
  });

  final String access;
  final String username;
  final String password;
  final String? namespace;
  final String? database;

  @override
  Map<String, Object?> toJson() => {
        ..._withScope(
          namespace: namespace,
          database: database,
          access: access,
        ),
        'user': username,
        'pass': password,
      };
}

/// Credentials for a bearer key access method.
final class AccessBearerAuth extends AnyAuth {
  const AccessBearerAuth({
    required this.access,
    required this.key,
    this.namespace,
    this.database,
  });

  final String access;
  final String key;
  final String? namespace;
  final String? database;

  @override
  Map<String, Object?> toJson() => {
        ..._withScope(
          namespace: namespace,
          database: database,
          access: access,
        ),
        'key': key,
      };
}

/// Credentials for a record access method, used for application end users.
///
/// The [variables] are the values the access method's `SIGNIN` or `SIGNUP`
/// clause expects, for example an email and password. They are sent alongside
/// the namespace, database, and access fields.
final class AccessRecordAuth extends AnyAuth {
  const AccessRecordAuth({
    required this.access,
    required this.variables,
    this.namespace,
    this.database,
  });

  final String access;
  final Map<String, Object?> variables;
  final String? namespace;
  final String? database;

  @override
  Map<String, Object?> toJson() => {
        ..._withScope(
          namespace: namespace,
          database: database,
          access: access,
        ),
        ...variables,
      };
}

/// The result of `signin` or `signup`. SurrealDB returns at least an access
/// token, and may also return a refresh token when the access method supports
/// it.
class Tokens {
  const Tokens({required this.access, this.refresh});

  final String access;
  final String? refresh;
}
