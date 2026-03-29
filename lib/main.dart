import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:image/image.dart' as img;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:hive_flutter/hive_flutter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Isolate payload — only plain Dart data, no Flutter objects allowed here
// ─────────────────────────────────────────────────────────────────────────────

class IsolateInput {
  final Uint8List bytes;
  IsolateInput(this.bytes);
}

class IsolateResult {
  final List<int>? hash;
  final double blurScore;
  final double brightness;
  IsolateResult({this.hash, required this.blurScore, required this.brightness});
}

// Top-level function — required by compute()
IsolateResult _analyzeInIsolate(IsolateInput input) {
  final img.Image? decoded = img.decodeImage(input.bytes);
  if (decoded == null) {
    return IsolateResult(hash: null, blurScore: 0, brightness: 0);
  }

  // ── pHash ──
  final img.Image resized = img.copyResize(decoded, width: 8, height: 8);
  final img.Image gray8 = img.grayscale(resized);
  int total = 0;
  for (int y = 0; y < 8; y++) {
    for (int x = 0; x < 8; x++) {
      total += gray8.getPixel(x, y).r.toInt();
    }
  }
  final int avg = total ~/ 64;
  final List<int> hash = [];
  for (int y = 0; y < 8; y++) {
    for (int x = 0; x < 8; x++) {
      hash.add(gray8.getPixel(x, y).r.toInt() >= avg ? 1 : 0);
    }
  }

  // ── Blur (Laplacian variance) ──
  final img.Image grayFull = img.grayscale(decoded);
  final int w = grayFull.width;
  final int h = grayFull.height;
  final List<double> lap = [];
  for (int y = 1; y < h - 1; y++) {
    for (int x = 1; x < w - 1; x++) {
      final int c = grayFull.getPixel(x, y).r.toInt();
      final int t = grayFull.getPixel(x, y - 1).r.toInt();
      final int b = grayFull.getPixel(x, y + 1).r.toInt();
      final int l = grayFull.getPixel(x - 1, y).r.toInt();
      final int r = grayFull.getPixel(x + 1, y).r.toInt();
      lap.add((t + b + l + r - 4 * c).toDouble());
    }
  }
  double blurScore = 0;
  if (lap.isNotEmpty) {
    final double mean = lap.reduce((a, b) => a + b) / lap.length;
    blurScore = lap
            .map((v) => (v - mean) * (v - mean))
            .reduce((a, b) => a + b) /
        lap.length;
  }

  // ── Brightness ──
  int bTotal = 0;
  for (int y = 0; y < grayFull.height; y++) {
    for (int x = 0; x < grayFull.width; x++) {
      bTotal += grayFull.getPixel(x, y).r.toInt();
    }
  }
  final double brightness = bTotal / (grayFull.width * grayFull.height);

  return IsolateResult(hash: hash, blurScore: blurScore, brightness: brightness);
}

// ─────────────────────────────────────────────────────────────────────────────
// Hive cache
// ─────────────────────────────────────────────────────────────────────────────

class ScanCache {
  static const _boxName = 'scan_cache';
  static late Box _box;

  static Future<void> init() async {
    await Hive.initFlutter();
    _box = await Hive.openBox(_boxName);
  }

  static bool has(String id) => _box.containsKey(id);

  static Map<String, dynamic>? get(String id) {
    final v = _box.get(id);
    if (v == null) return null;
    return Map<String, dynamic>.from(v as Map);
  }

  static Future<void> put(
    String id, {
    required List<int>? hash,
    required double blurScore,
    required double brightness,
    required bool isJunk,
    required String junkReason,
  }) async {
    await _box.put(id, {
      'hash': hash,
      'blurScore': blurScore,
      'brightness': brightness,
      'isJunk': isJunk,
      'junkReason': junkReason,
    });
  }

  static Future<void> evict(List<String> ids) async {
    await _box.deleteAll(ids);
  }

  static Future<void> clear() async => _box.clear();

  static int get size => _box.length;
}

