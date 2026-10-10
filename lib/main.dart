// Shorts Studio - tamamen cihaz Ã¼stÃ¼nde, Ã¼cretsiz, otonom Shorts/Reels Ã¼retici.
//
// AkÄ±ÅŸ: Senaryo (konu -> Pollinations metin | yapÄ±ÅŸtÄ±rÄ±lan Gemini JSON)
//       -> GÃ¶rseller (Pollinations Flux, 1080x1920)
//       -> Seslendirme (Edge-TTS, olmazsa Android yerel TTS)
//       -> Tek geÃ§iÅŸte FFmpeg: Ken Burns + altyazÄ± (ASS hardsub) + sentez mÃ¼zik + ducking
//       -> Galeriye kaydet + oynat + paylaÅŸ.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ============================ SABÄ°TLER ============================
const int kFps = 30;
const double kSceneGap = 0.30; // sahneler arasÄ± sessizlik (sn)
const double kEndTail = 0.60; // video sonu payÄ± (sn)
const String kEdgeVoice = 'Microsoft Server Speech Text to Speech Voice (tr-TR, AhmetNeural)';
const String kSubtitleFont = 'Roboto'; // Android sistem fontu, TÃ¼rkÃ§e karakter destekler

enum VideoStyle {
  cinematic(
    '3D Sinematik',
    '3D render, Unreal Engine 5, cinematic lighting, volumetric fog, photorealistic, 8k, ultra detailed, vertical 9:16 composition',
    'eq=contrast=1.06:saturation=1.12',
  ),
  tense(
    'Gerilim',
    'dark mysterious atmosphere, 3D render, moody low-key lighting, deep shadows, mist, desaturated, photorealistic, 8k, vertical 9:16 composition',
    'eq=contrast=1.12:saturation=0.75:brightness=-0.03,vignette=PI/5',
  ),
  cartoon(
    'KarikatÃ¼r',
    'stylized 3D cartoon animation style, vibrant colors, soft lighting, expressive, high detail, vertical 9:16 composition',
    'eq=contrast=1.05:saturation=1.35',
  );

  const VideoStyle(this.label, this.suffix, this.grade);
  final String label;
  final String suffix; // gÃ¶rsel istemine eklenir
  final String grade; // FFmpeg renk dÃ¼zenleme filtresi
}

// ============================ MODELLER ============================
class Scene {
  Scene(this.voiceover, this.visualPrompt);
  final String voiceover;
  final String visualPrompt;
}

class Scenario {
  Scenario(this.title, this.scenes);
  final String title;
  final List<Scene> scenes;
}

class WordTiming {
  WordTiming(this.text, this.start, this.end);
  final String text;
  final double start; // saniye
  final double end;
}

class SceneAudio {
  SceneAudio(this.file, this.speechSec, this.words);
  final File file; // 44.1 kHz stereo wav, sonunda kSceneGap sessizlik
  final double speechSec;
  final List<WordTiming> words; // sahne baÅŸlangÄ±cÄ±na gÃ¶re
  double get totalSec => speechSec + kSceneGap;
}

// ============================ YARDIMCILAR ============================
const String _scriptPromptTemplate =
    '''Sen viral YouTube Shorts senaristisisin. Konu: "{TOPIC}"

45-60 saniyelik, gizem ve merak uyandÄ±ran dikey video senaryosu yaz.
Kurallar:
- Toplam 130-160 kelime olsun.
- Ä°lk cÃ¼mle (ilk 3 saniye) Ã§ok gÃ¼Ã§lÃ¼ bir kanca (hook) olsun.
- YalnÄ±zca doÄŸrulanabilir bilgiler kullan; emin olmadÄ±ÄŸÄ±n ÅŸeyi uydurma.
- Son cÃ¼mle merak bÄ±rakan bir kapanÄ±ÅŸ olsun.
- 4 ile 6 arasÄ± sahne Ã¼ret.
- "voiceover": SADECE seslendirilecek duru TÃ¼rkÃ§e metin (emoji, parantez, sahne notu YOK).
- "visual_prompt": Ä°ngilizce; sahneyi anlatan somut gÃ¶rsel istemi (nesne, mekÃ¢n, Ä±ÅŸÄ±k, atmosfer). YazÄ±/logo ve yakÄ±n Ã§ekim insan yÃ¼zÃ¼ iÃ§ermesin.

YALNIZCA ÅŸu JSON'u dÃ¶ndÃ¼r:
{"title": "kÄ±sa baÅŸlÄ±k", "scenes": [{"voiceover": "...", "visual_prompt": "..."}]}''';

