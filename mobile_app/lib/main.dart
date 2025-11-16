import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

const _asciiCharacters = " .'`^\",:;Il!i><~+_-?][}{1)(|\\/*tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$";
final List<String> _asciiTable = _asciiCharacters.split("");
const double _charAspect = 0.5;
const int _targetAsciiWidth = 80;
const Duration _frameThrottle = Duration(milliseconds: 90);

class ColorSchemeOption {
  const ColorSchemeOption({
    required this.id,
    required this.title,
    this.palette,
  });

  final String id;
  final String title;
  final List<Color>? palette;
}

const List<ColorSchemeOption> _colorSchemes = [
  ColorSchemeOption(id: '1', title: 'Монохром', palette: null),
  ColorSchemeOption(
    id: '2',
    title: 'Тёплый закат',
    palette: [
      Color(0xFF5B1A18),
      Color(0xFF872B1A),
      Color(0xFFB2381B),
      Color(0xFFE05220),
      Color(0xFFF07C2E),
      Color(0xFFF2A541),
      Color(0xFFF5C664),
    ],
  ),
  ColorSchemeOption(
    id: '3',
    title: 'Неоновая радуга',
    palette: [
      Color(0xFF1428A0),
      Color(0xFF2F5CE3),
      Color(0xFF4D9CFF),
      Color(0xFF6AE6FF),
      Color(0xFF6AFFC3),
      Color(0xFF89FF79),
      Color(0xFFE6FF5C),
      Color(0xFFFF9284),
    ],
  ),
  ColorSchemeOption(
    id: '4',
    title: 'Изумрудное свечение',
    palette: [
      Color(0xFF0B2F26),
      Color(0xFF114638),
      Color(0xFF19604C),
      Color(0xFF1F7A5E),
      Color(0xFF38A072),
      Color(0xFF53C888),
      Color(0xFF7AF2A0),
    ],
  ),
];

class AsciiFrame {
  const AsciiFrame(this.spans);

  final List<InlineSpan> spans;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AsciiCameraApp());
}

class AsciiCameraApp extends StatefulWidget {
  const AsciiCameraApp({super.key});

  @override
  State<AsciiCameraApp> createState() => _AsciiCameraAppState();
}

class _AsciiCameraAppState extends State<AsciiCameraApp> {
  CameraController? _controller;
  bool _mirror = false;
  bool _permissionDenied = false;
  bool _isProcessing = false;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  String _selectedSchemeId = _colorSchemes.first.id;
  AsciiFrame? _currentFrame;
  String? _errorMessage;

  ColorSchemeOption get _currentScheme =>
      _colorSchemes.firstWhere((scheme) => scheme.id == _selectedSchemeId);