// ─────────────────────────────────────────────────────────────────────────────
// Data model
// ─────────────────────────────────────────────────────────────────────────────

class ImageAnalysis {
  final AssetEntity asset;
  final bool isBlurry;
  final bool isDark;
  final bool isJunk;
  final double blurScore;
  final double brightnessScore;
  final String junkReason;

  ImageAnalysis({
    required this.asset,
    required this.isBlurry,
    required this.isDark,
    required this.isJunk,
    required this.blurScore,
    required this.brightnessScore,
    this.junkReason = '',
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// App entry
// ─────────────────────────────────────────────────────────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ScanCache.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Image Cleaner',
      theme: ThemeData.dark(),
      home: const GalleryPage(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Gallery page
// ─────────────────────────────────────────────────────────────────────────────

class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  static const int _batchSize = 50;

  List<AssetEntity> images = [];
  List<List<AssetEntity>> duplicateGroups = [];
  List<ImageAnalysis> badImages = [];
  List<ImageAnalysis> junkImages = [];
  Set<String> selectedIds = {};

  bool loading = true;
  bool scanning = false;
  bool deleting = false;
  bool permissionDenied = false;

  String statusText = '';
  double scanProgress = 0.0;
  int selectedTab = 0;

  int deletedDuplicates = 0;
  int deletedBadQuality = 0;
  int deletedJunk = 0;

  final List<String> junkKeywords = [
    'otp', 'offer', 'expires', 'win', 'prize', 'discount',
    'click here', 'limited time', 'free', 'congratulations',
    'verify', 'coupon', 'cashback', 'reward', 'promo',
    'advertisement', 'sponsored', 'subscribe', 'deal',
    'claim', 'redeem', 'voucher', 'sale', 'off',
  ];

  @override
  void initState() {
    super.initState();
    loadImages();
  }

  // ── Helpers ───────────────────────────────────────────

  bool _isScreenshot(AssetEntity asset) {
    final path = asset.relativePath?.toLowerCase() ?? '';
    if (path.contains('screenshot')) return true;
    final w = asset.width;
    final h = asset.height;
    if (w == 0 || h == 0) return false;
    final ratio = w / h;
    return ratio > 0.4 && ratio < 0.75 && h >= 1500;
  }

  int _hammingDistance(List<int> a, List<int> b) {
    int dist = 0;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) dist++;
    }
    return dist;
  }

  // ── Load images ───────────────────────────────────────

  Future<void> loadImages() async {
    setState(() {
      loading = true;
      permissionDenied = false;
      duplicateGroups = [];
      badImages = [];
      junkImages = [];
      selectedIds = {};
      deletedDuplicates = 0;
      deletedBadQuality = 0;
      deletedJunk = 0;
    });

    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (ps == PermissionState.denied || ps == PermissionState.restricted) {
      setState(() {
        loading = false;
        permissionDenied = true;
      });
      return;
    }

    final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
    );
    if (albums.isEmpty) {
      setState(() => loading = false);
      return;
    }

    final int totalCount = await albums[0].assetCountAsync;
    final List<AssetEntity> allImages =
        await albums[0].getAssetListRange(start: 0, end: totalCount);

    setState(() {
      images = allImages;
      loading = false;
    });
  }

  // ── Full scan ─────────────────────────────────────────

