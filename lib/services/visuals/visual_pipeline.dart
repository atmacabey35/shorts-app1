import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../models/scene.dart';
import 'visual_provider.dart';

class VisualPipeline {
  VisualPipeline(this.provider);

  final VisualProvider provider;

  Future<List<File>> generateAll({
    required List<Scene> scenes,
    required Directory outputDir,
    required String styleSuffix,
    required void Function(String) log,
    required void Function(int done, int total) onProgress,
  }) async {
    final files = <File>[];
    final seenHashes = <String>{};

    for (var i = 0; i < scenes.length; i++) {
      final file = await provider.generate(
        scene: scenes[i],
        sceneIndex: i,
        outputDir: outputDir,
        styleSuffix: styleSuffix,
        log: log,
      );

      final hash = sha256.convert(await file.readAsBytes()).toString();

      if (!seenHashes.add(hash)) {
        log('Sahne ${i + 1}: aynı görsel tekrarlandı.');
        throw Exception(
          'Sahne ${i + 1}: görsel başka bir sahneyle birebir aynı. Yeniden üretim gerekli.',
        );
      }

      files.add(file);
      onProgress(i + 1, scenes.length);
    }

    return files;
  }
}
