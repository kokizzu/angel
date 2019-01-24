import 'dart:convert';

import 'package:charcode/ascii.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:string_scanner/string_scanner.dart';
import 'query.dart';

final DateFormat dateYmd = new DateFormat('yyyy-MM-dd');
final DateFormat dateYmdHms = new DateFormat('yyyy-MM-dd HH:mm:ss');

/// The ORM prefers using substitution values, which allow for prepared queries,
/// and prevent SQL injection attacks.
@deprecated
String sanitizeExpression(String unsafe) {
  var buf = new StringBuffer();
  var scanner = new StringScanner(unsafe);
  int ch;

  while (!scanner.isDone) {
    // Ignore comment starts
    if (scanner.scan('--') || scanner.scan('/*'))
      continue;

    // Ignore all single quotes and attempted escape sequences
    else if (scanner.scan("'") || scanner.scan('\\'))
      continue;

    // Otherwise, add the next char, unless it's a null byte.
    else if ((ch = scanner.readChar()) != $nul && ch != null)
      buf.writeCharCode(ch);
  }

  return toSql(buf.toString(), withQuotes: false);
}

abstract class SqlExpressionBuilder<T> {
  final Query query;
  final String columnName;
  bool _isProperty = false;
  String _substitution;

  SqlExpressionBuilder(this.query, this.columnName);

  String get substitution {
    var c = _isProperty ? 'prop' : columnName;
    return _substitution ??= query.reserveName(c);
  }

  bool get hasValue;

  String compile();
}

class NumericSqlExpressionBuilder<T extends num>
    extends SqlExpressionBuilder<T> {
  bool _hasValue = false;
  String _op = '=';
  String _raw;
  T _value;

  NumericSqlExpressionBuilder(Query query, String columnName)
      : super(query, columnName);

  @override
  bool get hasValue => _hasValue;

  bool _change(String op, T value) {
    _raw = null;
    _op = op;
    _value = value;
    return _hasValue = true;
  }

  @override
  String compile() {
    if (_raw != null) return _raw;
    if (_value == null) return null;
    return '$_op $_value';
  }

  operator <(T value) => _change('<', value);

  operator >(T value) => _change('>', value);

  operator <=(T value) => _change('<=', value);

  operator >=(T value) => _change('>=', value);

  void lessThan(T value) {
    _change('<', value);
  }

  void lessThanOrEqualTo(T value) {
    _change('<=', value);
  }

  void greaterThan(T value) {
    _change('>', value);
  }

  void greaterThanOrEqualTo(T value) {
    _change('>=', value);
  }

  void equals(T value) {
    _change('=', value);
  }

  void notEquals(T value) {
    _change('!=', value);
  }

  void isBetween(T lower, T upper) {
    _raw = 'BETWEEN $lower AND $upper';
    _hasValue = true;
  }

  void isNotBetween(T lower, T upper) {
    _raw = 'NOT BETWEEN $lower AND $upper';
    _hasValue = true;
  }

  void isIn(Iterable<T> values) {
    _raw = 'IN (' + values.join(', ') + ')';
    _hasValue = true;
  }

  void isNotIn(Iterable<T> values) {
    _raw = 'NOT IN (' + values.join(', ') + ')';
    _hasValue = true;
  }
}

class EnumSqlExpressionBuilder<T> extends SqlExpressionBuilder<T> {
  final int Function(T) _getValue;
  bool _hasValue = false;
  String _op = '=';
  String _raw;
  int _value;

  EnumSqlExpressionBuilder(Query query, String columnName, this._getValue)
      : super(query, columnName);

  @override
  bool get hasValue => _hasValue;

  bool _change(String op, T value) {
    _raw = null;
    _op = op;
    _value = _getValue(value);
    return _hasValue = true;
  }

  UnsupportedError _unsupported() =>
      UnsupportedError('Enums do not support this operation.');

  @override
  String compile() {
    if (_raw != null) return _raw;
    if (_value == null) return null;
    return '$_op $_value';
  }

  void isNull() {
    _hasValue = true;
    _raw = 'IS NOT NULL';
  }

  void isNotNull() {
    _hasValue = true;
    _raw = 'IS NOT NULL';
  }

  void equals(T value) {
    _change('=', value);
  }

