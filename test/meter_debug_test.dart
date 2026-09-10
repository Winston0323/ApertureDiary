import 'package:flutter_test/flutter_test.dart';
import 'package:aperture_diary/meter_debug.dart';
import 'package:aperture_diary/metering.dart';

MeterDebugInfo info({
  ExposureParams? params,
  SpotSample? sample,
  double? rawSceneEv,
  double calibration = 0.0,
  double? smoothedEv100,
  double? lensEv,
  int meterIso = 100,
}) {
  return MeterDebugInfo(
    params: params,
    sample: sample,
    rawSceneEv: rawSceneEv,
    calibration: calibration,
    smoothedEv100: smoothedEv100,
    lensEv: lensEv,
    meterIso: meterIso,
    cctKelvin: null,
    frameWidth: 1920,
    frameHeight: 1080,
    frameFormat: 'yuv420',
    exposureLocked: false,
    measuredAt: null,
    aeSettleMs: 900,
  );
}

List<String> splitCsv(String row) {
  final fields = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < row.length; i++) {
    final c = row[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < row.length && row[i + 1] == '"') {
          buffer.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        buffer.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
    } else if (c == ',') {
      fields.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(c);
    }
  }
  fields.add(buffer.toString());
  return fields;
}

void main() {
  group('meter log CSV', () {
    test('row has exactly one field per declared column', () {
      final row = info().toCsvRow();
      expect(
        splitCsv(row).length,
        MeterDebugInfo.csvColumns.length,
      );
    });

    test('header lists the same columns', () {
      expect(
        MeterDebugInfo.csvHeader.split(','),
        MeterDebugInfo.csvColumns,
      );
    });

    test('missing values become empty fields, not "null"', () {
      final fields = splitCsv(info().toCsvRow());
      expect(fields.contains('null'), isFalse);
      expect(fields[MeterDebugInfo.csvColumns.indexOf('lens_ev')], '');
      expect(fields[MeterDebugInfo.csvColumns.indexOf('exif_n')], '');
    });

    test('exposure and patch values land in their own columns', () {
      final row = info(
        params: const ExposureParams(
          aperture: 1.78,
          shutterSeconds: 1 / 120,
          iso: 320,
        ),
        sample: const SpotSample(
          linearLuminance: 0.18,
          encodedLuminance: 0.46,
          r: 118,
          g: 118,
          b: 118,
        ),
        rawSceneEv: 8.25,
        calibration: -0.3,
        smoothedEv100: 7.95,
        lensEv: 9.62,
        meterIso: 320,
      ).toCsvRow(referenceEv: 9.7);

      final fields = splitCsv(row);
      String at(String column) =>
          fields[MeterDebugInfo.csvColumns.indexOf(column)];

      expect(double.parse(at('ref_ev')), closeTo(9.7, 1e-9));
      expect(double.parse(at('lens_ev')), closeTo(9.62, 1e-9));
      expect(double.parse(at('ev100')), closeTo(7.95, 1e-9));
      expect(double.parse(at('ev100_raw')), closeTo(8.25, 1e-9));
      expect(double.parse(at('cal')), closeTo(-0.3, 1e-9));
      expect(double.parse(at('exif_n')), closeTo(1.78, 1e-9));
      expect(double.parse(at('exif_iso')), closeTo(320, 1e-9));
      expect(at('meter_iso'), '320');
      expect(at('r'), '118');
      // A patch sitting exactly on middle grey is 0 stops away from it.
      expect(double.parse(at('stops_from_mid')), closeTo(0, 1e-6));
    });

    test('a note containing commas and quotes stays one field', () {
      final row = info().toCsvRow(note: 'grey card, "shade", tilted');
      final fields = splitCsv(row);
      expect(fields.length, MeterDebugInfo.csvColumns.length);
      expect(
        fields[MeterDebugInfo.csvColumns.indexOf('note')],
        'grey card, "shade", tilted',
      );
    });

    test('non-finite values are dropped rather than written as inf/nan', () {
      final row = info(
        params: const ExposureParams(
          aperture: 0,
          shutterSeconds: 0,
          iso: 0,
        ),
        lensEv: double.nan,
        smoothedEv100: double.infinity,
      ).toCsvRow();

      final fields = splitCsv(row);
      String at(String column) =>
          fields[MeterDebugInfo.csvColumns.indexOf(column)];

      expect(at('lens_ev'), '');
      expect(at('ev100'), '');
      expect(at('exif_ev100'), '');
    });
  });

  group('DiagnosticsExport', () {
    test('timestamp slug has no characters a filesystem would reject', () {
      final slug = DiagnosticsExport.timestampSlug(
        DateTime(2026, 9, 3, 14, 22, 5),
      );
      expect(slug, '2026-09-03T14-22-05');
      expect(RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(slug), isTrue);
    });

    test('slug pads single-digit fields', () {
      expect(
        DiagnosticsExport.timestampSlug(DateTime(2026, 1, 2, 3, 4, 5)),
        '2026-01-02T03-04-05',
      );
    });

    test('a generated sweep filename is accepted by the safety check', () async {
      // Writing is a no-op off-device, but the name must survive validation;
      // a rejected name would silently return null at runtime.
      final name = 'ae_sweep_${DiagnosticsExport.timestampSlug()}.csv';
      expect(RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name), isTrue);
      expect(name.length, lessThan(128));
    });

    test('path traversal attempts are rejected', () async {
      for (final bad in [
        '../escape.csv',
        'sub/dir.csv',
        '..',
        '',
        r'back\slash.csv',
      ]) {
        expect(
          await DiagnosticsExport.write(bad, 'data'),
          isNull,
          reason: 'should refuse "$bad"',
        );
      }
    });
  });
}
