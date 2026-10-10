import '../../models/scene.dart';

class VisualPromptBuilder {
  static String build({
    required Scene scene,
    required String styleSuffix,
  }) {
    final subject = scene.subject?.trim();
    final action = scene.action?.trim();

    final parts = <String>[
      if (subject != null && subject.isNotEmpty) subject,
      if (action != null && action.isNotEmpty) action,
      scene.visualPrompt,
      'Camera: ${scene.camera}.',
      'Vertical 9:16 composition.',
      'One clear focal subject, uncluttered background.',
      'No text, no logos, no watermark.',
      'Accurate object geometry and physically plausible arrangement.',
      styleSuffix,
    ];

    return parts
        .where((part) => part.trim().isNotEmpty)
        .join('. ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
