import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import '../../models/scene.dart';
import 'visual_prompt_builder.dart';
import 'visual_provider.dart';

class FluxVisualProvider implements VisualProvider {
  @override
  Future<File> generate({
    required Scene scene,
    required int sceneIndex,
    required Directory outputDir,
    required String styleSuffix,
    required void Function(String) log,
  }) async {
    final prompt = VisualPromptBuilder.build(
      scene: scene,
      styleSuffix: styleSuffix,
    );

    Object? lastError;

    for (var attempt = 1; attempt <= 4; attempt++) {
      try {
        final large = attempt <= 2;
        final width = large ? 1080 : 720;
        final height = large ? 1920 : 1280;

        final seed = Random.secure().nextInt(1 << 31);
        final uri = Uri.parse(
          'https://image.pollinations.ai/prompt/'
          '${Uri.encodeComponent(prompt)}'
          '?width=$width&height=$height'
          '&model=flux&nologo=true&seed=$seed',
        );

        final response = await http.get(
          uri,
          headers: {'User-Agent': 'ShortsStudio'},
        ).timeout(Duration(seconds: large ? 120 : 90));

        final contentType = response.headers['content-type'] ?? '';

        if (response.statusCode != 200 ||
            !contentType.startsWith('image/') ||
            response.bodyBytes.length < 5000) {
          throw Exception('HTTP ${response.statusCode}, content-type=$contentType');
        }

        final bytes = response.bodyBytes;
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        final image = frame.image;

        final validDimensions = image.width >= 400 && image.height >= 600;
        image.dispose();
        codec.dispose();

        if (!validDimensions) {
          throw Exception('Görsel boyutları yetersiz.');
        }

        var ext = 'jpg';
        if (bytes.length > 2 && bytes[0] == 0x89 && bytes[1] == 0x50) {
          ext = 'png';
        } else if (bytes.length > 12 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[8] == 0x57) {
          ext = 'webp';
        }

        final file = File('${outputDir.path}/scene_$sceneIndex.$ext');
        await file.writeAsBytes(bytes, flush: true);

        log('Sahne ${sceneIndex + 1}: Flux görseli hazır.');
        return file;
      } catch (error) {
        lastError = error;
        log('Sahne ${sceneIndex + 1}: deneme $attempt/4 başarısız: $error');

        if (attempt < 4) {
          await Future.delayed(Duration(seconds: 2 * attempt));
        }
      }
    }

    throw Exception('Sahne ${sceneIndex + 1} için görsel üretilemedi: $lastError');
  }
}