  void notEquals(T value) {
    _change('!=', value);
  }

  void isBetween(T lower, T upper) => throw _unsupported();

  void isNotBetween(T lower, T upper) => throw _unsupported();

  void isIn(Iterable<T> values) {
    _raw = 'IN (' + values.map(_getValue).join(', ') + ')';
    _hasValue = true;
  }

  void isNotIn(Iterable<T> values) {
    _raw = 'NOT IN (' + values.map(_getValue).join(', ') + ')';
    _hasValue = true;
  }
}

class StringSqlExpressionBuilder extends SqlExpressionBuilder<String> {
  bool _hasValue = false;
  String _op = '=', _raw, _value;

  StringSqlExpressionBuilder(Query query, String columnName)
      : super(query, columnName);

  @override
  bool get hasValue => _hasValue;

  String get lowerName => '${substitution}_lower';

  String get upperName => '${substitution}_upper';

  bool _change(String op, String value) {
    _raw = null;
    _op = op;
    _value = value;
    query.substitutionValues[substitution] = _value;
    return _hasValue = true;
  }

  @override
  String compile() {
    if (_raw != null) return _raw;
    if (_value == null) return null;
    return "$_op @$substitution";
  }

  void isEmpty() => equals('');

  void equals(String value) {
    _change('=', value);
  }

  void notEquals(String value) {
    _change('!=', value);
  }

  /// Builds a `LIKE` predicate.
  ///
  /// To prevent injections, the [pattern] is called with a name that
  /// will be escaped by the underlying [QueryExecutor].
  ///
  /// Example:
  /// ```dart
  /// carNameBuilder.like((name) => 'Mazda %$name%');
  /// ```
  void like(String Function(String) pattern) {
    _raw = 'LIKE \'' + pattern('@$substitution') + '\'';
    query.substitutionValues[substitution] = _value;
    _hasValue = true;
  }

  void isBetween(String lower, String upper) {
    query.substitutionValues[lowerName] = lower;
    query.substitutionValues[upperName] = upper;
    _raw = "BETWEEN @$lowerName AND @$upperName";
    _hasValue = true;
  }

  void isNotBetween(String lower, String upper) {
    query.substitutionValues[lowerName] = lower;
    query.substitutionValues[upperName] = upper;
    _raw = "NOT BETWEEN @$lowerName AND @$upperName";
    _hasValue = true;
  }

  String _in(Iterable<String> values) {
    return 'IN (' +
        values.map((v) {
          var name = query.reserveName('${columnName}_in_value');
          query.substitutionValues[name] = v;
          return '@$name';
        }).join(', ') +
        ')';
  }

  void isIn(Iterable<String> values) {
    _raw = _in(values);
    _hasValue = true;
  }

  void isNotIn(Iterable<String> values) {
    _raw = 'NOT ' + _in(values);
    _hasValue = true;
  }
}

class BooleanSqlExpressionBuilder extends SqlExpressionBuilder<bool> {
  bool _hasValue = false;
  String _op = '=', _raw;
  bool _value;

  BooleanSqlExpressionBuilder(Query query, String columnName)
      : super(query, columnName);

  @override
  bool get hasValue => _hasValue;

  bool _change(String op, bool value) {
    _raw = null;
    _op = op;
    _value = value;
    return _hasValue = true;
  }

  @override
  String compile() {
    if (_raw != null) return _raw;
    if (_value == null) return null;
    var v = _value ? 'TRUE' : 'FALSE';
    return '$_op $v';
  }

  Null get isTrue => equals(true);

  Null get isFalse => equals(false);

  void equals(bool value) {
    _change('=', value);
  }

  void notEquals(bool value) {
    _change('!=', value);
  }
}

class DateTimeSqlExpressionBuilder extends SqlExpressionBuilder<DateTime> {
  NumericSqlExpressionBuilder<int> _year, _month, _day, _hour, _minute, _second;

  String _raw;

  DateTimeSqlExpressionBuilder(Query query, String columnName)
      : super(query, columnName);