String scriptPrompt(String topic) => _scriptPromptTemplate.replaceAll('{TOPIC}', topic);

String trUpper(String s) => s.replaceAll('i', 'Ä°').replaceAll('Ä±', 'I').toUpperCase();

String _hex(int n) {
  final r = Random.secure();
  return List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
}

/// Bir FFmpeg komutunu Ã§alÄ±ÅŸtÄ±rÄ±r; hata olursa gÃ¼nlÃ¼ÄŸÃ¼n sonunu istisna olarak fÄ±rlatÄ±r.
Future<void> runFfmpeg(List<String> args, {void Function(double seconds)? onTime}) async {
  final done = Completer<void>();
  await FFmpegKit.executeWithArgumentsAsync(
    args,
    (session) async {
      final rc = await session.getReturnCode();
      if (ReturnCode.isSuccess(rc)) {
        if (!done.isCompleted) done.complete();
      } else {
        String logs = '';
        try {
          logs = (await session.getAllLogsAsString()) ?? '';
        } catch (_) {}
        final tail = logs.length > 1500 ? logs.substring(logs.length - 1500) : logs;
        if (!done.isCompleted) done.completeError(Exception('FFmpeg hatasÄ± (kod: $rc)\n$tail'));
      }
    },
    null,
    onTime == null
        ? null
        : (stat) {
            final ms = stat.getTime();
            if (ms > 0) onTime(ms / 1000.0);
          },
  );
  await done.future;
}

Future<double> probeDuration(String path) async {
  final session = await FFprobeKit.getMediaInformation(path);
  final info = await session.getMediaInformation();
  final d = double.tryParse((await info?.getDuration()) ?? '');
  if (d == null || d <= 0) throw Exception('Ses sÃ¼resi okunamadÄ±: $path');
  return d;
}

// ============================ 1) SENARYO ============================
class ScenarioService {
  static bool looksLikeJson(String s) => s.contains('{') && s.contains('"scenes"');

  static Scenario parse(String raw) {
    var text = raw.trim();
    final open = text.indexOf(RegExp(r'[\{\[]'));
    final close = max(text.lastIndexOf('}'), text.lastIndexOf(']'));
    if (open < 0 || close <= open) throw const FormatException('JSON bulunamadÄ±.');
    text = text.substring(open, close + 1);

    final dynamic data = jsonDecode(text);
    final dynamic rawScenes = data is List ? data : (data is Map ? data['scenes'] : null);
    if (rawScenes is! List || rawScenes.isEmpty) {
      throw const FormatException('JSON iÃ§inde dolu bir "scenes" listesi yok.');
    }
    final scenes = <Scene>[];
    for (var i = 0; i < rawScenes.length && i < 6; i++) {
      final s = rawScenes[i];
      if (s is! Map) throw FormatException('Sahne ${i + 1} geÃ§ersiz.');
      final vo = _cleanVoice('${s['voiceover'] ?? ''}');
      final vp = '${s['visual_prompt'] ?? ''}'.trim();
      if (vo.isEmpty || vp.isEmpty) {
        throw FormatException('Sahne ${i + 1}: "voiceover" ve "visual_prompt" dolu olmalÄ±.');
      }
      scenes.add(Scene(vo, vp));
    }
    final title = data is Map ? '${data['title'] ?? 'Shorts'}' : 'Shorts';
    return Scenario(title, scenes);
  }

  static String _cleanVoice(String t) {
    t = t.replaceAll(RegExp(r'[\*#_\[\]\(\)\{\}<>]'), '');
    t = t.replaceAll(RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true), '');
    return t.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Konu girildiyse Ã¼cretsiz Pollinations metin API'siyle senaryo Ã¼retir.
  static Future<Scenario> fromTopic(String topic) async {
    Object? last;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final r = await http
            .post(
              Uri.parse('https://text.pollinations.ai/openai'),
              headers: {'Content-Type': 'application/json', 'User-Agent': 'ShortsStudio'},
              body: jsonEncode({
                'model': 'openai',
                'seed': Random().nextInt(999999),
                'messages': [
                  {'role': 'user', 'content': scriptPrompt(topic)},
                ],
              }),
            )
            .timeout(const Duration(seconds: 90));
        if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
        final body = utf8.decode(r.bodyBytes);
        String content = body;
        try {
          final j = jsonDecode(body);
          content = j['choices'][0]['message']['content'] as String;
        } catch (_) {}
        return parse(content);
      } catch (e) {
        last = e;
        await Future.delayed(Duration(seconds: 3 * attempt));
      }
    }
    throw Exception(
      'Senaryo otomatik Ã¼retilemedi ($last).\n'
      '"Gemini istemini kopyala" ile istemi Gemini Web\'e verip dÃ¶nen JSON\'u buraya yapÄ±ÅŸtÄ±rÄ±n.',
    );
  }
}

