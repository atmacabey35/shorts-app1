enum VisualMode {
  staticImage,
  procedural3d,
  aiVideo,
}

class Scene {
  const Scene({
    required this.voiceover,
    required this.visualPrompt,
    this.visualMode = VisualMode.staticImage,
    this.subject,
    this.action,
    this.camera = 'medium close-up',
    this.assetId,
    this.animation = const {},
  });

  final String voiceover;
  final String visualPrompt;

  final VisualMode visualMode;
  final String? subject;
  final String? action;
  final String camera;

  final String? assetId;
  final Map<String, dynamic> animation;

  factory Scene.fromJson(Map<String, dynamic> json) {
    return Scene(
      voiceover: '${json['voiceover'] ?? ''}'.trim(),
      visualPrompt: '${json['visual_prompt'] ?? ''}'.trim(),
      visualMode: VisualMode.values.firstWhere(
        (mode) => mode.name == json['visual_mode'],
        orElse: () => VisualMode.staticImage,
      ),
      subject: json['subject']?.toString(),
      action: json['action']?.toString(),
      camera: '${json['camera'] ?? 'medium close-up'}',
      assetId: json['asset_id']?.toString(),
      animation: json['animation'] is Map
          ? Map<String, dynamic>.from(json['animation'])
          : const {},
    );
  }
}
