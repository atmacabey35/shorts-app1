// Shorts Studio - on-device, free, autonomous Shorts/Reels generator.
//
// Flow: script (topic -> Pollinations text | pasted Gemini JSON)
//       -> images (VisualPipeline -> FluxVisualProvider, neighbor-image fallback removed)
//       -> voice (Edge-TTS -> Google Translate TTS -> Android TTS, one engine per video)
//       -> single FFmpeg pass: Ken Burns + ASS hardsub + synth music + ducking
//       -> save to gallery + play + share.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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

import 'models/scene.dart';
import 'services/visuals/flux_visual_provider.dart';
import 'services/visuals/visual_pipeline.dart';

// ============================ CONSTANTS ============================
const int kFps = 30;
const double kSceneGap = 0.30; // silence between scenes (sec)
const double kEndTail = 0.60; // tail after the last scene (sec)
const String kEdgeVoice = 'Microsoft Server Speech Text to Speech Voice (tr-TR, AhmetNeural)';
const String kSubtitleFont = 'Roboto'; // Android system font, has Turkish glyphs

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
    'Karikatür',
    'stylized 3D cartoon animation style, vibrant colors, soft lighting, expressive, high detail, vertical 9:16 composition',
    'eq=contrast=1.05:saturation=1.35',
  );

  const VideoStyle(this.label, this.suffix, this.grade);
  final String label;
  final String suffix;
  final String grade;
}

// ============================ MODELS ============================
class Scenario {
  Scenario(this.title, this.scenes);
  final String title;
  final List<Scene> scenes;
}

class WordTiming {
  WordTiming(this.text, this.start, this.end);
  final String text;
  final double start;
  final double end;
}

class SceneAudio {
  SceneAudio(this.file, this.speechSec, this.words);
  final File file;
  final double speechSec;
  final List<WordTiming> words;
  double get totalSec => speechSec + kSceneGap;
}

// ============================ HELPERS ============================
const String _scriptPromptTemplate =
    '''Sen viral YouTube Shorts senaristisisin. Konu: "{TOPIC}"

45-60 saniyelik, gizem ve merak uyandıran dikey video senaryosu yaz.
Kurallar:
- Toplam 130-160 kelime olsun.
- İlk cümle çok güçlü bir kanca (hook) olsun.
- Yalnızca doğrulanabilir bilgiler kullan.
- Son cümle merak bırakan bir kapanış olsun.
- 4 ile 6 arası sahne üret.
- "voiceover": SADECE seslendirilecek duru Türkçe metin.
- "subject": İngilizce odak mekanizma veya nesne.
- "action": İngilizce parçanın hareketi veya eylemi.
- "camera": transparent side cutaway, close-up vb. kamera açısı.
- "visual_prompt": Sahneyi anlatan somut görsel istemi (Yazı/logo içermesin).

YALNIZCA şu JSON'u döndür:
{"title": "kısa başlık", "scenes": [{"voiceover": "...", "subject": "...", "action": "...", "camera": "...", "visual_prompt": "..."}]}''';

String scriptPrompt(String topic) => _scriptPromptTemplate.replaceAll('{TOPIC}', topic);

String trUpper(String s) => s.replaceAll('i', 'İ').replaceAll('ı', 'I').toUpperCase();

String _hex(int n) {
  final r = Random.secure();
  return List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
}

String shortErr(Object? e) {
  var s = '$e'.replaceAll(RegExp(r'\s+'), ' ');
  if (s.length > 150) s = '${s.substring(0, 150)}...';
  return s;
}

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
        if (!done.isCompleted) done.completeError(Exception('FFmpeg hatası (kod: $rc)\n$tail'));
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
  if (d == null || d <= 0) throw Exception('Ses süresi okunamadı: $path');
  return d;
}

// ============================ 1) SCRIPT ============================
class ScenarioService {
  static bool looksLikeJson(String s) => s.contains('{') && s.contains('"scenes"');