// ============================ 2) GÃ–RSELLER ============================
class ImageService {
  static Future<File> fetch(Scene scene, int i, Directory dir, String styleSuffix) async {
    var prompt = '${scene.visualPrompt}, $styleSuffix';
    if (prompt.length > 700) prompt = prompt.substring(0, 700);
    final file = File('${dir.path}/img_$i.jpg');

    for (var attempt = 1; attempt <= 4; attempt++) {
      try {
        final seed = Random().nextInt(999999);
        final url = Uri.parse(
          'https://image.pollinations.ai/prompt/${Uri.encodeComponent(prompt)}'
          '?width=1080&height=1920&model=flux&nologo=true&seed=$seed',
        );
        final r = await http
            .get(url, headers: {'User-Agent': 'Mozilla/5.0 ShortsStudio'})
            .timeout(const Duration(seconds: 180));
        final ct = r.headers['content-type'] ?? '';
        if (r.statusCode == 200 && ct.startsWith('image') && r.bodyBytes.length > 5000) {
          final codec = await ui.instantiateImageCodec(r.bodyBytes); // bozuk gÃ¶rsel ise fÄ±rlatÄ±r
          codec.dispose();
          // UzantÄ±yÄ± gerÃ§ek iÃ§eriÄŸe gÃ¶re seÃ§ (PNG/WEBP gelirse FFmpeg ÅŸaÅŸÄ±rmasÄ±n)
          final b = r.bodyBytes;
          var ext = 'jpg';
          if (b[0] == 0x89 && b[1] == 0x50) {
            ext = 'png';
          } else if (b[0] == 0x52 && b[1] == 0x49 && b[8] == 0x57) {
            ext = 'webp';
          }
          final out = File('${dir.path}/img_$i.$ext');
          await out.writeAsBytes(b);
          return out;
        }
      } catch (_) {}
      await Future.delayed(Duration(seconds: 4 * attempt));
    }
    // Yedek: FFmpeg ile koyu dÃ¼z arka plan (akÄ±ÅŸ asla Ã§Ã¶kmesin)
    const colors = ['0x0b0b1f', '0x1f0b0b', '0x0b1a1f'];
    await runFfmpeg([
      '-y', '-f', 'lavfi', '-i', 'color=c=${colors[i % 3]}:s=1080x1920:d=1',
      '-frames:v', '1', '-pix_fmt', 'yuvj420p', '-q:v', '2', file.path,
    ]);
    return file;
  }
}

// ============================ 3) SESLENDÄ°RME ============================
class EdgeResult {
  EdgeResult(this.audio, this.words);
  final Uint8List audio;
  final List<WordTiming> words;
}

/// Microsoft Edge "Read Aloud" WebSocket protokolÃ¼.
/// NOT: Microsoft Sec-MS-GEC-Version sabitini zaman zaman deÄŸiÅŸtirir; birkaÃ§ sÃ¼rÃ¼m denenir,
/// hepsi baÅŸarÄ±sÄ±z olursa uygulama otomatik olarak Android yerel TTS'e geÃ§er.
class EdgeTts {
  static const _token = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const _versions = ['142.0.3595.94', '134.0.3124.66', '130.0.2849.68'];

  static String _gec() {
    var ticks = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + 11644473600;
    ticks -= ticks % 300;
    ticks *= 10000000;
    return sha256.convert(ascii.encode('$ticks$_token')).toString().toUpperCase();
  }

