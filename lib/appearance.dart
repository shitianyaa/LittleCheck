import 'package:flutter/material.dart';

enum AppPalette {
  blue('雾蓝', 0xFF4F7693, 0xFF8AACCA, 0xFFFCFCFD, 0xFF191D22),
  green('松绿', 0xFF3D7866, 0xFF8DC6AE, 0xFFFBFCFA, 0xFF18211D),
  amber('暖橙', 0xFF986839, 0xFFD9B084, 0xFFFDFBF8, 0xFF231F1B),
  violet('鸢紫', 0xFF7C6998, 0xFFBCA9D8, 0xFFFCFBFD, 0xFF201C25),
  graphite('石墨', 0xFF626D7A, 0xFFADB7C3, 0xFFFBFCFD, 0xFF1A1D21);

  const AppPalette(this.label, this.light, this.dark, this.paper, this.night);
  final String label;
  final int light, dark, paper, night;
  Color primary(Brightness brightness) =>
      Color(brightness == Brightness.dark ? dark : light);
  Color surface(Brightness brightness) =>
      Color(brightness == Brightness.dark ? night : paper);
}