  Future<void> fullScan() async {
    setState(() {
      scanning = true;
      statusText = 'Preparing...';
      scanProgress = 0.0;
      duplicateGroups = [];
      badImages = [];
      junkImages = [];
      selectedIds = {};
    });

    final int total = images.length;
    int processed = 0;

    final List<List<int>?> allHashes = List.filled(total, null);
    final List<ImageAnalysis> tempBad = [];
    final List<ImageAnalysis> tempJunk = [];

    // ── Batched loop ──
    for (int batchStart = 0; batchStart < total; batchStart += _batchSize) {
      final int batchEnd = (batchStart + _batchSize).clamp(0, total);
      final List<AssetEntity> batch = images.sublist(batchStart, batchEnd);

      for (int i = 0; i < batch.length; i++) {
        final int globalIdx = batchStart + i;
        final AssetEntity asset = batch[i];
        processed++;

        setState(() {
          scanProgress = processed / total;
          statusText =
              'Scanning ${(scanProgress * 100).round()}%  ($processed/$total)';
        });

        // ── Cache hit — skip reprocessing ──
        if (ScanCache.has(asset.id)) {
          final cached = ScanCache.get(asset.id)!;
          final List<int>? hash = cached['hash'] != null
              ? List<int>.from(cached['hash'] as List)
              : null;
          allHashes[globalIdx] = hash;

          final double blur = (cached['blurScore'] as num).toDouble();
          final double brightness = (cached['brightness'] as num).toDouble();
          final bool isJunk = cached['isJunk'] as bool;
          final String junkReason = cached['junkReason'] as String;

          if (blur < 80 || brightness < 50) {
            tempBad.add(ImageAnalysis(
              asset: asset,
              isBlurry: blur < 80,
              isDark: brightness < 50,
              isJunk: false,
              blurScore: blur,
              brightnessScore: brightness,
            ));
          }
          if (isJunk) {
            tempJunk.add(ImageAnalysis(
              asset: asset,
              isBlurry: false,
              isDark: false,
              isJunk: true,
              blurScore: 0,
              brightnessScore: 0,
              junkReason: junkReason,
            ));
          }
          continue;
        }

        // ── Cache miss — fetch thumbnail + run isolate ──
        // Some files (corrupt, HEIC, video misclassified as image) cause
        // Glide to throw a RuntimeException instead of returning null.
        // Wrap in try-catch so one bad file doesn't kill the whole scan.
        Uint8List? bytes;
        try {
          bytes = await asset.thumbnailDataWithSize(
            const ThumbnailSize(64, 64),
          ).timeout(const Duration(seconds: 6));
        } on TimeoutException {
          bytes = null;
        } catch (_) {
          bytes = null;
        }

        IsolateResult? result;
        if (bytes != null) {
          result = await compute(_analyzeInIsolate, IsolateInput(bytes));
        }

        final List<int>? hash = result?.hash;
        final double blur = result?.blurScore ?? 0;
        final double brightness = result?.brightness ?? 0;
        allHashes[globalIdx] = hash;

        // ── OCR only on every 3rd screenshot to avoid stalling ──
        bool isJunk = false;
        String junkReason = '';
        if (_isScreenshot(asset) && globalIdx % 3 == 0) {
          final String? keyword = await _detectJunk(asset);
          if (keyword != null) {
            isJunk = true;
            junkReason = keyword;
          }
        }

        // ── Write to cache ──
        await ScanCache.put(
          asset.id,
          hash: hash,
          blurScore: blur,
          brightness: brightness,
          isJunk: isJunk,
          junkReason: junkReason,
        );

        if (blur < 80 || brightness < 50) {
          tempBad.add(ImageAnalysis(
            asset: asset,
            isBlurry: blur < 80,
            isDark: brightness < 50,
            isJunk: false,
            blurScore: blur,
            brightnessScore: brightness,
          ));
        }
        if (isJunk) {
          tempJunk.add(ImageAnalysis(
            asset: asset,
            isBlurry: false,
            isDark: false,
            isJunk: true,
            blurScore: 0,
            brightnessScore: 0,
            junkReason: junkReason,
          ));
        }
      }

      // Yield to UI between batches
      await Future.delayed(Duration.zero);
    }

    // ── Duplicate detection ──
    setState(() => statusText = 'Finding duplicates...');

    final List<bool> visited = List.filled(total, false);
    final List<List<AssetEntity>> groups = [];

    for (int i = 0; i < total; i++) {
      if (visited[i] || allHashes[i] == null) continue;
      final List<AssetEntity> group = [images[i]];
      visited[i] = true;
      for (int j = i + 1; j < total; j++) {
        if (visited[j] || allHashes[j] == null) continue;
        if (_hammingDistance(allHashes[i]!, allHashes[j]!) <= 10) {
          group.add(images[j]);
          visited[j] = true;
        }
      }
      if (group.length > 1) groups.add(group);
    }

    setState(() {
      duplicateGroups = groups;
      badImages = tempBad;
      junkImages = tempJunk;
      scanning = false;
      scanProgress = 0.0;
      statusText = '';
    });
  }