  static String _jsTime() {
    const d = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final t = DateTime.now().toUtc();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d[t.weekday - 1]} ${m[t.month - 1]} ${p(t.day)} ${t.year} '
        '${p(t.hour)}:${p(t.minute)}:${p(t.second)} GMT+0000 (Coordinated Universal Time)';
  }

  static Future<EdgeResult> synth(String text, {String rate = '+0%'}) async {
    Object? last;
    for (final ver in _versions) {
      try {
        return await _once(text, rate, ver);
      } catch (e) {
        last = e;
      }
    }
    throw Exception('Edge-TTS baÅŸarÄ±sÄ±z: $last');
  }

  static Future<EdgeResult> _once(String text, String rate, String ver) async {
    final major = ver.split('.').first;
    final url = 'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1'
        '?TrustedClientToken=$_token&Sec-MS-GEC=${_gec()}&Sec-MS-GEC-Version=1-$ver'
        '&ConnectionId=${_hex(32)}';
    final ws = await WebSocket.connect(url, headers: {
      'Pragma': 'no-cache',
      'Cache-Control': 'no-cache',
      'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/$major.0.0.0 Safari/537.36 Edg/$major.0.0.0',
      'Accept-Language': 'en-US,en;q=0.9',
      'Cookie': 'muid=${_hex(32).toUpperCase()};',
    }).timeout(const Duration(seconds: 20));

    final audio = BytesBuilder();
    final words = <WordTiming>[];
    final done = Completer<void>();

    ws.listen(
      (dynamic data) {
        if (data is String) {
          if (data.contains('Path:turn.end')) {
            if (!done.isCompleted) done.complete();
          } else if (data.contains('Path:audio.metadata')) {
            try {
              final body = data.substring(data.indexOf('\r\n\r\n') + 4);
              final j = jsonDecode(body);
              for (final m in (j['Metadata'] as List)) {
                if (m['Type'] == 'WordBoundary') {
                  final dd = m['Data'];
                  final off = (dd['Offset'] as num) / 1e7;
                  final dur = (dd['Duration'] as num) / 1e7;
                  words.add(WordTiming('${dd['text']['Text']}', off.toDouble(), (off + dur).toDouble()));
                }
              }
            } catch (_) {}
          }
        } else if (data is List<int>) {
          final b = Uint8List.fromList(data);
          if (b.length < 2) return;
          final hl = (b[0] << 8) | b[1];
          if (b.length < 2 + hl) return;
          final header = utf8.decode(b.sublist(2, 2 + hl), allowMalformed: true);
          if (header.contains('Path:audio')) audio.add(b.sublist(2 + hl));
        }
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.completeError(StateError('BaÄŸlantÄ± erken kapandÄ±'));
      },
    );

    final ts = _jsTime();
    ws.add(
      'X-Timestamp:$ts\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n'
      '{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false",'
      '"wordBoundaryEnabled":"true"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n',
    );
    final esc = text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
    final ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='tr-TR'>"
        "<voice name='$kEdgeVoice'><prosody pitch='+0Hz' rate='$rate' volume='+0%'>$esc</prosody></voice></speak>";
    ws.add(
      'X-RequestId:${_hex(32)}\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:${ts}Z\r\nPath:ssml\r\n\r\n$ssml',
    );

    try {
      await done.future.timeout(const Duration(seconds: 60));
    } finally {
      await ws.close();
    }
    final bytes = audio.toBytes();
    if (bytes.length < 1000) throw Exception('BoÅŸ ses dÃ¶ndÃ¼');
    return EdgeResult(bytes, words);
  }
}

class AndroidTts {
  static Future<File> synth(String text, String path) async {
    final tts = FlutterTts();
    final ok = await tts.isLanguageAvailable('tr-TR');
    if (ok != true) {
      throw Exception(
        'Telefonda TÃ¼rkÃ§e TTS sesi yok. Ayarlar > Genel yÃ¶netim > Metin okuma bÃ¶lÃ¼mÃ¼nden TÃ¼rkÃ§e ses verisini indirin.',
      );
    }
    await tts.setLanguage('tr-TR');
    await tts.setSpeechRate(0.5);
    await tts.awaitSynthCompletion(true);
    await tts.synthesizeToFile(text, path, true);
    final f = File(path);
    if (!await f.exists() || await f.length() < 1000) throw Exception('Android TTS dosya Ã¼retemedi.');
    return f;
  }
}

class TtsService {
  static Future<SceneAudio> synth(String text, int i, Directory dir, void Function(String) log) async {
    File? src;
    var words = <WordTiming>[];
    try {
      final r = await EdgeTts.synth(text);
      src = File('${dir.path}/vo_$i.mp3');
      await src.writeAsBytes(r.audio);
      words = r.words;
      log('Sahne ${i + 1}: Edge-TTS (AhmetNeural)');
    } catch (e) {
      log('Sahne ${i + 1}: Edge-TTS olmadÄ±, Android TTS kullanÄ±lÄ±yor.');
    }
    src ??= await AndroidTts.synth(text, '${dir.path}/vo_$i.wav');

    final speech = await probeDuration(src.path);
    final out = File('${dir.path}/vo_${i}_pad.wav');
    await runFfmpeg([
      '-y', '-i', src.path, '-ar', '44100', '-ac', '2', '-af', 'apad=pad_dur=$kSceneGap', out.path,
    ]);
    if (words.isEmpty) words = _estimateWords(text, speech);
    return SceneAudio(out, speech, words);
  }