  static Scenario parse(String raw) {
    var text = raw.trim();
    final open = text.indexOf(RegExp(r'[\{\[]'));
    final close = max(text.lastIndexOf('}'), text.lastIndexOf(']'));
    if (open < 0 || close <= open) throw const FormatException('JSON bulunamadı.');
    text = text.substring(open, close + 1);

    final dynamic data = jsonDecode(text);
    final dynamic rawScenes = data is List ? data : (data is Map ? data['scenes'] : null);
    if (rawScenes is! List || rawScenes.isEmpty) {
      throw const FormatException('JSON içinde dolu bir "scenes" listesi yok.');
    }
    final scenes = <Scene>[];
    for (var i = 0; i < rawScenes.length && i < 6; i++) {
      final s = rawScenes[i];
      if (s is! Map) throw FormatException('Sahne ${i + 1} geçersiz.');
      final map = Map<String, dynamic>.from(s);
      map['voiceover'] = _cleanVoice('${map['voiceover'] ?? ''}');
      final scene = Scene.fromJson(map);
      if (scene.voiceover.isEmpty || scene.visualPrompt.isEmpty) {
        throw FormatException('Sahne ${i + 1}: voiceover ve visual_prompt dolu olmalı.');
      }
      scenes.add(scene);
    }
    final title = data is Map ? '${data['title'] ?? 'Shorts'}' : 'Shorts';
    return Scenario(title, scenes);
  }

  static String _cleanVoice(String t) {
    t = t.replaceAll(RegExp(r'[\*#_\[\]\(\)\{\}<>]'), '');
    t = t.replaceAll(RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true), '');
    return t.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

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
    throw Exception('Senaryo otomatik üretilemedi (${shortErr(last)}).');
  }
}

// ============================ 2) VOICE ============================
class EdgeResult {
  EdgeResult(this.audio, this.words);
  final Uint8List audio;
  final List<WordTiming> words;
}

class EdgeTts {
  static const _token = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const _versions = ['143.0.3650.75', '142.0.3595.94', '134.0.3124.66', '130.0.2849.68'];
  static const _base = 'speech.platform.bing.com/consumer/speech/synthesize/readaloud';
  static String? _goodVersion;
  static int _skewSec = 0;

  static String _ua(String ver) {
    final major = ver.split('.').first;
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$major.0.0.0 Safari/537.36 Edg/$major.0.0.0';
  }

  static String _gec() {
    var ticks = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + _skewSec + 11644473600;
    ticks -= ticks % 300;
    ticks *= 10000000;
    return sha256.convert(ascii.encode('$ticks$_token')).toString().toUpperCase();
  }