  NumericSqlExpressionBuilder<int> get year =>
      _year ??= new NumericSqlExpressionBuilder(query, 'year');
  NumericSqlExpressionBuilder<int> get month =>
      _month ??= new NumericSqlExpressionBuilder(query, 'month');
  NumericSqlExpressionBuilder<int> get day =>
      _day ??= new NumericSqlExpressionBuilder(query, 'day');
  NumericSqlExpressionBuilder<int> get hour =>
      _hour ??= new NumericSqlExpressionBuilder(query, 'hour');
  NumericSqlExpressionBuilder<int> get minute =>
      _minute ??= new NumericSqlExpressionBuilder(query, 'minute');
  NumericSqlExpressionBuilder<int> get second =>
      _second ??= new NumericSqlExpressionBuilder(query, 'second');

  @override
  bool get hasValue =>
      _raw?.isNotEmpty == true ||
      _year?.hasValue == true ||
      _month?.hasValue == true ||
      _day?.hasValue == true ||
      _hour?.hasValue == true ||
      _minute?.hasValue == true ||
      _second?.hasValue == true;

  bool _change(String _op, DateTime dt, bool time) {
    var dateString = time ? dateYmdHms.format(dt) : dateYmd.format(dt);
    _raw = '$columnName $_op \'$dateString\'';
    return true;
  }

  operator <(DateTime value) => _change('<', value, true);

  operator <=(DateTime value) => _change('<=', value, true);

  operator >(DateTime value) => _change('>', value, true);

  operator >=(DateTime value) => _change('>=', value, true);

  void equals(DateTime value, {bool includeTime: true}) {
    _change('=', value, includeTime != false);
  }

  void lessThan(DateTime value, {bool includeTime: true}) {
    _change('<', value, includeTime != false);
  }

  void lessThanOrEqualTo(DateTime value, {bool includeTime: true}) {
    _change('<=', value, includeTime != false);
  }

  void greaterThan(DateTime value, {bool includeTime: true}) {
    _change('>', value, includeTime != false);
  }

  void greaterThanOrEqualTo(DateTime value, {bool includeTime: true}) {
    _change('>=', value, includeTime != false);
  }

  void isIn(Iterable<DateTime> values) {
    _raw = '$columnName IN (' +
        values.map(dateYmdHms.format).map((s) => '$s').join(', ') +
        ')';
  }

  void isNotIn(Iterable<DateTime> values) {
    _raw = '$columnName NOT IN (' +
        values.map(dateYmdHms.format).map((s) => '$s').join(', ') +
        ')';
  }

  void isBetween(DateTime lower, DateTime upper) {
    var l = dateYmdHms.format(lower), u = dateYmdHms.format(upper);
    _raw = "$columnName BETWEEN '$l' and '$u'";
  }

  void isNotBetween(DateTime lower, DateTime upper) {
    var l = dateYmdHms.format(lower), u = dateYmdHms.format(upper);
    _raw = "$columnName NOT BETWEEN '$l' and '$u'";
  }

  @override
  String compile() {
    if (_raw?.isNotEmpty == true) return _raw;
    List<String> parts = [];
    if (year?.hasValue == true)
      parts.add('YEAR($columnName) ${year.compile()}');
    if (month?.hasValue == true)
      parts.add('MONTH($columnName) ${month.compile()}');
    if (day?.hasValue == true) parts.add('DAY($columnName) ${day.compile()}');
    if (hour?.hasValue == true)
      parts.add('HOUR($columnName) ${hour.compile()}');
    if (minute?.hasValue == true)
      parts.add('MINUTE($columnName) ${minute.compile()}');
    if (second?.hasValue == true)
      parts.add('SECOND($columnName) ${second.compile()}');

    return parts.isEmpty ? null : parts.join(' AND ');
  }
}

abstract class JsonSqlExpressionBuilder<T, K> extends SqlExpressionBuilder<T> {
  final List<JsonSqlExpressionBuilderProperty> _properties = [];
  bool _hasValue = false;
  T _value;
  String _op;
  String _raw;

  JsonSqlExpressionBuilder(Query query, String columnName)
      : super(query, columnName);

  JsonSqlExpressionBuilderProperty operator [](K name) {
    var p = _property(name);
    _properties.add(p);
    return p;
  }

  JsonSqlExpressionBuilderProperty _property(K name);

  bool get hasRaw => _raw != null || _properties.any((p) => p.hasValue);

