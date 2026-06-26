import 'package:flutter/material.dart';

@pragma("vm:entry-point")
void overlayMain() {
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        color: Colors.transparent,
        child: FloatingBall(),
      ),
    ),
  );
}

class FloatingBall extends StatelessWidget {
  const FloatingBall({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 60,
      height: 60,
      decoration: const BoxDecoration(
        color: Colors.green,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.videocam, color: Colors.white),
    );
  }
}