  static String _jsTime() {
    const d = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final t = DateTime.now().toUtc();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d[t.weekday - 1]} ${m[t.month - 1]} ${p(t.day)} ${t.year} ${p(t.hour)}:${p(t.minute)}:${p(t.second)} GMT+0000 (Coordinated Universal Time)';
  }

  static Future<void> _syncClock() async {
    try {
      final r = await http
          .get(
            Uri.parse('https://$_base/voices/list?trustedclienttoken=$_token'),
            headers: {'User-Agent': _ua(_versions.first)},
          )
          .timeout(const Duration(seconds: 10));
      final date = r.headers['date'];
      if (date != null) {
        _skewSec = HttpDate.parse(date).difference(DateTime.now().toUtc()).inSeconds;
      }
    } catch (_) {}
  }

  static Future<EdgeResult> synth(String text, void Function(String) log, {String rate = '+5%'}) async {
    Object? last;
    for (var attempt = 1; attempt <= 3; attempt++) {
      await _syncClock();
      final good = _goodVersion;
      final versions = <String>[if (good != null) good, ..._versions.where((v) => v != good)];
      for (final ver in versions) {
        try {
          final r = await _once(text, rate, ver);
          _goodVersion = ver;
          return r;
        } catch (e) {
          last = e;
          log('Edge-TTS (v$ver, deneme $attempt/3): ${shortErr(e)}');
          final msg = '$e';
          if (!msg.contains('403') && !msg.contains('401') && !msg.contains('not upgraded')) break;
        }
      }
      await Future.delayed(Duration(seconds: 2 * attempt));
    }
    throw Exception('Edge-TTS 3 denemede de yanıt vermedi: ${shortErr(last)}');
  }

  static Future<EdgeResult> _once(String text, String rate, String ver) async {
    final major = ver.split('.').first;
    final url = 'wss://$_base/edge/v1?TrustedClientToken=$_token&Sec-MS-GEC=${_gec()}&Sec-MS-GEC-Version=1-$ver&ConnectionId=${_hex(32)}';

    final client = HttpClient()
      ..userAgent = _ua(ver)
      ..connectionTimeout = const Duration(seconds: 20);
    WebSocket? opened;
    try {
      final socket = await WebSocket.connect(
        url,
        headers: {
          'Pragma': 'no-cache',
          'Cache-Control': 'no-cache',
          'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
          'Accept-Language': 'en-US,en;q=0.9',
          'Sec-CH-UA': '" Not;A Brand";v="99", "Microsoft Edge";v="$major", "Chromium";v="$major"',
          'Sec-CH-UA-Mobile': '?0',
          'Sec-Fetch-Site': 'none',
          'Sec-Fetch-Mode': 'websocket',
          'Sec-Fetch-Dest': 'empty',
          'Cookie': 'muid=${_hex(32).toUpperCase()};',
        },
        compression: CompressionOptions.compressionOff,
        customClient: client,
      ).timeout(const Duration(seconds: 25));
      opened = socket;

      final audio = BytesBuilder();
      final words = <WordTiming>[];
      final done = Completer<void>();

      socket.listen(
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
          if (!done.isCompleted) done.completeError(StateError('Bağlantı erken kapandı'));
        },
      );

      final ts = _jsTime();
      socket.add(
        'X-Timestamp:$ts\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false",'
        '"wordBoundaryEnabled":"true"},"outputFormat":"audio-24khz-96kbitrate-mono-mp3"}}}}\r\n',
      );
      final esc = text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');
      final ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='tr-TR'>"
          "<voice name='$kEdgeVoice'><prosody pitch='+0Hz' rate='$rate' volume='+0%'>$esc</prosody></voice></speak>";
      socket.add('X-RequestId:${_hex(32)}\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:${ts}Z\r\nPath:ssml\r\n\r\n$ssml');

      await done.future.timeout(const Duration(seconds: 60));
      final bytes = audio.toBytes();
      if (bytes.length < 1000) throw Exception('Boş ses döndü');
      return EdgeResult(bytes, words);
    } finally {
      if (opened != null) {
        try {
          await opened.close().timeout(const Duration(seconds: 5));
        } catch (_) {}
      }
      client.close(force: true);
    }
  }
}

class GoogleTts {
  static const _ua = 'Mozilla/5.0 (Linux; Android 14; SM-S926B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';

  static List<String> _chunks(String text, {int max = 180}) {
    final out = <String>[];
    var cur = '';
    final sentences = RegExp(r'[^.!?;:]+[.!?;:]*').allMatches(text).map((m) => m.group(0)!.trim()).where((s) => s.isNotEmpty);
    for (final s in sentences) {
      if (s.length > max) {
        if (cur.isNotEmpty) {
          out.add(cur);
          cur = '';
        }
        var buf = '';
        for (final w in s.split(' ')) {
          final next = buf.isEmpty ? w : '$buf $w';
          if (next.length > max && buf.isNotEmpty) {
            out.add(buf);
            buf = w;
          } else {
            buf = next;
          }
        }
        if (buf.isNotEmpty) out.add(buf);
      } else {
        final next = cur.isEmpty ? s : '$cur $s';
        if (next.length > max) {
          out.add(cur);
          cur = s;
        } else {
          cur = next;
        }
      }
    }
    if (cur.isNotEmpty) out.add(cur);
    return out;
  }

