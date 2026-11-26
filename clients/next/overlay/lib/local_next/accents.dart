import 'package:flutter/material.dart';

/// Accent ink and tinted surfaces used by the paired client in both themes.
enum NextAccent {
  green(Color(0xff23633b), Color(0xff88dfa4)),
  blue(Color(0xff174d85), Color(0xff9ed0ff)),
  teal(Color(0xff006153), Color(0xff77dfc6)),
  amber(Color(0xff794b00), Color(0xffffcf75)),
  coral(Color(0xff973d27), Color(0xffffb49d)),
  slate(Color(0xff415475), Color(0xffb4c9e9)),
  red(Color(0xff9a2b34), Color(0xffffa9ad));

  const NextAccent(this.light, this.dark);
  final Color light;
  final Color dark;

  Color ink(Brightness brightness) => brightness == Brightness.dark ? dark : light;
  Color of(BuildContext context) => ink(Theme.of(context).brightness);
  Color tint(BuildContext context) => of(context).withValues(alpha: .13);
}
