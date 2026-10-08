import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() {
  runApp(const VideoNoteApp());
}

class VideoNoteApp extends StatelessWidget {
  const VideoNoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2962FF);
    return MaterialApp(
      title: 'Video Note',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}