  static Future<File> synth(String text, int idx, Directory dir) async {
    final chunks = _chunks(text);
    if (chunks.isEmpty) throw Exception('Boş metin');
    final files = <File>[];
    for (var c = 0; c < chunks.length; c++) {
      final f = File('${dir.path}/g_${idx}_$c.mp3');
      Object? last;
      var ok = false;
      for (var attempt = 1; attempt <= 3 && !ok; attempt++) {
        try {
          final url = Uri.parse(
            'https://translate.google.com/translate_tts?ie=UTF-8&tl=tr&client=tw-ob'
            '&total=1&idx=0&textlen=${chunks[c].length}&q=${Uri.encodeComponent(chunks[c])}',
          );
          final r = await http.get(url, headers: {'User-Agent': _ua, 'Referer': 'https://translate.google.com/'}).timeout(const Duration(seconds: 30));
          final ct = r.headers['content-type'] ?? '';
          if (r.statusCode == 200 && ct.contains('audio') && r.bodyBytes.length > 500) {
            await f.writeAsBytes(r.bodyBytes);
            ok = true;
          } else {
            last = 'HTTP ${r.statusCode} $ct';
          }
        } catch (e) {
          last = e;
        }
        if (!ok) await Future.delayed(Duration(seconds: 2 * attempt));
      }
      if (!ok) throw Exception('Google TTS parça ${c + 1}/${chunks.length}: ${shortErr(last)}');
      files.add(f);
    }
    final list = File('${dir.path}/g_${idx}_list.txt');
    await list.writeAsString(files.map((f) => "file '${f.path}'\n").join());
    final out = File('${dir.path}/vo_$idx.wav');
    await runFfmpeg(['-y', '-f', 'concat', '-safe', '0', '-i', list.path, '-ar', '44100', '-ac', '2', out.path]);
    return out;
  }
}

class AndroidTts {
  static Future<File> synth(String text, String path) async {
    final tts = FlutterTts();
    final ok = await tts.isLanguageAvailable('tr-TR');
    if (ok != true) {
      throw Exception('Telefonda Türkçe TTS sesi yok.');
    }
    await tts.setLanguage('tr-TR');
    await tts.setSpeechRate(0.5);
    await tts.awaitSynthCompletion(true);
    await tts.synthesizeToFile(text, path, true);
    final f = File(path);
    if (!await f.exists() || await f.length() < 1000) throw Exception('Android TTS dosya üretemedi.');
    return f;
  }
}

enum _Engine {
  edge('Edge-TTS (AhmetNeural)'),
  google('Google Translate TTS'),
  android('Android yerel TTS');

  const _Engine(this.label);
  final String label;
}

class TtsService {
  static Future<List<SceneAudio>> synthAll(
    List<Scene> scenes,
    Directory dir,
    void Function(String) log,
    void Function(int done) onSceneDone,
  ) async {
    var e = 0;
    while (true) {
      final engine = _Engine.values[e];
      log('Seslendirme motoru: ${engine.label}');
      final results = <SceneAudio>[];
      var failed = false;
      for (var i = 0; i < scenes.length; i++) {
        try {
          results.add(await _synthOne(engine, scenes[i].voiceover, i, dir, log));
          onSceneDone(i + 1);
        } catch (err) {
          log('${engine.label} başarısız (sahne ${i + 1}): ${shortErr(err)}');
          failed = true;
          break;
        }
      }
      if (!failed) return results;
      e++;
      if (e >= _Engine.values.length) {
        throw Exception('Hiçbir seslendirme motoru çalışmadı.');
      }
      log('Sonraki motora geçiliyor: ${_Engine.values[e].label}');
    }
  }

