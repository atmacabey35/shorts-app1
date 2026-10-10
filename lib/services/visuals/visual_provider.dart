import 'dart:io';
import '../../models/scene.dart';

abstract interface class VisualProvider {
  Future<File> generate({
    required Scene scene,
    required int sceneIndex,
    required Directory outputDir,
    required String styleSuffix,
    required void Function(String) log,
  });
}
