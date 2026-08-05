const double feetPerMetre = 3.28084;

/// Converts a stored metric length into the unit currently on display.
double convertLength(double metres, {required bool useFeet}) =>
    useFeet ? metres * feetPerMetre : metres;

/// Converts a length entered in the displayed unit back to metres.
double toMetres(double value, {required bool useFeet}) =>
    useFeet ? value / feetPerMetre : value;

/// Trims a value to at most one decimal, dropping it when it adds nothing.
String formatNumber(double value) {
  if (!value.isFinite) return '—';
  if ((value - value.round()).abs() < 0.05) return '${value.round()}';
  return value.toStringAsFixed(1);
}

String formatLength(double metres, {required bool useFeet}) {
  if (!metres.isFinite || metres <= 0) return '—';
  return '${formatNumber(convertLength(metres, useFeet: useFeet))} '
      '${useFeet ? 'ft' : 'm'}';
}