  // ── OCR — with timeouts so a bad image never hangs the scan ──────────────

  Future<String?> _detectJunk(AssetEntity asset) async {
    try {
      // asset.file can itself hang on some Android devices — cap it
      final File? file = await asset.file
          .timeout(const Duration(seconds: 5));
      if (file == null) return null;

      final textRecognizer = TextRecognizer();
      final InputImage inputImage = InputImage.fromFile(file);

      // ML Kit OCR on a corrupt / huge image can hang forever — cap it
      final RecognizedText recognized = await textRecognizer
          .processImage(inputImage)
          .timeout(const Duration(seconds: 8));

      await textRecognizer.close();

      final String text = recognized.text.toLowerCase();
      for (final keyword in junkKeywords) {
        if (text.contains(keyword)) return keyword;
      }
      return null;
    } on TimeoutException {
      // Image took too long — skip it silently and keep scanning
      return null;
    } catch (_) {
      return null;
    }
  }

  // ── Select all ────────────────────────────────────────

  void selectAllInCurrentTab() {
    setState(() {
      switch (selectedTab) {
        case 1:
          for (final group in duplicateGroups) {
            for (int i = 1; i < group.length; i++) {
              selectedIds.add(group[i].id);
            }
          }
          break;
        case 2:
          for (final a in badImages) selectedIds.add(a.asset.id);
          break;
        case 3:
          for (final a in junkImages) selectedIds.add(a.asset.id);
          break;
      }
    });
  }

  void clearSelection() => setState(() => selectedIds = {});

  // ── Delete selected ───────────────────────────────────