  @override
  bool get hasValue => _hasValue || _properties.any((p) => p.hasValue);

  _encodeValue(T v) => v;

  bool _change(String op, T value) {
    _raw = null;
    _op = op;
    _value = value;
    query.substitutionValues[substitution] = _encodeValue(_value);
    return _hasValue = true;
  }

  @override
  String compile() {
    var s = _compile();
    if (!_properties.any((p) => p.hasValue)) return s;
    s ??= '';

    for (var p in _properties) {
      if (p.hasValue) {
        var c = p.compile();

        if (c != null) {
          _hasValue = true;
          s ??= '';

          if (p.typed is! DateTimeSqlExpressionBuilder) {
            s += '${p.typed.columnName} ';
          }

          s += c;
        }
      }
    }

    return s;
  }

  String _compile() {
    if (_raw != null) return _raw;
    if (_value == null) return null;
    return "::jsonb $_op @$substitution::jsonb";
  }

  void contains(T value) {
    _change('@>', value);
  }

  void equals(T value) {
    _change('=', value);
  }
}

class MapSqlExpressionBuilder extends JsonSqlExpressionBuilder<Map, String> {
  MapSqlExpressionBuilder(Query query, String columnName)
      : super(query, columnName);

  @override
  JsonSqlExpressionBuilderProperty _property(String name) {
    return JsonSqlExpressionBuilderProperty(this, name, false);
  }

  void containsKey(String key) {
    this[key].isNotNull();
  }

  void containsPair(key, value) {
    contains({key: value});
  }
}

class ListSqlExpressionBuilder extends JsonSqlExpressionBuilder<List, int> {
  ListSqlExpressionBuilder(Query query, String columnName)
      : super(query, columnName);

  @override
  _encodeValue(List v) => json.encode(v);

  @override
  JsonSqlExpressionBuilderProperty _property(int name) {
    return JsonSqlExpressionBuilderProperty(this, name.toString(), true);
  }
}

class JsonSqlExpressionBuilderProperty {
  final JsonSqlExpressionBuilder builder;
  final String name;
  final bool isInt;
  SqlExpressionBuilder _typed;

  JsonSqlExpressionBuilderProperty(this.builder, this.name, this.isInt);

  SqlExpressionBuilder get typed => _typed;

  bool get hasValue => _typed?.hasValue == true;

  String compile() => _typed?.compile();

  T _set<T extends SqlExpressionBuilder>(T Function() value) {
    if (_typed is T) {
      return _typed as T;
    } else if (_typed != null) {
      throw StateError(
          '$nameString is already typed as $_typed, and cannot be changed.');
    } else {
      _typed = value().._isProperty = true;
      return _typed as T;
    }
  }

  String get nameString {
    if (isInt) {
      return '(${builder.columnName}->>$name)::jsonb';
    } else {
      return "(${builder.columnName}->>'$name')::jsonb";
    }
  }

  void isNotNull() {
    builder
      .._hasValue = true
      .._raw ??= ''
      .._raw += "$nameString IS NOT NULL";
  }

  void isNull() {
    builder
      .._hasValue = true
      .._raw ??= ''
      .._raw += "$nameString IS NULL";
  }

  StringSqlExpressionBuilder get asString {
    return _set(() => StringSqlExpressionBuilder(builder.query, nameString));
  }

  BooleanSqlExpressionBuilder get asBool {
    return _set(() => BooleanSqlExpressionBuilder(builder.query, nameString));
  }

  DateTimeSqlExpressionBuilder get asDateTime {
    return _set(() => DateTimeSqlExpressionBuilder(builder.query, nameString));
  }

  NumericSqlExpressionBuilder<double> get asDouble {
    return _set(
        () => NumericSqlExpressionBuilder<double>(builder.query, nameString));
  }

  NumericSqlExpressionBuilder<int> get asInt {
    return _set(
        () => NumericSqlExpressionBuilder<int>(builder.query, nameString));
  }

  MapSqlExpressionBuilder get asMap {
    return _set(() => MapSqlExpressionBuilder(builder.query, nameString));
  }

  ListSqlExpressionBuilder get asList {
    return _set(() => ListSqlExpressionBuilder(builder.query, nameString));
  }
}