  /// Kelime zamanÄ± gelmediyse: karakter sayÄ±sÄ±yla orantÄ±lÄ± tahmin.
  static List<WordTiming> _estimateWords(String text, double speech) {
    final toks = text.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    double weight(String t) {
      var w = t.length + 1.0;
      if (RegExp(r'[.!?]$').hasMatch(t)) {
        w += 4;
      } else if (RegExp(r'[,;:]$').hasMatch(t)) {
        w += 2;
      }
      return w;
    }

    final total = toks.fold<double>(0, (a, t) => a + weight(t));
    var cur = 0.0;
    final out = <WordTiming>[];
    for (final t in toks) {
      final d = speech * weight(t) / total;
      out.add(WordTiming(t, cur, cur + d));
      cur += d;
    }
    return out;
  }

  static Future<File> concatVoice(List<SceneAudio> parts, Directory dir) async {
    final list = File('${dir.path}/voice_list.txt');
    await list.writeAsString(parts.map((p) => "file '${p.file.path}'\n").join());
    final out = File('${dir.path}/voice.wav');
    await runFfmpeg(['-y', '-f', 'concat', '-safe', '0', '-i', list.path, '-c', 'copy', out.path]);
    return out;
  }
}

// ============================ 4) ALTYAZI (ASS) ============================
class SubtitleBuilder {
  static String _t(double t) {
    final cs = (max(t, 0) * 100).round();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${cs ~/ 360000}:${p(cs % 360000 ~/ 6000)}:${p(cs % 6000 ~/ 100)}.${p(cs % 100)}';
  }

  static Future<File> build(List<WordTiming> words, Directory dir) async {
    final head = '''[Script Info]
ScriptType: v4.00+
PlayResX: 1080
PlayResY: 1920
WrapStyle: 2
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Main,$kSubtitleFont,96,&H00FFFFFF,&H00FFFFFF,&H00000000,&H64000000,-1,0,0,0,100,100,0,0,1,8,2,2,60,60,520,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''';
    final strip = RegExp(r'''^[.,;:"'Â«Â»â€¦\-â€“â€”()]+|[.,;:"'Â«Â»â€¦\-â€“â€”()]+$''');
    final clean = words.map((w) {
      final c = trUpper(w.text.replaceAll(strip, ''));
      return WordTiming(c.isEmpty ? w.text : c, w.start, w.end);
    }).toList();

    // 3'lÃ¼ gruplar; noktalama veya uzun duraklamada bÃ¶l
    final groups = <List<int>>[];
    var cur = <int>[];
    for (var i = 0; i < clean.length; i++) {
      cur.add(i);
      final raw = words[i].text;
      final gap = i + 1 < clean.length ? clean[i + 1].start - clean[i].end : 0.0;
      if (cur.length >= 3 || RegExp(r'[.?!,]$').hasMatch(raw) || gap > 0.5) {
        groups.add(cur);
        cur = <int>[];
      }
    }
    if (cur.isNotEmpty) groups.add(cur);

    final lines = StringBuffer();
    for (final g in groups) {
      for (var pos = 0; pos < g.length; pos++) {
        final wi = g[pos];
        final start = clean[wi].start;
        var end = pos + 1 < g.length ? clean[g[pos + 1]].start : clean[wi].end + 0.12;
        if (end <= start) end = start + 0.1;
        final text = g.map((j) => j == wi ? '{\\1c&H00FFFF&}${clean[j].text}{\\1c&HFFFFFF&}' : clean[j].text).join(' ');
        lines.writeln('Dialogue: 0,${_t(start)},${_t(end)},Main,,0,0,0,,$text');
      }
    }
    final f = File('${dir.path}/subs.ass');
    await f.writeAsString(head + lines.toString());
    return f;
  }
}

// ============================ 5) FFMPEG RENDER ============================
class Renderer {
  static const _motions = ['zoom_in', 'pan_down', 'zoom_out', 'pan_right', 'pan_up', 'zoom_in'];

  static String _zoompan(String kind, int n) {
    const cx = 'iw/2-(iw/zoom/2)';
    const cy = 'ih/2-(ih/zoom/2)';
    switch (kind) {
      case 'zoom_in': // merkeze yaklaÅŸma
        return "z='1+0.30*on/$n':x='$cx':y='$cy'";
      case 'zoom_out':
        return "z='1.30-0.30*on/$n':x='$cx':y='$cy'";
      case 'pan_down': // yukarÄ±dan aÅŸaÄŸÄ±ya kayma
        return "z='1.25':x='$cx':y='(ih-ih/zoom)*on/$n'";
      case 'pan_up':
        return "z='1.25':x='$cx':y='(ih-ih/zoom)*(1-on/$n)'";
      default: // pan_right
        return "z='1.25':x='(iw-iw/zoom)*on/$n':y='$cy'";
    }
  }

