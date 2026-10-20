import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:file_picker/file_picker.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  WakelockPlus.enable();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Pro Video Enhancer',
    home: VideoEnhancerScreen(),
  ));
}

class VideoEnhancerScreen extends StatefulWidget {
  const VideoEnhancerScreen({Key? key}) : super(key: key);

  @override
  State<VideoEnhancerScreen> createState() => _VideoEnhancerScreenState();
}

class _VideoEnhancerScreenState extends State<VideoEnhancerScreen> {
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  final TransformationController _zoomController = TransformationController();

  String _currentUrl = 'https://flutter.github.io/assets-for-api-docs/assets/videos/butterfly.mp4';
  bool _isLoading = true;

  // Controles de mejora de imagen
  double _shadowBoost = 0.0; // Aclara zonas oscuras (0 a 100)
  double _contrast = 1.0;    // Nitidez / Micro-contraste (0.5 a 2.5)
  double _saturation = 1.0;  // Color (0.0 a 2.0)
  double _screenBrightness = 0.5;
  bool _nightVisionActive = false;
  bool _hdSmoothActive = true;

  @override
  void initState() {
    super.initState();
    _initBrightness();
    _loadVideoFromUrl(_currentUrl);
  }

  Future<void> _initBrightness() async {
    try {
      _screenBrightness = await ScreenBrightness().current;
      setState(() {});
    } catch (_) {}
  }

  Future<void> _loadVideoFromUrl(String url) async {
    setState(() => _isLoading = true);
    await _disposeControllers();
    _videoController = VideoPlayerController.networkUrl(Uri.parse(url));
    await _setupChewie();
  }

