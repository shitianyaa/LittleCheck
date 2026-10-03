import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Shared ring-and-check mark. Animation finishes once and respects reduced motion.
class BrandMark extends StatefulWidget {
  const BrandMark({super.key, this.size = 28, this.animate = false});
  final double size;
  final bool animate;
  @override
  State<BrandMark> createState() => _BrandMarkState();
}

class _BrandMarkState extends State<BrandMark>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  );
  bool _started = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      if (widget.animate && !MediaQuery.disableAnimationsOf(context)) {
        _animation.forward();
      } else {
        _animation.value = 1;
      }
    } else if (MediaQuery.disableAnimationsOf(context)) {
      _animation.value = 1;
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: AnimatedBuilder(
      animation: _animation,
      builder: (_, _) => CustomPaint(
        size: Size.square(widget.size),
        painter: _MarkPainter(
          Theme.of(context).colorScheme.primary,
          _animation.value,
        ),
      ),
    ),
  );
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color, this.progress);
  final Color color;
  final double progress;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * .068
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final ring = Curves.easeOutCubic.transform((progress / .65).clamp(0, 1));
    canvas.drawArc(
      Rect.fromCircle(
        center: size.center(Offset.zero),
        radius: size.width * .35,
      ),
      -math.pi / 4,
      -math.pi * 1.76 * ring,
      false,
      paint,
    );
    final path = Path()
      ..moveTo(size.width * .32, size.height * .52)
      ..lineTo(size.width * .45, size.height * .65)
      ..lineTo(size.width * .71, size.height * .39);
    final metric = path.computeMetrics().first;
    final check = Curves.easeOutCubic.transform(
      ((progress - .32) / .68).clamp(0, 1),
    );
    paint.strokeWidth = size.width * .078;
    canvas.drawPath(metric.extractPath(0, metric.length * check), paint);
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.progress != progress || old.color != color;
}