  static Future<void> render({
    required List<File> images,
    required List<double> durations,
    required File voice,
    required File ass,
    required String grade,
    required String outPath,
    required void Function(double fraction) onProgress,
  }) async {
    final n = images.length;
    final total = durations.fold<double>(0, (a, b) => a + b);

    try {
      await FFmpegKitConfig.setFontDirectoryList(['/system/fonts'], {});
    } catch (_) {}

    final args = <String>['-y'];
    for (final img in images) {
      args.addAll(['-i', img.path]); // 0..n-1
    }
    args.addAll(['-i', voice.path]); // n
    final d = (total + 2).toStringAsFixed(2);
    for (final f in ['55', '82.41', '110.5']) {
      args.addAll(['-f', 'lavfi', '-i', 'sine=frequency=$f:sample_rate=44100:duration=$d']); // n+1..n+3
    }
    args.addAll(['-f', 'lavfi', '-i', 'anoisesrc=color=brown:amplitude=0.25:sample_rate=44100:duration=$d']); // n+4

    final fc = StringBuffer();
    // --- Video: her sahne iÃ§in Ken Burns, sonra birleÅŸtir + renk + altyazÄ±
    for (var i = 0; i < n; i++) {
      final frames = max(2, (durations[i] * kFps).round());
      fc.write('[$i:v]scale=1620:2880:force_original_aspect_ratio=increase,crop=1620:2880,setsar=1,'
          'zoompan=${_zoompan(_motions[i % _motions.length], frames)}:d=$frames:s=1080x1920:fps=$kFps,'
          'fade=t=in:st=0:d=0.15,format=yuv420p[v$i];');
    }
    for (var i = 0; i < n; i++) {
      fc.write('[v$i]');
    }
    fc.write('concat=n=$n:v=1:a=0,$grade,ass=filename=${ass.path}:fontsdir=/system/fonts[vout];');

    // --- Ses: sentez gerilim mÃ¼ziÄŸi + audio ducking (konuÅŸmada â‰ˆ %15)
    final a = n + 1;
    fc.write('[$n:a]aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo,apad,asplit=2[vsc][vmix];');
    fc.write('[$a:a]volume=0.55[a0];');
    fc.write('[${a + 1}:a]volume=0.30,tremolo=f=0.15:d=0.6[a1];');
    fc.write('[${a + 2}:a]volume=0.18,tremolo=f=0.31:d=0.8[a2];');
    fc.write('[${a + 3}:a]lowpass=f=350,volume=0.7[a3];');
    fc.write('[a0][a1][a2][a3]amix=inputs=4:duration=longest,volume=3,lowpass=f=1400,'
        'aecho=0.8:0.7:600|1100:0.4|0.25,afade=t=in:d=2,'
        'afade=t=out:st=${max(total - 1, 1).toStringAsFixed(2)}:d=3,'
        'aformat=sample_fmts=fltp:channel_layouts=stereo,volume=0.55[m];');
    fc.write('[m][vsc]sidechaincompress=threshold=0.02:ratio=12:attack=15:release=500[duck];');
    fc.write('[vmix][duck]amix=inputs=2:duration=first:dropout_transition=0,volume=2,alimiter=limit=0.95[aout]');

    args.addAll([
      '-filter_complex', fc.toString(),
      '-map', '[vout]', '-map', '[aout]',
      '-t', total.toStringAsFixed(2),
      '-r', '$kFps',
      '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '21', '-pix_fmt', 'yuv420p',
      '-c:a', 'aac', '-b:a', '192k', '-ar', '44100',
      '-movflags', '+faststart',
      outPath,
    ]);

    await runFfmpeg(args, onTime: (sec) => onProgress((sec / total).clamp(0.0, 1.0)));
  }
}

// ============================ 6) ANA AKIÅ ============================
class Pipeline {
  Pipeline({required this.onStage, required this.onLog});
  final void Function(int step, String label, double progress) onStage;
  final void Function(String message) onLog;

