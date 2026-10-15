/// What `export` includes. A field left null uses the server's default,
/// which includes everything except [versions].
class ExportOptions {
  const ExportOptions({
    this.users,
    this.accesses,
    this.params,
    this.functions,
    this.analyzers,
    this.apis,
    this.buckets,
    this.modules,
    this.configs,
    this.tables,
    this.versions,
    this.records,
    this.sequences,
  });

  final bool? users;
  final bool? accesses;
  final bool? params;
  final bool? functions;
  final bool? analyzers;
  final bool? apis;
  final bool? buckets;
  final bool? modules;
  final bool? configs;

  /// Whether to export tables, or the names of the tables to export.
  /// Use [ExportTables.all], [ExportTables.none] or [ExportTables.only].
  final ExportTables? tables;

  /// Whether to export every version of each record, on storage engines
  /// that keep them. Only servers before 3.0 take it: 3.0 to 3.3.0 ignore
  /// it and later versions refuse it, so it is not sent to them, nor to a
  /// server whose version was not checked.
  final bool? versions;

  /// Whether to export records, or only the table definitions.
  final bool? records;
  final bool? sequences;

  /// The request body sent to `/export`.
  Map<String, Object?> toJson() => {
        if (users != null) 'users': users,
        if (accesses != null) 'accesses': accesses,
        if (params != null) 'params': params,
        if (functions != null) 'functions': functions,
        if (analyzers != null) 'analyzers': analyzers,
        if (apis != null) 'apis': apis,
        if (buckets != null) 'buckets': buckets,
        if (modules != null) 'modules': modules,
        if (configs != null) 'configs': configs,
        if (tables != null) 'tables': tables!._value,
        if (versions != null) 'versions': versions,
        if (records != null) 'records': records,
        if (sequences != null) 'sequences': sequences,
      };
}

/// Which tables `export` includes.
final class ExportTables {
  const ExportTables._(this._value);

  /// Every table.
  static const ExportTables all = ExportTables._(true);

  /// No tables.
  static const ExportTables none = ExportTables._(false);

  /// Only the named tables.
  factory ExportTables.only(List<String> names) =>
      ExportTables._(List.unmodifiable(names));

  final Object _value;
}
