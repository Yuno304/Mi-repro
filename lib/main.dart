import 'dart:async';
import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProVideoEnhancerApp());
}

class ProVideoEnhancerApp extends StatelessWidget {
  const ProVideoEnhancerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pro Video Enhancer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.cyan,
          brightness: Brightness.dark,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
      ),
      home: const EnhancerPage(),
    );
  }
}

class EnhancerPage extends StatefulWidget {
  const EnhancerPage({super.key});

  @override
  State<EnhancerPage> createState() => _EnhancerPageState();
}

class _EnhancerPageState extends State<EnhancerPage>
    with WidgetsBindingObserver {
  static const List<double> _speeds = <double>[
    0.25,
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
  ];

  final ImagePicker _picker = ImagePicker();
  final ScreenBrightness _screenBrightness = ScreenBrightness();
  final TransformationController _transformationController =
      TransformationController();

  VideoPlayerController? _videoController;
  ChewieController? _chewieController;

  bool _busy = false;
  bool _hdSmoothing = false;
  bool _brightnessAvailable = false;
  bool _writingBrightness = false;
  bool _closing = false;

  double _shadowBoost = 0.0;
  double _contrast = 1.0;
  double _brightness = 0.5;
  double? _queuedBrightness;

  String _sourceName = 'Ningún video seleccionado';
  String? _playbackError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_setWakelock(true));
    unawaited(_readBrightness());
    unawaited(_recoverLostVideo());
  }

  void _notify(String message) {
    if (!mounted || _closing) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message)),
      );
  }

  Future<void> _setWakelock(bool enabled) async {
    try {
      if (enabled) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (error) {
      debugPrint('Wakelock: $error');
    }
  }

  Future<void> _readBrightness() async {
    try {
      final double current = await _screenBrightness.current;

      if (!mounted || _closing) {
        return;
      }

      setState(() {
        _brightness = current.clamp(0.0, 1.0).toDouble();
        _brightnessAvailable = true;
      });
    } catch (error) {
      debugPrint('Lectura de brillo: $error');
      _notify('No se pudo acceder al brillo de la pantalla.');
    }
  }

  void _changeBrightness(double value) {
    setState(() {
      _brightness = value;
    });

    _queuedBrightness = value;
    unawaited(_flushBrightness());
  }

  // Serializa las llamadas nativas y conserva el último valor solicitado.
  Future<void> _flushBrightness() async {
    if (_writingBrightness || _closing) {
      return;
    }

    _writingBrightness = true;

    try {
      while (_queuedBrightness != null && !_closing) {
        final double target = _queuedBrightness!;
        _queuedBrightness = null;

        await _screenBrightness.setScreenBrightness(target);
      }
    } catch (error) {
      _queuedBrightness = null;
      _notify('No se pudo cambiar el brillo: $error');
    } finally {
      _writingBrightness = false;

      if (_closing) {
        await _resetHardwareBrightness();
      }
    }
  }

  Future<void> _resetHardwareBrightness() async {
    try {
      await _screenBrightness.resetScreenBrightness();
    } catch (error) {
      debugPrint('Restablecer brillo: $error');
    }
  }

  Future<void> _recoverLostVideo() async {
    if (!Platform.isAndroid) {
      return;
    }

    setState(() {
      _busy = true;
    });

    try {
      final LostDataResponse response = await _picker.retrieveLostData();

      if (!mounted || _closing) {
        return;
      }

      if (response.isEmpty) {
        return;
      }

      final List<XFile>? files = response.files;

      if (files != null && files.isNotEmpty) {
        final XFile file = files.first;
        await _loadVideo(
          VideoPlayerController.file(File(file.path)),
          file.name,
        );
      } else if (response.exception != null) {
        _notify('No se pudo recuperar el video seleccionado.');
      }
    } catch (error) {
      _notify('Error al recuperar el video: $error');
    } finally {
      if (mounted && !_closing) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _pickLocalVideo() async {
    if (_busy) {
      return;
    }

    setState(() {
      _busy = true;
    });

    try {
      final XFile? file = await _picker.pickVideo(
        source: ImageSource.gallery,
      );

      if (file == null || !mounted || _closing) {
        return;
      }

      await _loadVideo(
        VideoPlayerController.file(File(file.path)),
        file.name,
      );
    } catch (error) {
      _notify('No se pudo abrir la galería: $error');
    } finally {
      if (mounted && !_closing) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _showUrlDialog() async {
    if (_busy) {
      return;
    }

    final GlobalKey<FormState> formKey = GlobalKey<FormState>();
    String input = '';

    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) {
        void submit() {
          if (formKey.currentState?.validate() ?? false) {
            Navigator.of(dialogContext).pop(input.trim());
          }
        }

        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text('Abrir video por URL'),
          content: Form(
            key: formKey,
            child: TextFormField(
              autofocus: true,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Enlace directo HTTPS',
                hintText: 'https://ejemplo.com/video.mp4',
                border: OutlineInputBorder(),
              ),
              onChanged: (String value) {
                input = value;
              },
              onFieldSubmitted: (String value) {
                input = value;
                submit();
              },
              validator: (String? value) {
                final Uri? uri = Uri.tryParse((value ?? '').trim());

                if (uri == null ||
                    uri.scheme != 'https' ||
                    uri.host.isEmpty) {
                  return 'Introduce una URL HTTPS válida.';
                }

                return null;
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: submit,
              child: const Text('Abrir'),
            ),
          ],
        );
      },
    );

    if (result == null || !mounted || _closing) {
      return;
    }

    setState(() {
      _busy = true;
    });

    try {
      final Uri uri = Uri.parse(result);

      await _loadVideo(
        VideoPlayerController.networkUrl(uri),
        uri.host,
      );
    } catch (error) {
      _notify('No se pudo abrir el enlace: $error');
    } finally {
      if (mounted && !_closing) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _disposeVideo(VideoPlayerController controller) async {
    try {
      await controller.dispose();
    } catch (error) {
      debugPrint('Liberar video: $error');
    }
  }

  Future<void> _loadVideo(
    VideoPlayerController candidate,
    String sourceName,
  ) async {
    ChewieController? candidateChewie;

    try {
      await candidate.initialize();

      if (!mounted || _closing) {
        await _disposeVideo(candidate);
        return;
      }

      candidateChewie = ChewieController(
        videoPlayerController: candidate,
        autoInitialize: false,
        autoPlay: false,
        looping: false,
        showControls: false,
        allowFullScreen: false,
        allowedScreenSleep: false,
        playbackSpeeds: _speeds,
        errorBuilder: (
          BuildContext context,
          String errorMessage,
        ) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                errorMessage,
                textAlign: TextAlign.center,
              ),
            ),
          );
        },
      );
    } catch (error) {
      candidateChewie?.dispose();
      await _disposeVideo(candidate);
      _notify('No se pudo cargar el video. Detalle: $error');
      return;
    }

    final VideoPlayerController? previousVideo = _videoController;
    final ChewieController? previousChewie = _chewieController;

    previousVideo?.removeListener(_onVideoChanged);

    setState(() {
      _videoController = candidate;
      _chewieController = candidateChewie;
      _sourceName = sourceName;
      _playbackError = null;
    });

    candidate.addListener(_onVideoChanged);
    _transformationController.value = Matrix4.identity();

    // Espera a retirar el reproductor anterior del árbol antes de liberarlo.
    await WidgetsBinding.instance.endOfFrame;

    previousChewie?.dispose();

    if (previousVideo != null) {
      await _disposeVideo(previousVideo);
    }

    if (mounted && !_closing && identical(_videoController, candidate)) {
      await _runPlaybackAction(() => candidate.play());
    }
  }

  void _onVideoChanged() {
    final VideoPlayerController? controller = _videoController;

    if (controller == null || !mounted || _closing) {
      return;
    }

    final String? error = controller.value.hasError
        ? controller.value.errorDescription ?? 'Error de reproducción.'
        : null;

    if (error != _playbackError) {
      setState(() {
        _playbackError = error;
      });
    }
  }

  Future<void> _runPlaybackAction(
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      _notify('Error de reproducción: $error');
    }
  }

  Future<void> _togglePlayback() async {
    final VideoPlayerController? controller = _videoController;

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    await _runPlaybackAction(() async {
      if (controller.value.isPlaying) {
        await controller.pause();
      } else {
        if (controller.value.position >= controller.value.duration) {
          await controller.seekTo(Duration.zero);
        }

        await controller.play();
      }
    });
  }

  void _resetFiltersAndZoom() {
    setState(() {
      _shadowBoost = 0.0;
      _contrast = 1.0;
      _hdSmoothing = false;
    });

    _transformationController.value = Matrix4.identity();
  }

  void _activateNightVision() {
    setState(() {
      _shadowBoost = 1.0;
      _contrast = 0.85;
    });
  }

  List<double> get _colorMatrix {
    final double offset =
        110.0 * _shadowBoost + 128.0 * (1.0 - _contrast);

    return <double>[
      _contrast, 0.0, 0.0, 0.0, offset,
      0.0, _contrast, 0.0, 0.0, offset,
      0.0, 0.0, _contrast, 0.0, offset,
      0.0, 0.0, 0.0, 1.0, 0.0,
    ];
  }

  String _formatTime(Duration duration) {
    final int totalSeconds = duration.inSeconds;
    final int hours = totalSeconds ~/ 3600;
    final String minutes =
        ((totalSeconds ~/ 60) % 60).toString().padLeft(2, '0');
    final String seconds =
        (totalSeconds % 60).toString().padLeft(2, '0');

    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }

    return '$minutes:$seconds';
  }

  Widget _buildVideo() {
    final VideoPlayerController? video = _videoController;
    final ChewieController? chewie = _chewieController;

    if (video == null || chewie == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.video_library_outlined,
                size: 64.0,
                color: Colors.cyan,
              ),
              SizedBox(height: 16.0),
              Text(
                'Abre un video de la galería o un enlace MP4.',
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 8.0),
              Text(
                'Pellizca para ampliar hasta 8×.',
                style: TextStyle(color: Colors.white60),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final double ratio = video.value.aspectRatio > 0.0
        ? video.value.aspectRatio
        : 16.0 / 9.0;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ClipRect(
          child: InteractiveViewer(
            transformationController: _transformationController,
            minScale: 1.0,
            maxScale: 8.0,
            panEnabled: true,
            scaleEnabled: true,
            child: Center(
              child: AspectRatio(
                aspectRatio: ratio,
                child: ColorFiltered(
                  colorFilter: ColorFilter.matrix(_colorMatrix),
                  child: Transform.scale(
                    scale: 1.0,
                    filterQuality: _hdSmoothing
                        ? FilterQuality.high
                        : FilterQuality.none,
                    child: Chewie(
                      key: ObjectKey(chewie),
                      controller: chewie,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 8.0,
          left: 8.0,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8.0),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10.0,
                  vertical: 6.0,
                ),
                child: ValueListenableBuilder<Matrix4>(
                  valueListenable: _transformationController,
                  builder: (
                    BuildContext context,
                    Matrix4 matrix,
                    Widget? child,
                  ) {
                    return Text(
                      '${matrix.getMaxScaleOnAxis().toStringAsFixed(1)}×',
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        if (_playbackError != null)
          Center(
            child: Container(
              margin: const EdgeInsets.all(20.0),
              padding: const EdgeInsets.all(16.0),
              color: Colors.black87,
              child: Text(
                _playbackError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPlaybackControls() {
    final VideoPlayerController? controller = _videoController;

    if (controller == null) {
      return const SizedBox.shrink();
    }

    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (
        BuildContext context,
        VideoPlayerValue value,
        Widget? child,
      ) {
        final double duration =
            value.duration.inMilliseconds.toDouble();
        final double position = value.position.inMilliseconds
            .toDouble()
            .clamp(0.0, duration)
            .toDouble();

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (value.isBuffering)
              const LinearProgressIndicator(minHeight: 2.0),
            Slider(
              value: position,
              min: 0.0,
              max: duration > 0.0 ? duration : 1.0,
              onChanged: duration > 0.0 && !_busy
                  ? (double milliseconds) {
                      unawaited(
                        _runPlaybackAction(
                          () => controller.seekTo(
                            Duration(
                              milliseconds: milliseconds.round(),
                            ),
                          ),
                        ),
                      );
                    }
                  : null,
            ),
            Row(
              children: <Widget>[
                IconButton(
                  tooltip: value.isPlaying ? 'Pausar' : 'Reproducir',
                  onPressed: _busy ? null : _togglePlayback,
                  icon: Icon(
                    value.isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill,
                    size: 36.0,
                  ),
                ),
                Expanded(
                  child: Text(
                    '${_formatTime(value.position)}'
                    ' / ${_formatTime(value.duration)}',
                    style: const TextStyle(fontSize: 12.0),
                  ),
                ),
                PopupMenuButton<double>(
                  tooltip: 'Velocidad de reproducción',
                  enabled: !_busy,
                  initialValue: value.playbackSpeed,
                  onSelected: (double speed) {
                    unawaited(
                      _runPlaybackAction(
                        () => controller.setPlaybackSpeed(speed),
                      ),
                    );
                  },
                  itemBuilder: (BuildContext context) {
                    return _speeds.map((double speed) {
                      return PopupMenuItem<double>(
                        value: speed,
                        child: Text('${speed}×'),
                      );
                    }).toList();
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Text(
                      '${value.playbackSpeed}×',
                      style: const TextStyle(color: Colors.cyan),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: value.volume == 0.0
                      ? 'Activar sonido'
                      : 'Silenciar',
                  onPressed: _busy
                      ? null
                      : () {
                          unawaited(
                            _runPlaybackAction(
                              () => controller.setVolume(
                                value.volume == 0.0 ? 1.0 : 0.0,
                              ),
                            ),
                          );
                        },
                  icon: Icon(
                    value.volume == 0.0
                        ? Icons.volume_off
                        : Icons.volume_up,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildSlider({
    required IconData icon,
    required String title,
    required String valueLabel,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: 18.0, color: Colors.cyan),
            const SizedBox(width: 8.0),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontSize: 13.0),
              ),
            ),
            Text(
              valueLabel,
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          label: valueLabel,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildPanel() {
    return ColoredBox(
      color: Colors.grey[900]!,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              _sourceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12.0,
              ),
            ),
            _buildPlaybackControls(),
            const SizedBox(height: 12.0),
            Wrap(
              spacing: 10.0,
              runSpacing: 8.0,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: _activateNightVision,
                  icon: const Icon(Icons.nightlight_round),
                  label: const Text('Visión Nocturna'),
                ),
                FilterChip(
                  selected: _hdSmoothing,
                  avatar: const Icon(Icons.hd_outlined),
                  label: const Text('Suavizado HD'),
                  onSelected: (bool selected) {
                    setState(() {
                      _hdSmoothing = selected;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 20.0),
            _buildSlider(
              icon: Icons.brightness_5,
              title: 'Aclarar sombras',
              valueLabel: '${(_shadowBoost * 100.0).round()}%',
              value: _shadowBoost,
              min: 0.0,
              max: 1.0,
              onChanged: (double value) {
                setState(() {
                  _shadowBoost = value;
                });
              },
            ),
            _buildSlider(
              icon: Icons.contrast,
              title: 'Nitidez / Contraste',
              valueLabel: '${_contrast.toStringAsFixed(2)}×',
              value: _contrast,
              min: 0.5,
              max: 2.0,
              onChanged: (double value) {
                setState(() {
                  _contrast = value;
                });
              },
            ),
            _buildSlider(
              icon: Icons.brightness_high,
              title: 'Brillo de pantalla',
              valueLabel: _brightnessAvailable
                  ? '${(_brightness * 100.0).round()}%'
                  : 'No disponible',
              value: _brightness,
              min: 0.0,
              max: 1.0,
              onChanged:
                  _brightnessAvailable ? _changeBrightness : null,
            ),
            const Text(
              'Los ajustes modifican la visualización; '
              'el archivo original permanece intacto.',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11.0,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closing) {
      return;
    }

    if (state == AppLifecycleState.resumed) {
      unawaited(_setWakelock(true));

      if (_brightnessAvailable) {
        _queuedBrightness = _brightness;
        unawaited(_flushBrightness());
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      final VideoPlayerController? controller = _videoController;

      if (controller != null && controller.value.isInitialized) {
        unawaited(_runPlaybackAction(() => controller.pause()));
      }

      unawaited(_setWakelock(false));
    }
  }

  @override
  void dispose() {
    _closing = true;
    WidgetsBinding.instance.removeObserver(this);
    _queuedBrightness = null;

    final VideoPlayerController? video = _videoController;
    video?.removeListener(_onVideoChanged);

    _chewieController?.dispose();

    if (video != null) {
      unawaited(_disposeVideo(video));
    }

    _transformationController.dispose();

    if (!_writingBrightness) {
      unawaited(_resetHardwareBrightness());
    }

    unawaited(_setWakelock(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Pro Video Enhancer',
          style: TextStyle(fontSize: 17.0),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'Abrir galería',
            onPressed: _busy ? null : _pickLocalVideo,
            icon: const Icon(Icons.video_library_outlined),
          ),
          IconButton(
            tooltip: 'Pegar URL MP4',
            onPressed: _busy ? null : _showUrlDialog,
            icon: const Icon(Icons.link),
          ),
          IconButton(
            tooltip: 'Restablecer Filtros y Zoom',
            onPressed: _resetFiltersAndZoom,
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            if (_busy)
              const LinearProgressIndicator(minHeight: 3.0),
            Expanded(
              child: LayoutBuilder(
                builder: (
                  BuildContext context,
                  BoxConstraints constraints,
                ) {
                  final bool sidePanel =
                      constraints.maxWidth > constraints.maxHeight &&
                      constraints.maxWidth >= 600.0;

                  if (sidePanel) {
                    return Row(
                      children: <Widget>[
                        Expanded(child: _buildVideo()),
                        SizedBox(
                          width: 320.0,
                          child: _buildPanel(),
                        ),
                      ],
                    );
                  }

                  return Column(
                    children: <Widget>[
                      Expanded(
                        flex: 5,
                        child: _buildVideo(),
                      ),
                      Expanded(
                        flex: 6,
                        child: _buildPanel(),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}