import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:media_store_plus/media_store_plus.dart';
import 'package:image/image.dart' as img;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  if (Platform.isAndroid) {
    await MediaStore.ensureInitialized();
    MediaStore.appFolder = "ShelfReader";
  }

  runApp(const ShelfReaderApp());
}

class ShelfReaderApp extends StatelessWidget {
  const ShelfReaderApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ShelfReader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const HomePage(),
    );
  }
}

/// 🏠 ANA EKRAN (sade)
class HomePage extends StatelessWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.menu_book, size: 120, color: Colors.white70),
                const SizedBox(height: 24),
                const Text('ShelfReader',
                    style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('Başını eğmeden rafları oku 📚',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 48),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const CameraPage()),
                    );
                  },
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Kamerayı Aç'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 18),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 📸 KAMERA SAYFASI
class CameraPage extends StatefulWidget {
  const CameraPage({super.key});
  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> with WidgetsBindingObserver {
  CameraController? _controller;
  double _quarterTurns = 0; // 0..3 => 0°, 90°, 180°, 270°
  bool _torchOn = false;
  bool _busy = false;

  double _zoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _zoomBeforeScale = 1.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cam = _controller;
    if (cam == null) return;
    if (state == AppLifecycleState.inactive) {
      cam.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _ensurePermissions() async {
    final cam = await Permission.camera.request();
    if (!cam.isGranted) {
      throw 'Kamera izni gerekli';
    }
    await Permission.photos.request();   // Android 13+ / iOS
    await Permission.storage.request();  // Android 12 ve öncesi
  }

  Future<void> _initCamera() async {
    try {
      await _ensurePermissions();

      final cams = await availableCameras();
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );

      final controller = CameraController(
        back,
        ResolutionPreset.max,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await controller.initialize();

      _minZoom = await controller.getMinZoomLevel();
      _maxZoom = await controller.getMaxZoomLevel();
      _zoom = _zoom.clamp(_minZoom, _maxZoom);
      await controller.setZoomLevel(_zoom);

      if (!mounted) return;
      setState(() => _controller = controller);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _rotateRight() => setState(() => _quarterTurns = (_quarterTurns + 1) % 4);
  void _rotateLeft()  => setState(() => _quarterTurns = (_quarterTurns - 1) % 4);
  void _reset()       => setState(() => _quarterTurns = 0);

  Future<void> _toggleTorch() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.setFlashMode(_torchOn ? FlashMode.off : FlashMode.torch);
      setState(() => _torchOn = !_torchOn);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Fener desteklenmiyor olabilir')),
        );
      }
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    _zoomBeforeScale = _zoom;
  }

  Future<void> _onScaleUpdate(ScaleUpdateDetails d) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final newZoom = (_zoomBeforeScale * d.scale).clamp(_minZoom, _maxZoom);
    if ((newZoom - _zoom).abs() > 0.01) {
      _zoom = newZoom;
      await c.setZoomLevel(_zoom);
      if (mounted) setState(() {});
    }
  }

  Future<void> _takeAndSave() async {
    if (_busy) return;
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    setState(() => _busy = true);
    try {
      final xfile = await c.takePicture();

      final bytes = await File(xfile.path).readAsBytes();
      final decoded = img.decodeImage(bytes);
      String toSavePath;

      if (decoded != null && _quarterTurns % 4 != 0) {
        final turns = (_quarterTurns % 4).toInt();
        final angle = turns * 90;
        final rotated = img.copyRotate(decoded, angle: angle);

        final dir = await getApplicationDocumentsDirectory();
        final fileName = 'shelf_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final savedPath = p.join(dir.path, fileName);
        final jpg = img.encodeJpg(rotated, quality: 95);
        await File(savedPath).writeAsBytes(jpg);
        toSavePath = savedPath;
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final fileName = 'shelf_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final savedPath = p.join(dir.path, fileName);
        await File(xfile.path).copy(savedPath);
        toSavePath = savedPath;
      }

      try {
        await MediaStore().saveFile(
          tempFilePath: toSavePath,
          dirType: DirType.photo,
          dirName: DirName.pictures,
          relativePath: "ShelfReader",
        );
      } catch (_) {}

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Fotoğraf kaydedildi 📸')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Hata: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: c == null || !c.value.isInitialized
            ? const Center(child: CircularProgressIndicator())
            : Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: _onScaleUpdate,
                      child: Transform.rotate(
                        angle: (_quarterTurns * 90) * math.pi / 180,
                        child: FittedBox(
                          fit: BoxFit.cover,
                          child: SizedBox(
                            width: c.value.previewSize!.height,
                            height: c.value.previewSize!.width,
                            child: CameraPreview(c),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.arrow_back),
                            color: Colors.white,
                          ),
                          const Spacer(),
                          IconButton(
                            onPressed: _toggleTorch,
                            icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
                            color: Colors.white,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: SafeArea(
                      minimum: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _SmallBtn(icon: Icons.rotate_left,  label: '↺ 90°', onTap: _rotateLeft),
                              const SizedBox(width: 10),
                              _SmallBtn(icon: Icons.refresh,     label: 'Sıfırla', onTap: _reset),
                              const SizedBox(width: 10),
                              _SmallBtn(icon: Icons.rotate_right, label: '↻ 90°', onTap: _rotateRight),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              const Icon(Icons.zoom_out, size: 18, color: Colors.white70),
                              Expanded(
                                child: Slider(
                                  value: _zoom,
                                  min: _minZoom,
                                  max: _maxZoom,
                                  onChanged: (v) async {
                                    _zoom = v;
                                    await _controller?.setZoomLevel(_zoom);
                                    if (mounted) setState(() {});
                                  },
                                ),
                              ),
                              const Icon(Icons.zoom_in, size: 18, color: Colors.white70),
                            ],
                          ),
                          const SizedBox(height: 8),
                          GestureDetector(
                            onTap: _busy ? null : _takeAndSave,
                            child: Container(
                              width: 78,
                              height: 78,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 4),
                              ),
                              child: Center(
                                child: _busy
                                    ? const SizedBox(
                                        width: 28,
                                        height: 28,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 3,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _SmallBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SmallBtn({required this.icon, required this.label, required this.onTap, super.key});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.15),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}
