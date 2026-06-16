part of 'value.dart';

/// Base type for the SurrealDB geometry values. Every geometry serialises to
/// GeoJSON through [toJson].
sealed class Geometry extends SurrealValue {
  const Geometry();
}

/// A single point, ordered as longitude then latitude to match GeoJSON.
final class GeometryPoint extends Geometry {
  const GeometryPoint(this.longitude, this.latitude);

  final double longitude;
  final double latitude;

  /// The raw coordinate pair `[longitude, latitude]`.
  List<double> get coordinates => [longitude, latitude];

  @override
  Map<String, Object?> toJson() => {
        'type': 'Point',
        'coordinates': coordinates,
      };

  @override
  bool operator ==(Object other) =>
      other is GeometryPoint &&
      other.longitude == longitude &&
      other.latitude == latitude;

  @override
  int get hashCode => Object.hash(longitude, latitude);
}

/// A line made of two or more points.
final class GeometryLine extends Geometry {
  const GeometryLine(this.points);

  final List<GeometryPoint> points;

  @override
  Map<String, Object?> toJson() => {
        'type': 'LineString',
        'coordinates': [for (final p in points) p.coordinates],
      };

  @override
  bool operator ==(Object other) =>
      other is GeometryLine && _listEquals(other.points, points);

  @override
  int get hashCode => Object.hashAll(points);
}

/// A polygon made of one or more closed lines, the first being the exterior
/// ring and the rest interior rings.
final class GeometryPolygon extends Geometry {
  const GeometryPolygon(this.lines);

  final List<GeometryLine> lines;

  @override
  Map<String, Object?> toJson() => {
        'type': 'Polygon',
        'coordinates': [
          for (final line in lines)
            [for (final p in line.points) p.coordinates],
        ],
      };

  @override
  bool operator ==(Object other) =>
      other is GeometryPolygon && _listEquals(other.lines, lines);

  @override
  int get hashCode => Object.hashAll(lines);
}

/// A collection of points.
final class GeometryMultiPoint extends Geometry {
  const GeometryMultiPoint(this.points);

  final List<GeometryPoint> points;

  @override
  Map<String, Object?> toJson() => {
        'type': 'MultiPoint',
        'coordinates': [for (final p in points) p.coordinates],
      };

  @override
  bool operator ==(Object other) =>
      other is GeometryMultiPoint && _listEquals(other.points, points);

  @override
  int get hashCode => Object.hashAll(points);
}

/// A collection of lines.
final class GeometryMultiLine extends Geometry {
  const GeometryMultiLine(this.lines);

  final List<GeometryLine> lines;

  @override
  Map<String, Object?> toJson() => {
        'type': 'MultiLineString',
        'coordinates': [
          for (final line in lines)
            [for (final p in line.points) p.coordinates],
        ],
      };

  @override
  bool operator ==(Object other) =>
      other is GeometryMultiLine && _listEquals(other.lines, lines);

  @override
  int get hashCode => Object.hashAll(lines);
}

/// A collection of polygons.
final class GeometryMultiPolygon extends Geometry {
  const GeometryMultiPolygon(this.polygons);

  final List<GeometryPolygon> polygons;

  @override
  Map<String, Object?> toJson() => {
        'type': 'MultiPolygon',
        'coordinates': [
          for (final polygon in polygons)
            [
              for (final line in polygon.lines)
                [for (final p in line.points) p.coordinates],
            ],
        ],
      };

  @override
  bool operator ==(Object other) =>
      other is GeometryMultiPolygon && _listEquals(other.polygons, polygons);

  @override
  int get hashCode => Object.hashAll(polygons);
}

/// A collection of arbitrary geometries.
final class GeometryCollection extends Geometry {
  const GeometryCollection(this.geometries);

  final List<Geometry> geometries;

  @override
  Map<String, Object?> toJson() => {
        'type': 'GeometryCollection',
        'geometries': [for (final g in geometries) g.toJson()],
      };

  @override
  bool operator ==(Object other) =>
      other is GeometryCollection && _listEquals(other.geometries, geometries);

  @override
  int get hashCode => Object.hashAll(geometries);
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