  static Future<SceneAudio> _synthOne(_Engine engine, String text, int i, Directory dir, void Function(String) log) async {
    File src;
    var words = <WordTiming>[];
    if (engine == _Engine.edge) {
      final r = await EdgeTts.synth(text, log);
      src = File('${dir.path}/vo_$i.mp3');
      await src.writeAsBytes(r.audio);
      words = r.words;
    } else if (engine == _Engine.google) {
      src = await GoogleTts.synth(text, i, dir);
    } else {
      src = await AndroidTts.synth(text, '${dir.path}/vo_$i.wav');
    }

    final speech = await probeDuration(src.path);
    final out = File('${dir.path}/vo_${i}_pad.wav');
    await runFfmpeg(['-y', '-i', src.path, '-ar', '44100', '-ac', '2', '-af', 'apad=pad_dur=$kSceneGap', out.path]);
    if (words.isEmpty) words = _estimateWords(text, speech);
    return SceneAudio(out, speech, words);
  }

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

// ============================ 3) SUBTITLES (ASS) ============================
class _Ev {
  _Ev(this.start, this.end, this.text);
  double start;
  double end;
  final String text;
}

class SubtitleBuilder {
  static final RegExp _strip = RegExp('^[.,;:"\'\u00AB\u00BB\u2026\\-\u2013\u2014()]+|[.,;:"\'\u00AB\u00BB\u2026\\-\u2013\u2014()]+\$');

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
WrapStyle: 0
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Main,$kSubtitleFont,78,&H00FFFFFF,&H00FFFFFF,&H00000000,&H64000000,-1,0,0,0,100,100,0,0,1,6,0,2,70,70,400,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''';

    final clean = words.map((w) {
      final c = trUpper(w.text.replaceAll(_strip, ''));
      return WordTiming(c.isEmpty ? w.text : c, w.start, w.end);
    }).toList();

    const maxWords = 3;
    const maxChars = 15;
    final groups = <List<int>>[];
    var cur = <int>[];
    var curLen = 0;
    for (var i = 0; i < clean.length; i++) {
      final len = clean[i].text.length;
      final wouldBe = curLen + (cur.isEmpty ? 0 : 1) + len;
      if (cur.isNotEmpty && (cur.length >= maxWords || wouldBe > maxChars)) {
        groups.add(cur);
        cur = <int>[];
        curLen = 0;
      }
      curLen += (cur.isEmpty ? 0 : 1) + len;
      cur.add(i);
      final gap = i + 1 < clean.length ? clean[i + 1].start - clean[i].end : 0.0;
      if (RegExp(r'[.?!,]$').hasMatch(words[i].text) || gap > 0.5) {
        groups.add(cur);
        cur = <int>[];
        curLen = 0;
      }
    }
    if (cur.isNotEmpty) groups.add(cur);

    final events = <_Ev>[];
    for (final g in groups) {
      for (var pos = 0; pos < g.length; pos++) {
        final wi = g[pos];
        final start = clean[wi].start;
        final end = pos + 1 < g.length ? clean[g[pos + 1]].start : clean[wi].end + 0.10;
        final text = g.map((j) => j == wi ? '{\\1c&H00FFFF&}${clean[j].text}{\\1c&HFFFFFF&}' : clean[j].text).join(' ');
        events.add(_Ev(start, max(end, start + 0.06), text));
      }
    }

    events.sort((a, b) => a.start.compareTo(b.start));
    for (var k = 0; k + 1 < events.length; k++) {
      if (events[k].end > events[k + 1].start) events[k].end = events[k + 1].start;
    }

    final lines = StringBuffer();
    for (final e in events) {
      if (e.end - e.start < 0.02) continue;
      lines.writeln('Dialogue: 0,${_t(e.start)},${_t(e.end)},Main,,0,0,0,,${e.text}');
    }
    final f = File('${dir.path}/subs.ass');
    await f.writeAsBytes(utf8.encode(head + lines.toString()));
    return f;
  }
}

// ============================ 4) FFMPEG RENDER ============================
class Renderer {
  static const _motions = ['zoom_in', 'pan_down', 'zoom_out', 'pan_right', 'pan_up', 'zoom_in'];

  static String _zoompan(String kind, int n) {
    const cx = 'iw/2-(iw/zoom/2)';
    const cy = 'ih/2-(ih/zoom/2)';
    switch (kind) {
      case 'zoom_in':
        return "z='1+0.30*on/$n':x='$cx':y='$cy'";
      case 'zoom_out':
        return "z='1.30-0.30*on/$n':x='$cx':y='$cy'";
      case 'pan_down':
        return "z='1.25':x='$cx':y='(ih-ih/zoom)*on/$n'";
      case 'pan_up':
        return "z='1.25':x='$cx':y='(ih-ih/zoom)*(1-on/$n)'";
      default:
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
      args.addAll(['-i', img.path]);
    }
    args.addAll(['-i', voice.path]);
    final d = (total + 2).toStringAsFixed(2);
    for (final f in ['55', '82.41', '110.5']) {
      args.addAll(['-f', 'lavfi', '-i', 'sine=frequency=$f:sample_rate=44100:duration=$d']);
    }
    args.addAll(['-f', 'lavfi', '-i', 'anoisesrc=color=brown:amplitude=0.25:sample_rate=44100:duration=$d']);

    final fc = StringBuffer();
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

// ============================ 5) PIPELINE ============================
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

      // --- [1/4] Script + images
      onStage(1, '[1/4] Görseller üretiliyor...', 0.01);
      final Scenario scenario;
      if (ScenarioService.looksLikeJson(input)) {
        onLog('Yapıştırılan JSON ayrıştırılıyor...');
        scenario = ScenarioService.parse(input);
      } else {
        onLog('Konu için senaryo yazılıyor (Pollinations)...');
        scenario = await ScenarioService.fromTopic(input);
      }
      onLog('Başlık: ${scenario.title} • ${scenario.scenes.length} sahne');
      final n = scenario.scenes.length;

      final visualPipeline = VisualPipeline(FluxVisualProvider());
      final images = await visualPipeline.generateAll(
        scenes: scenario.scenes,
        outputDir: dir,
        styleSuffix: style.suffix,
        log: onLog,
        onProgress: (done, total) {
          onStage(1, '[1/4] Görseller üretiliyor... ($done/$total)', 0.05 + 0.30 * done / total);
        },
      );

      // --- [2/4] Voice
      onStage(2, '[2/4] Seslendiriliyor...', 0.35);
      final audios = await TtsService.synthAll(
        scenario.scenes,
        dir,
        onLog,
        (done) => onStage(2, '[2/4] Seslendiriliyor... ($done/$n)', 0.35 + 0.15 * done / n),
      );
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
      onLog('Toplam süre: ${total.toStringAsFixed(1)} sn');
      final ass = await SubtitleBuilder.build(allWords, dir);

      // --- [3/4] Render
      onStage(3, '[3/4] FFmpeg ile render alınıyor...', 0.52);
      final outPath = '${dir.path}/final_shorts.mp4';
      await Renderer.render(
        images: images,
        durations: durations,
        voice: voice,
        ass: ass,
        grade: style.grade,
        outPath: outPath,
        onProgress: (f) => onStage(3, '[3/4] FFmpeg ile render alınıyor... %${(f * 100).round()}', 0.52 + 0.43 * f),
      );

      // --- [4/4] Save to gallery
      if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
      await Gal.putVideo(outPath, album: 'Shorts Studio');
      onStage(4, '[4/4] Galeriye kaydedildi! (Galeri > Shorts Studio)', 1.0);
      return outPath;
    } finally {
      await WakelockPlus.disable();
    }
  }
}

// ============================ UI ============================
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
    'Görseller üretiliyor',
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
      if (_logs.length > 120) _logs.removeAt(0);
    });
  }

  Future<void> _start() async {
    final text = _input.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Lütfen bir konu yazın veya Gemini JSON senaryosunu yapıştırın.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _resultPath = null;
      _step = 1;
      _progress = 0;
      _stageLabel = 'Başlıyor...';
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
      const SnackBar(content: Text('İstem kopyalandı. Gemini Web\'e yapıştırın, dönen JSON\'u buraya koyun.')),
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
                labelText: 'Senaryo JSON\'ı / Konu',
                hintText: 'Örn: Yazılmış en tehlikeli kitap\n\nveya Gemini Web\'den kopyaladığınız JSON',
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
            Text('Videonun tarzı', style: Theme.of(context).textTheme.labelLarge),
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
              label: const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Text('Videoyu Oluştur')),
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
                          child: Text('Uygulamadan çıkmayın; ekran açık kalır.',
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
                label: const Text('Paylaş'),
              ),
            ],
            if (_logs.isNotEmpty) ...[
              const SizedBox(height: 16),
              ExpansionTile(
                title: const Text('Ayrıntılı günlük'),
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