  Future<void> _pickLocalVideo() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.video);
    if (result != null && result.files.single.path != null) {
      setState(() => _isLoading = true);
      await _disposeControllers();
      _videoController = VideoPlayerController.file(File(result.files.single.path!));
      await _setupChewie();
    }
  }

  Future<void> _setupChewie() async {
    try {
      await _videoController!.initialize();
      _chewieController = ChewieController(
        videoPlayerController: _videoController!,
        autoPlay: true,
        looping: true,
        allowPlaybackSpeedChanging: true,
        playbackSpeeds: const [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0],
      );
    } catch (e) {
      debugPrint("Error cargando video: $e");
    }
    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _disposeControllers() async {
    _chewieController?.dispose();
    await _videoController?.dispose();
  }

  @override
  void dispose() {
    _disposeControllers();
    _zoomController.dispose();
    ScreenBrightness().resetScreenBrightness();
    WakelockPlus.disable();
    super.dispose();
  }

  // Matriz matematica 4x5 para aclarar sombras, mejorar contraste y saturacion en vivo
  List<double> _buildEnhancementMatrix() {
    double c = _contrast;
    double b = _shadowBoost * 1.8; // Offset de iluminacion de sombras
    double t = (1.0 - c) * 128.0 + b;

    double s = _saturation;
    double invS = 1.0 - s;
    double R = 0.2126 * invS;
    double G = 0.7152 * invS;
    double B = 0.0722 * invS;

    return <double>[
      c * (R + s), c * G,       c * B,       0.0, t,
      c * R,       c * (G + s), c * B,       0.0, t,
      c * R,       c * G,       c * (B + s), 0.0, t,
      0.0,         0.0,         0.0,         1.0, 0.0,
    ];
  }

  void _toggleNightVision() {
    setState(() {
      _nightVisionActive = !_nightVisionActive;
      if (_nightVisionActive) {
        _shadowBoost = 65.0; // Ilumina fuertemente las zonas negras
        _contrast = 1.35;    // Define los bordes en la oscuridad
        _saturation = 1.15;
      } else {
        _resetFilters();
      }
    });
  }

  void _resetFilters() {
    setState(() {
      _shadowBoost = 0.0;
      _contrast = 1.0;
      _saturation = 1.0;
      _nightVisionActive = false;
      _zoomController.value = Matrix4.identity();
    });
  }

  void _showUrlDialog() {
    final TextEditingController textCtrl = TextEditingController(text: _currentUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Pegar enlace MP4', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: textCtrl,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: 'https://...', hintStyle: TextStyle(color: Colors.grey)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              _currentUrl = textCtrl.text.trim();
              Navigator.pop(ctx);
              _loadVideoFromUrl(_currentUrl);
            },
            child: const Text('Cargar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        title: const Text('Reproductor Pro', style: TextStyle(fontSize: 16, color: Colors.white)),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open, color: Colors.amber),
            tooltip: 'Abrir video del celular',
            onPressed: _pickLocalVideo,
          ),
          IconButton(
            icon: const Icon(Icons.link, color: Colors.lightBlueAccent),
            tooltip: 'Pegar URL',
            onPressed: _showUrlDialog,
          ),
          IconButton(
            icon: const Icon(Icons.zoom_out_map, color: Colors.white),
            tooltip: 'Quitar Zoom (1x)',
            onPressed: () => setState(() => _zoomController.value = Matrix4.identity()),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.redAccent),
            tooltip: 'Restablecer todo',
            onPressed: _resetFilters,
          ),
        ],
      ),
      body: Column(
        children: [
          // AREA DE VIDEO CON SUPER ZOOM Y FILTRO DE SOMBRAS/NITIDEZ
          Expanded(
            child: Container(
              color: Colors.black,
              child: _isLoading || _chewieController == null
                  ? const Center(child: CircularProgressIndicator(color: Colors.blueAccent))
                  : InteractiveViewer(
                      transformationController: _zoomController,
                      minScale: 1.0,
                      maxScale: 8.0, // Zoom hasta 8x para ver detalles pequeños
                      panEnabled: true,
                      child: ColorFiltered(
                        colorFilter: ColorFilter.matrix(_buildEnhancementMatrix()),
                        child: Transform.scale(
                          scale: 1.0,
                          filterQuality: _hdSmoothActive ? FilterQuality.high : FilterQuality.none,
                          child: Chewie(controller: _chewieController!),
                        ),
                      ),
                    ),
            ),
          ),

          // BOTONES RAPIDOS (Salto de segundos, Vision Nocturna y Suavizado HD)
          Container(
            color: Colors.grey[900],
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _nightVisionActive ? Colors.green[700] : Colors.grey[800],
                    ),
                    icon: const Icon(Icons.nightlight_round, size: 18, color: Colors.white),
                    label: const Text('Visión Nocturna', style: TextStyle(color: Colors.white, fontSize: 12)),
                    onPressed: _toggleNightVision,
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _hdSmoothActive ? Colors.blue[800] : Colors.grey[800],
                    ),
                    icon: const Icon(Icons.hd, size: 18, color: Colors.white),
                    label: const Text('Suavizado Baja Res', style: TextStyle(color: Colors.white, fontSize: 12)),
                    onPressed: () => setState(() => _hdSmoothActive = !_hdSmoothActive),
                  ),
                ],
              ),
            ),
          ),

          // PANEL DE DESLIZADORES (Aclarar Oscuridad, Nitidez y Brillo de Pantalla)
          Container(
            color: const Color(0xFF121212),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Column(
              children: [
                _buildSliderRow(
                  icon: Icons.wb_twilight,
                  label: 'Aclarar Oscuridad',
                  value: _shadowBoost,
                  min: 0.0,
                  max: 100.0,
                  color: Colors.amber,
                  onChanged: (v) => setState(() => _shadowBoost = v),
                ),
                _buildSliderRow(
                  icon: Icons.deblur,
                  label: 'Nitidez / Bordes',
                  value: _contrast,
                  min: 0.5,
                  max: 2.5,
                  color: Colors.cyanAccent,
                  onChanged: (v) => setState(() => _contrast = v),
                ),
                _buildSliderRow(
                  icon: Icons.brightness_6,
                  label: 'Brillo Pantalla',
                  value: _screenBrightness,
                  min: 0.0,
                  max: 1.0,
                  color: Colors.white,
                  onChanged: (v) {
                    setState(() => _screenBrightness = v);
                    ScreenBrightness().setScreenBrightness(v);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSliderRow({
    required IconData icon,
    required String label,
    required double value,
    required double min,
    required double max,
    required Color color,
    required ValueChanged<double> onChanged,
  }) {
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 6),
          SizedBox(
            width: 110,
            child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ),
          Expanded(
            child: Slider(
              value: math.max(min, math.min(max, value)),
              min: min,
              max: max,
              activeColor: color,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