  Future<String> run({required String input, required VideoStyle style}) async {
    await WakelockPlus.enable();
    try {
      final tmp = await getTemporaryDirectory();
      final dir = Directory('${tmp.path}/shorts_work');
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);

      // --- [1/4] Senaryo + gÃ¶rseller
      onStage(1, '[1/4] GÃ¶rseller indiriliyor...', 0.01);
      final Scenario scenario;
      if (ScenarioService.looksLikeJson(input)) {
        onLog('YapÄ±ÅŸtÄ±rÄ±lan JSON ayrÄ±ÅŸtÄ±rÄ±lÄ±yor...');
        scenario = ScenarioService.parse(input);
      } else {
        onLog('Konu iÃ§in senaryo yazÄ±lÄ±yor (Pollinations)...');
        scenario = await ScenarioService.fromTopic(input);
      }
      onLog('BaÅŸlÄ±k: ${scenario.title} â€¢ ${scenario.scenes.length} sahne');
      final n = scenario.scenes.length;

      final images = <File>[];
      for (var i = 0; i < n; i++) {
        onLog('GÃ¶rsel ${i + 1}/$n indiriliyor...');
        images.add(await ImageService.fetch(scenario.scenes[i], i, dir, style.suffix));
        onStage(1, '[1/4] GÃ¶rseller indiriliyor... (${i + 1}/$n)', 0.05 + 0.30 * (i + 1) / n);
        if (i < n - 1) await Future.delayed(const Duration(seconds: 2)); // sunucuya nazik ol
      }

      // --- [2/4] Seslendirme
      onStage(2, '[2/4] Seslendiriliyor...', 0.35);
      final audios = <SceneAudio>[];
      for (var i = 0; i < n; i++) {
        audios.add(await TtsService.synth(scenario.scenes[i].voiceover, i, dir, onLog));
        onStage(2, '[2/4] Seslendiriliyor... (${i + 1}/$n)', 0.35 + 0.15 * (i + 1) / n);
      }
      final voice = await TtsService.concatVoice(audios, dir);

      final durations = audios.map((a) => a.totalSec).toList();
      durations[n - 1] += kEndTail;
      final allWords = <WordTiming>[];
      var offset = 0.0;
      for (var i = 0; i < n; i++) {
        for (final w in audios[i].words) {
          allWords.add(WordTiming(w.text, w.start + offset, w.end + offset));
        }
        offset += audios[i].totalSec;
      }
      final total = durations.fold<double>(0, (a, b) => a + b);
      onLog('Toplam sÃ¼re: ${total.toStringAsFixed(1)} sn');
      final ass = await SubtitleBuilder.build(allWords, dir);

      // --- [3/4] Render
      onStage(3, '[3/4] FFmpeg ile render alÄ±nÄ±yor...', 0.52);
      final outPath = '${dir.path}/final_shorts.mp4';
      await Renderer.render(
        images: images,
        durations: durations,
        voice: voice,
        ass: ass,
        grade: style.grade,
        outPath: outPath,
        onProgress: (f) => onStage(3, '[3/4] FFmpeg ile render alÄ±nÄ±yor... %${(f * 100).round()}', 0.52 + 0.43 * f),
      );

      // --- [4/4] Galeriye kaydet
      if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
      await Gal.putVideo(outPath, album: 'Shorts Studio');
      onStage(4, '[4/4] Galeriye kaydedildi! (Galeri > Shorts Studio)', 1.0);
      return outPath;
    } finally {
      await WakelockPlus.disable();
    }
  }
}

// ============================ ARAYÃœZ ============================
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ShortsApp());
}