  Future<void> deleteSelected() async {
    if (selectedIds.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Images'),
        content: Text(
            'Delete ${selectedIds.length} image(s)? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (confirm != true) return;
    setState(() => deleting = true);

    final List<AssetEntity> toDelete =
        images.where((e) => selectedIds.contains(e.id)).toList();

    await PhotoManager.editor.deleteWithIds(
      toDelete.map((e) => e.id).toList(),
    );

    // Evict deleted images from cache so they don't linger
    await ScanCache.evict(toDelete.map((e) => e.id).toList());

    final int dupDel = toDelete
        .where((e) => duplicateGroups.any((g) => g.any((a) => a.id == e.id)))
        .length;
    final int badDel = toDelete
        .where((e) => badImages.any((a) => a.asset.id == e.id))
        .length;
    final int junkDel = toDelete
        .where((e) => junkImages.any((a) => a.asset.id == e.id))
        .length;

    setState(() {
      images.removeWhere((e) => selectedIds.contains(e.id));
      badImages.removeWhere((a) => selectedIds.contains(a.asset.id));
      junkImages.removeWhere((a) => selectedIds.contains(a.asset.id));
      duplicateGroups = duplicateGroups
          .map((g) => g.where((e) => !selectedIds.contains(e.id)).toList())
          .where((g) => g.length > 1)
          .toList();
      selectedIds = {};
      deleting = false;
      deletedDuplicates += dupDel;
      deletedBadQuality += badDel;
      deletedJunk += junkDel;
    });

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SummaryScreen(
            duplicateCount: deletedDuplicates,
            badQualityCount: deletedBadQuality,
            junkCount: deletedJunk,
            totalDeleted:
                deletedDuplicates + deletedBadQuality + deletedJunk,
            onClose: () {
              Navigator.pop(context);
              loadImages();
            },
          ),
        ),
      );
    }
  }

  // ── UI ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator()));
    }

    if (permissionDenied) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              const Text('Gallery permission denied',
                  style: TextStyle(fontSize: 18)),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () async => await PhotoManager.openSetting(),
                child: const Text('Open Settings'),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: loadImages,
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: selectedIds.isEmpty
            ? Text('Image Cleaner (${images.length})')
            : Text('${selectedIds.length} selected'),
        actions: [
          if (selectedIds.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              onPressed: deleting ? null : deleteSelected,
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: clearSelection,
            ),
          ] else ...[
            if (selectedTab != 0)
              IconButton(
                icon: const Icon(Icons.select_all),
                tooltip: 'Select all',
                onPressed: selectAllInCurrentTab,
              ),
            // Cache clear button
            IconButton(
              icon: const Icon(Icons.cached),
              tooltip: 'Cache: ${ScanCache.size} items',
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Clear Scan Cache'),
                    content: Text(
                        '${ScanCache.size} items cached.\n\nClearing forces a full rescan next time.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Clear',
                              style: TextStyle(color: Colors.red))),
                    ],
                  ),
                );
                if (confirm == true) {
                  await ScanCache.clear();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Cache cleared ✅')),
                    );
                    setState(() {});
                  }
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: loadImages,
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          // ── Scan button ──
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: scanning ? null : fullScan,
                icon: scanning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.auto_fix_high),
                label: Text(scanning ? statusText : 'Scan All Images'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ),

          // ── Progress bar ──
          if (scanning)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: scanProgress,
                      minHeight: 6,
                      backgroundColor: Colors.white12,
                      valueColor: const AlwaysStoppedAnimation(
                          Colors.deepPurple),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${(scanProgress * 100).round()}% complete',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white54),
                      ),
                      Text(
                        '${ScanCache.size} cached',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white38),
                      ),
                    ],
                  ),
                ],
              ),
            ),

          // ── Tab chips ──
          if (!scanning &&
              (duplicateGroups.isNotEmpty ||
                  badImages.isNotEmpty ||
                  junkImages.isNotEmpty))
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  _chip('All', 0, Colors.blue),
                  const SizedBox(width: 8),
                  if (duplicateGroups.isNotEmpty)
                    _chip('${duplicateGroups.length} Duplicates', 1,
                        Colors.orange),
                  const SizedBox(width: 8),
                  if (badImages.isNotEmpty)
                    _chip('${badImages.length} Bad Quality', 2, Colors.red),
                  const SizedBox(width: 8),
                  if (junkImages.isNotEmpty)
                    _chip('${junkImages.length} Junk', 3, Colors.pink),
                ],
              ),
            ),

          const SizedBox(height: 4),
          Expanded(child: _buildTabContent()),
        ],
      ),
      bottomNavigationBar: selectedIds.isNotEmpty
          ? Container(
              color: Colors.red.shade900,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${selectedIds.length} image(s) selected',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: deleting ? null : deleteSelected,
                    icon: const Icon(Icons.delete),
                    label: const Text('Delete'),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red),
                  ),
                ],
              ),
            )
          : null,
    );
  }

  Widget _chip(String label, int tab, Color color) {
    return GestureDetector(
      onTap: () => setState(() => selectedTab = tab),
      child: Chip(
        backgroundColor:
            selectedTab == tab ? color : color.withOpacity(0.3),
        label: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _buildTabContent() {
    switch (selectedTab) {
      case 1: return _buildDuplicatesTab();
      case 2: return _buildBadQualityTab();
      case 3: return _buildJunkTab();
      default: return _buildGalleryGrid();
    }
  }

  Widget _buildGalleryGrid() {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
      ),
      itemCount: images.length,
      itemBuilder: (context, index) {
        final asset = images[index];
        final selected = selectedIds.contains(asset.id);
        return GestureDetector(
          onTap: () => setState(() {
            selected
                ? selectedIds.remove(asset.id)
                : selectedIds.add(asset.id);
          }),
          child: Stack(
            fit: StackFit.expand,
            children: [
              AssetEntityImage(asset, isOriginal: false, fit: BoxFit.cover),
              if (selected)
                Container(
                  color: Colors.blue.withOpacity(0.5),
                  child: const Icon(Icons.check_circle,
                      color: Colors.white, size: 28),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDuplicatesTab() {
    if (duplicateGroups.isEmpty) {
      return const Center(child: Text('No duplicates found ✅'));
    }
    return ListView.builder(
      itemCount: duplicateGroups.length,
      itemBuilder: (context, groupIndex) {
        final group = duplicateGroups[groupIndex];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Text(
                'Group ${groupIndex + 1} — ${group.length} duplicates',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.white70),
              ),
            ),
            SizedBox(
              height: 130,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: group.length,
                itemBuilder: (context, imageIndex) {
                  final asset = group[imageIndex];
                  final selected = selectedIds.contains(asset.id);
                  final isFirst = imageIndex == 0;
                  return GestureDetector(
                    onTap: () {
                      if (isFirst) return;
                      setState(() {
                        selected
                            ? selectedIds.remove(asset.id)
                            : selectedIds.add(asset.id);
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: AssetEntityImage(asset,
                                isOriginal: false,
                                width: 120,
                                height: 120,
                                fit: BoxFit.cover),
                          ),
                          if (isFirst)
                            Positioned(
                              top: 4,
                              left: 4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.green,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text('Keep',
                                    style: TextStyle(
                                        fontSize: 10, color: Colors.white)),
                              ),
                            ),
                          if (selected)
                            Positioned.fill(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.blue.withOpacity(0.5),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.check_circle,
                                    color: Colors.white, size: 28),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBadQualityGrid(List<ImageAnalysis> list) {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
      ),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final analysis = list[index];
        final selected = selectedIds.contains(analysis.asset.id);
        return GestureDetector(
          onTap: () => setState(() {
            selected
                ? selectedIds.remove(analysis.asset.id)
                : selectedIds.add(analysis.asset.id);
          }),
          child: Stack(
            fit: StackFit.expand,
            children: [
              AssetEntityImage(analysis.asset,
                  isOriginal: false, fit: BoxFit.cover),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.all(2),
                  child: Text(
                    analysis.isJunk
                        ? '🗑️ ${analysis.junkReason}'
                        : analysis.isBlurry && analysis.isDark
                            ? '🌫️🌑'
                            : analysis.isBlurry
                                ? '🌫️ Blurry'
                                : '🌑 Dark',
                    style: const TextStyle(fontSize: 10, color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              if (selected)
                Container(
                  color: Colors.blue.withOpacity(0.5),
                  child: const Icon(Icons.check_circle,
                      color: Colors.white, size: 28),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBadQualityTab() {
    if (badImages.isEmpty) {
      return const Center(child: Text('No bad quality images found ✅'));
    }
    return _buildBadQualityGrid(badImages);
  }

  Widget _buildJunkTab() {
    if (junkImages.isEmpty) {
      return const Center(child: Text('No junk images found ✅'));
    }
    return _buildBadQualityGrid(junkImages);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Summary screen
// ─────────────────────────────────────────────────────────────────────────────

class SummaryScreen extends StatelessWidget {
  final int duplicateCount;
  final int badQualityCount;
  final int junkCount;
  final int totalDeleted;
  final VoidCallback onClose;

  const SummaryScreen({
    super.key,
    required this.duplicateCount,
    required this.badQualityCount,
    required this.junkCount,
    required this.totalDeleted,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.check_circle, color: Colors.green, size: 80),
              const SizedBox(height: 24),
              const Text(
                'Clean Complete! 🎉',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 40),
              _statCard('🗂️ Duplicates Removed', duplicateCount, Colors.orange),
              const SizedBox(height: 12),
              _statCard('🌫️ Bad Quality Removed', badQualityCount, Colors.red),
              const SizedBox(height: 12),
              _statCard('🗑️ Junk Removed', junkCount, Colors.pink),
              const Divider(height: 40, color: Colors.white24),
              _statCard('✅ Total Deleted', totalDeleted, Colors.green),
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: onClose,
                  icon: const Icon(Icons.home),
                  label: const Text('Back to Gallery'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statCard(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 15)),
          Text(
            '$count',
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }
}