  @override
  void initState() {
    super.initState();
    unawaited(_initializeCamera());
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initializeCamera() async {
    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        if (mounted) {
          setState(() {
            _permissionDenied = true;
          });
        }
        return;
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _errorMessage = 'Камера не найдена.';
          });
        }
        return;
      }

      final preferred = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        preferred,
        ResolutionPreset.low,
        imageFormatGroup: ImageFormatGroup.yuv420,
        enableAudio: false,
      );

      _controller = controller;
      _mirror = preferred.lensDirection == CameraLensDirection.front;

      await controller.initialize();
      await controller.startImageStream(_processCameraImage);

      if (mounted) {
        setState(() {});
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Ошибка инициализации камеры: $error';
        });
      }
    }
  }

  void _processCameraImage(CameraImage image) {
    final now = DateTime.now();
    if (_isProcessing || now.difference(_lastFrame) < _frameThrottle) {
      return;
    }

    _isProcessing = true;
    _lastFrame = now;

    try {
      final frame = _buildAsciiFrame(
        image,
        scheme: _currentScheme,
        mirror: _mirror,
        targetWidth: _targetAsciiWidth,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _currentFrame = frame;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Ошибка обработки кадра: $error';
        });
      }
    } finally {
      _isProcessing = false;
    }
  }

  AsciiFrame _buildAsciiFrame(
    CameraImage image, {
    required ColorSchemeOption scheme,
    required bool mirror,
    required int targetWidth,
  }) {
    final yPlane = image.planes.first;
    final width = image.width;
    final height = image.height;
    final rowStride = yPlane.bytesPerRow;
    final pixelStride = yPlane.bytesPerPixel ?? 1;
    final bytes = yPlane.bytes;

    final targetHeight = math.max(1,
        ((height / width) * targetWidth * _charAspect).round());
    final double xScale = width / targetWidth;
    final double yScale = height / targetHeight;

    final List<InlineSpan> spans = <InlineSpan>[];
    final TextStyle baseStyle = const TextStyle(
      fontFamily: 'Courier',
      letterSpacing: 0,
      fontSize: 10,
      height: 1.05,
      color: Colors.white,
    );

    if (scheme.palette == null) {
      for (int y = 0; y < targetHeight; y++) {
        final row = StringBuffer();
        final srcY = (y * yScale).floor().clamp(0, height - 1);
        for (int x = 0; x < targetWidth; x++) {
          final srcXUnclamped = (x * xScale).floor();
          final srcX = mirror
              ? (width - 1 - srcXUnclamped).clamp(0, width - 1)
              : srcXUnclamped.clamp(0, width - 1);
          final index = srcY * rowStride + srcX * pixelStride;
          if (index >= 0 && index < bytes.length) {
            final luminance = bytes[index];
            final normalized = luminance / 255.0;
            final charIndex = (normalized * (_asciiTable.length - 1))
                .clamp(0, _asciiTable.length - 1)
                .toInt();
            row.write(_asciiTable[charIndex]);
          } else {
            row.write(' ');
          }
        }
        spans.add(TextSpan(text: '${row.toString()}\n', style: baseStyle));
      }

      return AsciiFrame(spans);
    }

    final palette = scheme.palette!;

    for (int y = 0; y < targetHeight; y++) {
      final rowBuffer = StringBuffer();
      Color? segmentColor;
      final srcY = (y * yScale).floor().clamp(0, height - 1);

      void flush() {
        if (rowBuffer.isEmpty) {
          return;
        }
        spans.add(TextSpan(
          text: rowBuffer.toString(),
          style: baseStyle.copyWith(color: segmentColor ?? baseStyle.color),
        ));
        rowBuffer.clear();
      }

      for (int x = 0; x < targetWidth; x++) {
        final srcXUnclamped = (x * xScale).floor();
        final srcX = mirror
            ? (width - 1 - srcXUnclamped).clamp(0, width - 1)
            : srcXUnclamped.clamp(0, width - 1);
        final index = srcY * rowStride + srcX * pixelStride;
        if (index < 0 || index >= bytes.length) {
          if (segmentColor != null) {
            flush();
            segmentColor = null;
          }
          rowBuffer.write(' ');
          continue;
        }

        final luminance = bytes[index];
        final normalized = luminance / 255.0;
        final charIndex = (normalized * (_asciiTable.length - 1))
            .clamp(0, _asciiTable.length - 1)
            .toInt();
        final color = _colorFromPalette(palette, normalized);

        if (segmentColor == null) {
          segmentColor = color;
        } else if (color.value != segmentColor!.value) {
          flush();
          segmentColor = color;
        }

        rowBuffer.write(_asciiTable[charIndex]);
      }

      flush();
      spans.add(TextSpan(text: '\n', style: baseStyle));
    }

    return AsciiFrame(spans);
  }

  Color _colorFromPalette(List<Color> palette, double normalized) {
    if (palette.isEmpty) {
      return Colors.white;
    }

    final value = normalized.clamp(0.0, 1.0);
    if (palette.length == 1) {
      return palette.first;
    }

    final scaled = value * (palette.length - 1);
    final lowerIndex = scaled.floor();
    final upperIndex = math.min(palette.length - 1, lowerIndex + 1);
    final t = scaled - lowerIndex;
    return Color.lerp(palette[lowerIndex], palette[upperIndex], t) ??
        palette[lowerIndex];
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: const Text('ASCII камера'),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButton<String>(
                  value: _selectedSchemeId,
                  dropdownColor: Colors.grey.shade900,
                  iconEnabledColor: Colors.white,
                  items: _colorSchemes
                      .map(
                        (scheme) => DropdownMenuItem<String>(
                          value: scheme.id,
                          child: Text(
                            scheme.title,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _selectedSchemeId = value;
                    });
                  },
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      border: Border.all(color: Colors.white24),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: _buildContent(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_permissionDenied) {
      return const Center(
        child: Text(
          'Доступ к камере запрещён. Разрешите доступ в настройках устройства.',
          textAlign: TextAlign.center,
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Text(
          _errorMessage!,
          textAlign: TextAlign.center,
        ),
      );
    }

    if (_controller == null || !_controller!.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    final spans = _currentFrame?.spans;
    if (spans == null || spans.isEmpty) {
      return const Center(
        child: Text(
          'Ожидание первого кадра...',
          textAlign: TextAlign.center,
        ),
      );
    }

    return SingleChildScrollView(
      child: RichText(
        text: TextSpan(
          style: const TextStyle(
            fontFamily: 'Courier',
            fontSize: 10,
            height: 1.05,
            color: Colors.white,
          ),
          children: spans,
        ),
      ),
    );
  }
}