class ShortsApp extends StatelessWidget {
  const ShortsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shorts Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7C4DFF), brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF0E0E14),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _input = TextEditingController();
  VideoStyle _style = VideoStyle.cinematic;
  bool _busy = false;
  int _step = 0;
  double _progress = 0;
  String _stageLabel = '';
  String? _error;
  String? _resultPath;
  int _runId = 0;
  final List<String> _logs = [];

  static const _steps = [
    'GÃ¶rseller indiriliyor',
    'Seslendiriliyor',
    'FFmpeg ile render',
    'Galeriye kaydedildi',
  ];

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _log(String m) {
    if (!mounted) return;
    setState(() {
      _logs.add(m);
      if (_logs.length > 80) _logs.removeAt(0);
    });
  }

  Future<void> _start() async {
    final text = _input.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'LÃ¼tfen bir konu yazÄ±n veya Gemini JSON senaryosunu yapÄ±ÅŸtÄ±rÄ±n.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _resultPath = null;
      _step = 1;
      _progress = 0;
      _stageLabel = 'BaÅŸlÄ±yor...';
      _logs.clear();
    });
    try {
      final path = await Pipeline(
        onStage: (step, label, p) {
          if (!mounted) return;
          setState(() {
            _step = step;
            _stageLabel = label;
            _progress = p;
          });
        },
        onLog: _log,
      ).run(input: text, style: _style);
      if (!mounted) return;
      setState(() {
        _resultPath = path;
        _runId++;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyPrompt() async {
    final t = _input.text.trim();
    final topic = (t.isEmpty || ScenarioService.looksLikeJson(t)) ? '<BURAYA KONUNUZU YAZIN>' : t;
    await Clipboard.setData(ClipboardData(text: scriptPrompt(topic)));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Ä°stem kopyalandÄ±. Gemini Web\'e yapÄ±ÅŸtÄ±rÄ±n, dÃ¶nen JSON\'u buraya koyun.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Shorts Studio'), backgroundColor: Colors.transparent),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            TextField(
              controller: _input,
              enabled: !_busy,
              minLines: 5,
              maxLines: 10,
              decoration: InputDecoration(
                labelText: 'Senaryo JSON\'Ä± / Konu',
                hintText: 'Ã–rn: YazÄ±lmÄ±ÅŸ en tehlikeli kitap\n\nveya Gemini Web\'den kopyaladÄ±ÄŸÄ±nÄ±z JSON',
                filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _busy ? null : _copyPrompt,
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Gemini istemini kopyala'),
              ),
            ),
            const SizedBox(height: 8),
            Text('Videonun tarzÄ±', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<VideoStyle>(
              showSelectedIcon: false,
              segments: [for (final s in VideoStyle.values) ButtonSegment(value: s, label: Text(s.label))],
              selected: {_style},
              onSelectionChanged: _busy ? null : (v) => setState(() => _style = v.first),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy ? null : _start,
              icon: const Icon(Icons.movie_creation_rounded),
              label: const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Text('Videoyu OluÅŸtur')),
            ),
            if (_busy || _step > 0) ...[
              const SizedBox(height: 20),
              Card(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LinearProgressIndicator(value: _progress, minHeight: 8, borderRadius: BorderRadius.circular(8)),
                      const SizedBox(height: 12),
                      Text(_stageLabel, style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 8),
                      for (var i = 0; i < _steps.length; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(children: [
                            _stepIcon(i + 1, cs),
                            const SizedBox(width: 8),
                            Text('[${i + 1}/4] ${_steps[i]}'),
                          ]),
                        ),
                      if (_busy)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text('Uygulamadan Ã§Ä±kmayÄ±n; ekran aÃ§Ä±k kalÄ±r.',
                              style: TextStyle(fontSize: 12, color: Colors.white54)),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Card(
                color: cs.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: SelectableText(_error!, style: TextStyle(color: cs.onErrorContainer)),
                ),
              ),
            ],
            if (_resultPath != null) ...[
              const SizedBox(height: 20),
              ResultPlayer(key: ValueKey(_runId), path: _resultPath!),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => Share.shareXFiles([XFile(_resultPath!)], text: 'final_shorts.mp4'),
                icon: const Icon(Icons.share_rounded),
                label: const Text('PaylaÅŸ'),
              ),
            ],
            if (_logs.isNotEmpty) ...[
              const SizedBox(height: 16),
              ExpansionTile(
                title: const Text('AyrÄ±ntÄ±lÄ± gÃ¼nlÃ¼k'),
                children: [Align(alignment: Alignment.centerLeft, child: SelectableText(_logs.join('\n')))],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stepIcon(int step, ColorScheme cs) {
    if (_step > step || (_step == 4 && !_busy)) {
      return Icon(Icons.check_circle_rounded, size: 18, color: cs.primary);
    }
    if (_step == step && _busy) {
      return const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2));
    }
    return const Icon(Icons.radio_button_unchecked, size: 18, color: Colors.white38);
  }
}

class ResultPlayer extends StatefulWidget {
  const ResultPlayer({super.key, required this.path});
  final String path;

  @override
  State<ResultPlayer> createState() => _ResultPlayerState();
}

class _ResultPlayerState extends State<ResultPlayer> {
  late final VideoPlayerController _c;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _c = VideoPlayerController.file(File(widget.path));
    _c.initialize().then((_) {
      if (!mounted) return;
      _c.setLooping(true);
      _c.play();
      setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: GestureDetector(
            onTap: () => setState(() => _c.value.isPlaying ? _c.pause() : _c.play()),
            child: Stack(
              alignment: Alignment.center,
              children: [
                AspectRatio(aspectRatio: _c.value.aspectRatio, child: VideoPlayer(_c)),
                if (!_c.value.isPlaying)
                  const Icon(Icons.play_circle_fill_rounded, size: 64, color: Colors.white70),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
