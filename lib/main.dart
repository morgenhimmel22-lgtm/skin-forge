// SkinForge – Minecraft-Skin- und Texture-Pack-Creator (Java Edition)
// Alles in einer Datei. Android: INTERNET-Berechtigung nötig (siehe Workflow/Anleitung).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipDecoder, ZipEncoder;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const SkinForgeApp());

class SkinForgeApp extends StatelessWidget {
  const SkinForgeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SkinForge',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF4F8A3C), useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF4F8A3C), brightness: Brightness.dark, useMaterial3: true),
        home: const Home(),
      );
}

class SkinException implements Exception {
  final String message;
  SkinException(this.message);
}

// ───────────── Pixelpuffer & Bearbeitungszustand ─────────────

/// RGBA-Pixelpuffer (8 Bit, nicht vormultipliziert, keine Glättung)
class Pix {
  final int w, h;
  final Uint8List d;
  Pix(this.w, this.h, [Uint8List? data]) : d = data ?? Uint8List(w * h * 4);
  Pix copy() => Pix(w, h, Uint8List.fromList(d));
  int get(int x, int y) {
    final i = (y * w + x) * 4;
    return (d[i + 3] << 24) | (d[i] << 16) | (d[i + 1] << 8) | d[i + 2];
  }

  void set(int x, int y, int c) {
    final i = (y * w + x) * 4;
    d[i] = (c >> 16) & 255;
    d[i + 1] = (c >> 8) & 255;
    d[i + 2] = c & 255;
    d[i + 3] = (c >> 24) & 255;
  }
}

/// Dokument mit Undo/Redo (max. 50 Schritte)
class Doc extends ChangeNotifier {
  Pix pix;
  final _u = <Uint8List>[], _r = <Uint8List>[];
  Doc(this.pix);
  bool get canUndo => _u.isNotEmpty;
  bool get canRedo => _r.isNotEmpty;
  void snap() {
    _u.add(Uint8List.fromList(pix.d));
    if (_u.length > 50) _u.removeAt(0);
    _r.clear();
  }

  void undo() {
    if (_u.isEmpty) return;
    _r.add(Uint8List.fromList(pix.d));
    pix.d.setAll(0, _u.removeLast());
    notifyListeners();
  }

  void redo() {
    if (_r.isEmpty) return;
    _u.add(Uint8List.fromList(pix.d));
    pix.d.setAll(0, _r.removeLast());
    notifyListeners();
  }

  void touch() => notifyListeners();
  void reset(Pix p) {
    pix = p;
    _u.clear();
    _r.clear();
    notifyListeners();
  }
}

Pix solid(int n, int c) {
  final p = Pix(n, n);
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      p.set(x, y, c);
    }
  }
  return p;
}

/// Bild dekodieren (PNG/JPEG/WebP) – über die Flutter-Engine, liefert immer RGBA
Future<Pix> decodePix(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final im = (await codec.getNextFrame()).image;
  final bd = await im.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  final p = Pix(im.width, im.height, Uint8List.fromList(bd!.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes)));
  im.dispose();
  codec.dispose();
  for (var i = 0; i < p.d.length; i += 4) {
    if (p.d[i + 3] == 0) {
      p.d[i] = 0;
      p.d[i + 1] = 0;
      p.d[i + 2] = 0;
    }
  }
  return p;
}

/// Pix → PNG-Bytes (RGBA, 8 Bit)
Uint8List pixToPng(Pix p) {
  final im = img.Image(width: p.w, height: p.h, numChannels: 4);
  for (var y = 0; y < p.h; y++) {
    for (var x = 0; x < p.w; x++) {
      final i = (y * p.w + x) * 4;
      im.setPixelRgba(x, y, p.d[i], p.d[i + 1], p.d[i + 2], p.d[i + 3]);
    }
  }
  return img.encodePng(im);
}

/// Pix → ui.Image für die Anzeige (vormultipliziert, damit transparente Pixel nichts aufhellen)
Future<ui.Image> toUi(Pix p) {
  final b = Uint8List(p.d.length);
  for (var i = 0; i < b.length; i += 4) {
    final a = p.d[i + 3];
    b[i] = p.d[i] * a ~/ 255;
    b[i + 1] = p.d[i + 1] * a ~/ 255;
    b[i + 2] = p.d[i + 2] * a ~/ 255;
    b[i + 3] = a;
  }
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(b, p.w, p.h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

/// Skalieren (Mittelwert beim Verkleinern, Nearest beim Vergrößern)
Pix resample(Pix s, int nw, int nh) {
  final p = Pix(nw, nh);
  for (var y = 0; y < nh; y++) {
    for (var x = 0; x < nw; x++) {
      final x0 = x * s.w ~/ nw, x1 = max(x0 + 1, (x + 1) * s.w ~/ nw);
      final y0 = y * s.h ~/ nh, y1 = max(y0 + 1, (y + 1) * s.h ~/ nh);
      var a = 0, r = 0, g = 0, b = 0, n = 0;
      for (var j = y0; j < y1; j++) {
        for (var i = x0; i < x1; i++) {
          final c = s.get(i, j);
          a += c >> 24;
          r += (c >> 16) & 255;
          g += (c >> 8) & 255;
          b += c & 255;
          n++;
        }
      }
      p.set(x, y, ((a ~/ n) << 24) | ((r ~/ n) << 16) | ((g ~/ n) << 8) | (b ~/ n));
    }
  }
  return p;
}

// ───────────── Skin-Layout (Java 64×64) ─────────────

/// Körperteil: UV-Ursprung innen (u,v) / außen (ou,ov), Größe (w,h,d), Minimalecke (x,y,z), Drehpunkt, Aufblähung e der Außenschicht
class P {
  final String n;
  final int u, v, ou, ov, w, h, d;
  final double x, y, z, px, py, pz, e;
  const P(this.n, this.u, this.v, this.ou, this.ov, this.w, this.h, this.d, this.x, this.y, this.z, this.px, this.py, this.pz, this.e);
}

const parts = [
  P('head', 0, 0, 32, 0, 8, 8, 8, -4, 24, -4, 0, 24, 0, .5),
  P('body', 16, 16, 16, 32, 8, 12, 4, -4, 12, -2, 0, 12, 0, .25),
  P('armR', 40, 16, 40, 32, 4, 12, 4, -8, 12, -2, -6, 22, 0, .25),
  P('armL', 32, 48, 48, 48, 4, 12, 4, 4, 12, -2, 6, 22, 0, .25),
  P('legR', 0, 16, 0, 32, 4, 12, 4, -4, 0, -2, -2, 12, 0, .25),
  P('legL', 16, 48, 0, 48, 4, 12, 4, 0, 0, -2, 2, 12, 0, .25),
];

/// UV-Rechtecke [x, y, breite, höhe]: oben, unten, rechts, vorne, links, hinten
List<List<int>> faces(int u, int v, int w, int h, int d) => [
      [u + d, v, w, d],
      [u + d + w, v, w, d],
      [u, v + d, d, h],
      [u + d, v + d, w, h],
      [u + d + w, v + d, d, h],
      [u + 2 * d + w, v + d, w, h],
    ];

List<List<int>> allFaces() => [
      for (final p in parts) ...faces(p.u, p.v, p.w, p.h, p.d),
      for (final p in parts) ...faces(p.ou, p.ov, p.w, p.h, p.d),
    ];

/// Eckpunkte je Fläche (oben-links, oben-rechts, unten-rechts, unten-links – von außen gesehen)
List<List<double>> corners(int f, double x0, double y0, double z0, double x1, double y1, double z1) {
  switch (f) {
    case 0:
      return [[x0, y1, z0], [x1, y1, z0], [x1, y1, z1], [x0, y1, z1]];
    case 1:
      return [[x0, y0, z1], [x1, y0, z1], [x1, y0, z0], [x0, y0, z0]];
    case 2:
      return [[x0, y1, z0], [x0, y1, z1], [x0, y0, z1], [x0, y0, z0]];
    case 3:
      return [[x0, y1, z1], [x1, y1, z1], [x1, y0, z1], [x0, y0, z1]];
    case 4:
      return [[x1, y1, z1], [x1, y1, z0], [x1, y0, z0], [x1, y0, z1]];
    default:
      return [[x1, y1, z0], [x0, y1, z0], [x0, y0, z0], [x1, y0, z0]];
  }
}

const _nrm = [
  [0.0, 1.0, 0.0], [0.0, -1.0, 0.0], [-1.0, 0.0, 0.0], [0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 0.0, -1.0],
];

List<bool> baseMask() {
  final m = List.filled(4096, false);
  for (final pa in parts) {
    for (final f in faces(pa.u, pa.v, pa.w, pa.h, pa.d)) {
      for (var y = f[1]; y < f[1] + f[3]; y++) {
        for (var x = f[0]; x < f[0] + f[2]; x++) {
          m[y * 64 + x] = true;
        }
      }
    }
  }
  return m;
}

/// Zufälliger Mock-Skin (Fallback, wenn die KI nicht erreichbar ist)
Pix mockSkin(Random r) {
  int rc() => 0xFF000000 | ((r.nextInt(180) + 40) << 16) | ((r.nextInt(180) + 40) << 8) | (r.nextInt(180) + 40);
  final hair = rc(), shirt = rc(), pants = rc();
  final skin = const [0xFFF1C27D, 0xFFC68642, 0xFF8D5524, 0xFFFFDBAC][r.nextInt(4)];
  final p = Pix(64, 64);
  void fill(List<int> f, int c) {
    for (var y = f[1]; y < f[1] + f[3]; y++) {
      for (var x = f[0]; x < f[0] + f[2]; x++) {
        p.set(x, y, c);
      }
    }
  }

  for (final pa in parts) {
    final fr = faces(pa.u, pa.v, pa.w, pa.h, pa.d);
    final arm = pa.n.startsWith('arm');
    final base = pa.n == 'head' || arm ? skin : (pa.n == 'body' ? shirt : pants);
    for (final f in fr) {
      fill(f, base);
    }
    if (pa.n == 'head') {
      fill(fr[0], hair);
      fill(fr[5], hair);
      fill([8, 8, 8, 2], hair);
      p.set(9, 11, 0xFF2B4EA8);
      p.set(14, 11, 0xFF2B4EA8);
      p.set(11, 13, 0xFF8B4B3B);
      p.set(12, 13, 0xFF8B4B3B);
    }
    if (arm) {
      fill(fr[0], shirt);
      for (var i = 2; i < 6; i++) {
        fill([fr[i][0], fr[i][1], fr[i][2], 4], shirt);
      }
    }
  }
  return p;
}

Pix defaultSkin() => mockSkin(Random(7));

// ───────────── Import & Validierung ─────────────

/// Legacy 64×32 → 64×64 (Minecraft-Algorithmus: Arme/Beine gespiegelt kopieren)
Pix legacyToModern(Pix s) {
  final p = Pix(64, 64);
  for (var y = 0; y < 32; y++) {
    for (var x = 0; x < 64; x++) {
      p.set(x, y, s.get(x, y));
    }
  }
  // Quelle x,y → Ziel x,y, Breite, Höhe (horizontal gespiegelt)
  const m = [
    [4, 16, 20, 48, 4, 4], [8, 16, 24, 48, 4, 4], [8, 20, 16, 52, 4, 12], [4, 20, 20, 52, 4, 12],
    [0, 20, 24, 52, 4, 12], [12, 20, 28, 52, 4, 12], [44, 16, 36, 48, 4, 4], [48, 16, 40, 48, 4, 4],
    [48, 20, 32, 52, 4, 12], [44, 20, 36, 52, 4, 12], [40, 20, 40, 52, 4, 12], [52, 20, 44, 52, 4, 12],
  ];
  for (final r in m) {
    for (var j = 0; j < r[5]; j++) {
      for (var i = 0; i < r[4]; i++) {
        p.set(r[2] + r[4] - 1 - i, r[3] + j, s.get(r[0] + i, r[1] + j));
      }
    }
  }
  return p;
}

/// Prüft Größe/Format und liefert einen modernen 64×64-RGBA-Skin
Future<Pix> validateSkin(Uint8List bytes) async {
  if (bytes.length > 2 * 1024 * 1024) throw SkinException('Datei ist größer als 2 MB.');
  final Pix p;
  try {
    p = await decodePix(bytes);
  } catch (_) {
    throw SkinException('Datei ist kein gültiges Bild (evtl. beschädigt).');
  }
  if (p.w != 64 || (p.h != 64 && p.h != 32)) {
    throw SkinException('Größe ${p.w}×${p.h} wird nicht unterstützt (erlaubt: 64×64 oder 64×32).');
  }
  return p.h == 32 ? legacyToModern(p) : p;
}

Future<(Pix, String)?> pickSkin(BuildContext c) async {
  final r = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
  if (r == null || r.files.isEmpty) return null; // Abbruch → keine Aktion
  final f = r.files.first;
  if (f.bytes == null) {
    if (c.mounted) snack(c, 'Import fehlgeschlagen: Datei konnte nicht gelesen werden.');
    return null;
  }
  if (!c.mounted) return null;
  final p = await busy(c, () => validateSkin(f.bytes!));
  if (p == null) return null;
  if (c.mounted) snack(c, 'Skin erfolgreich geladen');
  return (p, f.name.replaceAll(RegExp(r'\.png$', caseSensitive: false), ''));
}

// ───────────── Mojang-Lookup ─────────────

Future<Pix> mojangSkin(String name) async {
  const t = Duration(seconds: 15);
  final r = await http.get(Uri.parse('https://api.mojang.com/users/profiles/minecraft/${Uri.encodeComponent(name)}')).timeout(t);
  if (r.statusCode == 404 || r.statusCode == 204) throw SkinException('Spieler „$name“ nicht gefunden.');
  if (r.statusCode == 429) throw SkinException('Mojang-Rate-Limit – bitte kurz warten.');
  if (r.statusCode != 200) throw SkinException('Mojang-Fehler (${r.statusCode}).');
  final id = jsonDecode(r.body)['id'];
  final s = await http.get(Uri.parse('https://sessionserver.mojang.com/session/minecraft/profile/$id')).timeout(t);
  if (s.statusCode != 200) throw SkinException('Profil nicht abrufbar (${s.statusCode}) – evtl. Rate-Limit.');
  final props = jsonDecode(s.body)['properties'] as List;
  final tex = jsonDecode(utf8.decode(base64Decode(props.first['value'] as String)));
  final url = tex['textures']?['SKIN']?['url'] as String?;
  if (url == null) throw SkinException('Dieser Account hat keinen eigenen Skin.');
  final png = await http.get(Uri.parse(url.replaceFirst('http://', 'https://'))).timeout(t);
  return validateSkin(png.bodyBytes);
}

// ───────────── KI (Pollinations, ohne API-Key) ─────────────

class Ai {
  static final cool = ValueNotifier<int>(0); // Cooldown in Sekunden
  static String? hint; // Hinweis (z. B. Mock-Fallback)
  static Timer? _t;

  static void _start() {
    cool.value = 15;
    _t?.cancel();
    _t = Timer.periodic(const Duration(seconds: 1), (t) {
      cool.value--;
      if (cool.value <= 0) t.cancel();
    });
  }

  /// Anonym: 1 Anfrage / 15 s. Wartet den Cooldown ab und wiederholt einmal bei 429.
  static Future<Uint8List> fetch(String prompt, int size) async {
    while (cool.value > 0) {
      await Future.delayed(const Duration(milliseconds: 300));
    }
    for (var i = 0; i < 2; i++) {
      _start();
      final uri = Uri.https('image.pollinations.ai', '/prompt/${prompt.replaceAll('/', ' ')}', {
        'width': '$size',
        'height': '$size',
        'model': 'flux',
        'nologo': 'true',
        'enhance': 'true',
        'seed': '${Random().nextInt(99999)}',
      });
      final r = await http.get(uri).timeout(const Duration(seconds: 90));
      if (r.statusCode == 200) return r.bodyBytes;
      if (r.statusCode != 429) throw SkinException('KI-Dienst antwortet mit Fehler ${r.statusCode}.');
      await Future.delayed(const Duration(seconds: 15));
    }
    throw SkinException('KI-Rate-Limit erreicht – bitte später erneut versuchen.');
  }
}

/// Text → Skin: KI-Bild auf die 64×64-UV legen (Basisschicht deckend, Rest transparent)
Future<Pix> aiSkin(String desc) async {
  try {
    final bytes = await Ai.fetch('minecraft skin $desc, flat texture, 64x64 pixel art, no background, no shadows', 64);
    final s = resample(await decodePix(bytes), 64, 64);
    final m = baseMask();
    for (var i = 0; i < 4096; i++) {
      final x = i % 64, y = i ~/ 64;
      s.set(x, y, m[i] ? (s.get(x, y) | 0xFF000000) : 0);
    }
    return s;
  } catch (_) {
    Ai.hint = 'KI nicht erreichbar – zufälliger Mock-Skin erzeugt.';
    return mockSkin(Random());
  }
}

Future<Pix> aiTexture(String desc, int size) async {
  try {
    final bytes = await Ai.fetch(
        'Minecraft-style seamless tileable ${size}x$size pixel art texture of $desc, flat even lighting, crisp pixel definition, fills the entire square edge to edge, no border, vanilla-inspired shading',
        size);
    final p = resample(await decodePix(bytes), size, size);
    for (var i = 3; i < p.d.length; i += 4) {
      p.d[i] = 255; // Texturen deckend
    }
    return makeSeamless(p);
  } catch (_) {
    Ai.hint = 'KI nicht erreichbar – zufällige Mock-Textur erzeugt.';
    final r = Random();
    final b = [for (var i = 0; i < 3; i++) 70 + r.nextInt(130)];
    final p = Pix(size, size);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final v = r.nextInt(41) - 20;
        int ch(int i) => min(255, max(0, b[i] + v));
        p.set(x, y, 0xFF000000 | (ch(0) << 16) | (ch(1) << 8) | ch(2));
      }
    }
    return makeSeamless(p, force: true);
  }
}

int _dc(int a, int b) => (((a >> 16) & 255) - ((b >> 16) & 255)).abs() + (((a >> 8) & 255) - ((b >> 8) & 255)).abs() + ((a & 255) - (b & 255)).abs();

/// Nahtlos machen: Randbereiche durch um die halbe Kachel versetzte Kopie ersetzen (Pixel bleiben scharf)
Pix makeSeamless(Pix p, {bool force = false}) {
  var diff = 0;
  for (var i = 0; i < p.w; i++) {
    diff += _dc(p.get(i, 0), p.get(i, p.h - 1));
  }
  for (var j = 0; j < p.h; j++) {
    diff += _dc(p.get(0, j), p.get(p.w - 1, j));
  }
  if (!force && diff / (p.w + p.h) < 30) return p; // Ränder passen schon
  final o = p.copy();
  for (var y = 0; y < p.h; y++) {
    for (var x = 0; x < p.w; x++) {
      final ex = (x - (p.w - 1) / 2).abs() / ((p.w - 1) / 2), ey = (y - (p.h - 1) / 2).abs() / ((p.h - 1) / 2);
      if (max(ex, ey) > .7) p.set(x, y, o.get((x + p.w ~/ 2) % p.w, (y + p.h ~/ 2) % p.h));
    }
  }
  return p;
}

// ───────────── Texture Packs ─────────────

class Tex {
  String path;
  Pix pix;
  Uint8List? thumb;
  Tex(this.path, this.pix);
}

class Pack {
  String name, version;
  final List<Tex> tex;
  Pack(this.name, this.version, this.tex);
}

/// Zielversion → Resource-Pack-Format [Major, Minor] (Stand 11/2026, laut Minecraft Wiki).
/// Ab 1.21.9 heißen die Felder min_format/max_format; seit 2026 heißen die Versionen 26.x.
const packFormats = <String, List<int>>{'1.8': [1, 0], '1.21.11': [75, 0], '26.3': [97, 1]};

String mcmeta(Pack p) {
  final f = packFormats[p.version]!;
  final pack = <String, Object>{'description': '${p.name} – erstellt mit SkinForge', 'pack_format': f[0]};
  if (p.version != '1.8') {
    pack['min_format'] = [f[0], 0];
    pack['max_format'] = f;
  }
  return const JsonEncoder.withIndent('  ').convert({'pack': pack});
}

Uint8List exportZip(Pack p) {
  final a = Archive();
  void add(String n, List<int> b) => a.addFile(ArchiveFile(n, b.length, b));
  add('pack.mcmeta', utf8.encode(mcmeta(p)));
  add('pack.png', pixToPng(p.tex.isEmpty ? Pix(64, 64) : resample(p.tex.first.pix, 64, 64)));
  for (final t in p.tex) {
    add(t.path, pixToPng(t.pix));
  }
  return Uint8List.fromList(ZipEncoder().encode(a)!);
}

Future<Pack> importZip(Uint8List bytes, String name) async {
  final a = ZipDecoder().decodeBytes(bytes);
  final metas = a.files.where((f) => f.isFile && f.name.endsWith('pack.mcmeta')).toList();
  if (metas.isEmpty) throw SkinException('pack.mcmeta fehlt – das ist kein gültiges Texture Pack.');
  final root = metas.first.name.substring(0, metas.first.name.length - 'pack.mcmeta'.length);
  final tex = <Tex>[];
  for (final f in a.files) {
    if (f.isFile && f.name.startsWith('${root}assets/minecraft/textures/') && f.name.endsWith('.png')) {
      try {
        tex.add(Tex(f.name.substring(root.length), await decodePix(Uint8List.fromList(f.content as List<int>))));
      } catch (_) {} // einzelne defekte PNGs überspringen
    }
  }
  if (tex.isEmpty) throw SkinException('Keine Texturen unter assets/minecraft/textures/ gefunden.');
  var fmt = -1;
  try {
    final pk = jsonDecode(utf8.decode(metas.first.content as List<int>))['pack'];
    final raw = pk['pack_format'] ?? pk['min_format'];
    final v = raw is List ? raw[0] : raw;
    if (v is num) fmt = v.toInt();
  } catch (_) {}
  final ver = packFormats.entries.firstWhere((e) => e.value[0] == fmt, orElse: () => MapEntry<String, List<int>>('26.3', [97, 1])).key;
  return Pack(name, ver, tex);
}

Future<Pack?> pickPack(BuildContext c) async {
  final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['zip'], withData: true);
  if (r == null || r.files.isEmpty) return null;
  final f = r.files.first;
  if (f.bytes == null || !c.mounted) return null;
  return busy(c, () => importZip(f.bytes!, f.name.replaceAll(RegExp(r'\.zip$', caseSensitive: false), '')));
}

// ───────────── Hilfen: Snackbar, Dialoge, Teilen ─────────────

void snack(BuildContext c, String m) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

/// Zeigt einen Ladekreis, fängt Fehler ab und meldet sie per Snackbar
Future<T?> busy<T>(BuildContext c, Future<T> Function() f) async {
  final nav = Navigator.of(c, rootNavigator: true);
  showDialog<void>(
    context: c,
    barrierDismissible: false,
    builder: (_) => const PopScope(canPop: false, child: Center(child: CircularProgressIndicator())),
  );
  try {
    final r = await f();
    if (Ai.hint != null && c.mounted) {
      snack(c, Ai.hint!);
      Ai.hint = null;
    }
    return r;
  } on SkinException catch (e) {
    if (c.mounted) snack(c, e.message);
  } catch (e) {
    if (c.mounted) snack(c, 'Fehler: $e');
  } finally {
    nav.pop();
  }
  return null;
}

Future<String?> askText(BuildContext c, String title, [String hint = '']) {
  final ctl = TextEditingController();
  return showDialog<String>(
    context: c,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctl, autofocus: true, decoration: InputDecoration(hintText: hint)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Abbrechen')),
        FilledButton(onPressed: () => Navigator.pop(d, ctl.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

String safe(String s) => s.trim().replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_');

Future<void> shareBytes(String name, Uint8List b, String mime) async {
  final f = File('${(await getTemporaryDirectory()).path}/$name');
  await f.writeAsBytes(b);
  await Share.shareXFiles([XFile(f.path, mimeType: mime)]);
}

void openSkin(BuildContext c, Pix p, String n) => Navigator.push(c, MaterialPageRoute(builder: (_) => SkinPage(Doc(p), n)));

// ───────────── Startseite ─────────────

class Home extends StatelessWidget {
  const Home({super.key});

  Widget _b(IconData i, String t, VoidCallback? f) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: FilledButton.icon(
          icon: Icon(i),
          label: Text(t),
          onPressed: f,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54), alignment: Alignment.centerLeft),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = context;
    const h = TextStyle(fontSize: 20, fontWeight: FontWeight.w700);
    return Scaffold(
      appBar: AppBar(title: const Text('SkinForge')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Skins', style: h),
        const SizedBox(height: 10),
        _b(Icons.add, 'Neuer Skin', () => openSkin(c, defaultSkin(), 'neu')),
        _b(Icons.upload_file, 'Eigenen Skin hochladen', () async {
          final r = await pickSkin(c);
          if (r != null && c.mounted) openSkin(c, r.$1, r.$2);
        }),
        _b(Icons.person_search, 'Skin eines Spielers laden', () async {
          final n = await askText(c, 'Minecraft-Benutzername');
          if (n == null || n.isEmpty || !c.mounted) return;
          final p = await busy(c, () => mojangSkin(n));
          if (p != null && c.mounted) openSkin(c, p, n);
        }),
        ValueListenableBuilder<int>(
          valueListenable: Ai.cool,
          builder: (_, s, __) => _b(Icons.auto_awesome, s > 0 ? 'KI-Skin (bereit in $s s)' : 'KI-Skin erstellen', s > 0
              ? null
              : () async {
                  final d = await askText(c, 'Beschreibe deinen Skin', 'z. B. Ritter mit blauer Rüstung');
                  if (d == null || d.isEmpty || !c.mounted) return;
                  final p = await busy(c, () => aiSkin(d));
                  if (p != null && c.mounted) openSkin(c, p, 'ki');
                }),
        ),
        const SizedBox(height: 14),
        const Text('Texture Packs', style: h),
        const SizedBox(height: 10),
        _b(Icons.folder_zip, 'Neues Texture Pack erstellen', () async {
          final n = await askText(c, 'Name des Texture Packs');
          if (n == null || n.isEmpty || !c.mounted) return;
          final pk = Pack(n, '26.3', [Tex('assets/minecraft/textures/block/stone.png', solid(16, 0xFF808080))]);
          Navigator.push(c, MaterialPageRoute(builder: (_) => PackPage(pk)));
        }),
        _b(Icons.upload_file, 'Texture Pack laden (.zip)', () async {
          final pk = await pickPack(c);
          if (pk != null && c.mounted) Navigator.push(c, MaterialPageRoute(builder: (_) => PackPage(pk)));
        }),
        const SizedBox(height: 12),
        const Text(
          'Hinweise: Skins anderer Spieler nur privat bearbeiten und nicht unter deren Namen veröffentlichen. '
          'KI-Bilder (Pollinations) können Rechte Dritter berühren – vor einer Veröffentlichung Lizenz prüfen. '
          'Minecraft ist eine Marke von Mojang/Microsoft; SkinForge ist inoffiziell.',
          style: TextStyle(fontSize: 12),
        ),
      ]),
    );
  }
}

// ───────────── Skin-Seite (Editor + 3D) ─────────────

class SkinPage extends StatefulWidget {
  final Doc doc;
  final String name;
  const SkinPage(this.doc, this.name, {super.key});
  @override
  State<SkinPage> createState() => _SkinPageState();
}

class _SkinPageState extends State<SkinPage> {
  int tab = 0;
  final fc = allFaces();

  @override
  Widget build(BuildContext context) {
    final d = widget.doc;
    return Scaffold(
      appBar: AppBar(title: Text(widget.name), actions: [
        AnimatedBuilder(
          animation: d,
          builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(icon: const Icon(Icons.undo), onPressed: d.canUndo ? d.undo : null),
            IconButton(icon: const Icon(Icons.redo), onPressed: d.canRedo ? d.redo : null),
          ]),
        ),
        IconButton(
          icon: const Icon(Icons.folder_open),
          tooltip: 'Skin laden',
          onPressed: () async {
            final r = await pickSkin(context);
            if (r != null) d.reset(r.$1);
          },
        ),
        IconButton(
          icon: const Icon(Icons.share),
          tooltip: 'Als PNG exportieren',
          onPressed: () => shareBytes('skin_${safe(widget.name)}_${DateTime.now().millisecondsSinceEpoch}.png', pixToPng(d.pix), 'image/png'),
        ),
      ]),
      body: IndexedStack(index: tab, sizing: StackFit.expand, children: [
        Editor(d, faces: fc),
        TickerMode(enabled: tab == 1, child: SkinView(d)),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.brush), label: 'Editor'),
          NavigationDestination(icon: Icon(Icons.view_in_ar), label: '3D-Vorschau'),
        ],
      ),
    );
  }
}

// ───────────── Pixel-Editor ─────────────

class Editor extends StatefulWidget {
  final Doc doc;
  final List<List<int>>? faces; // UV-Flächen (für Umrisse und Spiegeln); null = Textur
  const Editor(this.doc, {this.faces, super.key});
  @override
  State<Editor> createState() => _EditorState();
}

class _EditorState extends State<Editor> {
  static const mc = [
    0xFFF9FFFE, 0xFFF9801D, 0xFFC74EBD, 0xFF3AB3DA, 0xFFFED83D, 0xFF80C71F, 0xFFF38BAA, 0xFF474F52,
    0xFF9D9D97, 0xFF169C9C, 0xFF8932B8, 0xFF3C44AA, 0xFF835432, 0xFF5E7C16, 0xFFB02E26, 0xFF1D1D21,
  ];
  static const tools = <String, (IconData, String)>{
    'pinsel': (Icons.brush, 'Pinsel'),
    'radierer': (Icons.auto_fix_normal, 'Radierer'),
    'pipette': (Icons.colorize, 'Pipette'),
    'fuellen': (Icons.format_color_fill, 'Füllen'),
    'hand': (Icons.pan_tool, 'Hand'),
  };
  String tool = 'pinsel';
  int color = 0xFF3A7D44, pointers = 0, lx = -1, ly = -1;
  bool mirror = false, snapped = false;
  final recent = <int>[];
  ui.Image? im;
  final hex = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.doc.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.doc.removeListener(_load);
    hex.dispose();
    super.dispose();
  }

  void _load() => toUi(widget.doc.pix).then((i) {
        if (!mounted) {
          i.dispose();
          return;
        }
        final o = im;
        setState(() => im = i);
        o?.dispose();
      });

  void _down(Offset o, Size s) {
    pointers++;
    if (pointers != 1 || tool == 'hand') return;
    snapped = false;
    lx = ly = -1;
    if (tool == 'pinsel' || tool == 'fuellen') {
      recent.remove(color);
      recent.insert(0, color);
      if (recent.length > 10) recent.removeLast();
      setState(() {});
    }
    _at(o, s, true);
  }

  void _move(Offset o, Size s) {
    if (pointers == 1 && tool != 'hand') _at(o, s, false);
  }

  void _up() => pointers = max(0, pointers - 1);

  void _at(Offset o, Size s, bool start) {
    final d = widget.doc, p = d.pix;
    final x = (o.dx / s.width * p.w).floor(), y = (o.dy / s.height * p.h).floor();
    if (x < 0 || y < 0 || x >= p.w || y >= p.h) return;
    if (tool == 'pipette') {
      final c = p.get(x, y);
      if (c >> 24 != 0) {
        setState(() {
          color = c | 0xFF000000;
          tool = 'pinsel';
        });
      }
      return;
    }
    if (tool == 'fuellen') {
      if (start) _fill(x, y);
      return;
    }
    final c = tool == 'radierer' ? 0 : color;
    _line(lx < 0 ? x : lx, ly < 0 ? y : ly, x, y, (a, b) {
      _one(a, b, c);
      if (mirror) _one(_mx(a, b), b, c);
    });
    lx = x;
    ly = y;
    d.touch();
  }

  void _one(int a, int b, int c) {
    final d = widget.doc;
    if (d.pix.get(a, b) == c) return;
    if (!snapped) {
      d.snap();
      snapped = true;
    }
    d.pix.set(a, b, c);
  }

  int _mx(int x, int y) {
    final fs = widget.faces;
    if (fs == null) return widget.doc.pix.w - 1 - x;
    for (final f in fs) {
      if (x >= f[0] && x < f[0] + f[2] && y >= f[1] && y < f[1] + f[3]) return 2 * f[0] + f[2] - 1 - x;
    }
    return x;
  }

  void _line(int x0, int y0, int x1, int y1, void Function(int, int) f) {
    final dx = (x1 - x0).abs(), dy = -(y1 - y0).abs(), sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
    var err = dx + dy;
    while (true) {
      f(x0, y0);
      if (x0 == x1 && y0 == y1) break;
      final e2 = 2 * err;
      if (e2 >= dy) {
        err += dy;
        x0 += sx;
      }
      if (e2 <= dx) {
        err += dx;
        y0 += sy;
      }
    }
  }

  void _fill(int x, int y) {
    final d = widget.doc, p = d.pix, t = p.get(x, y);
    if (t == color) return;
    d.snap();
    final st = <int>[x + y * p.w];
    while (st.isNotEmpty) {
      final i = st.removeLast(), cx = i % p.w, cy = i ~/ p.w;
      if (p.get(cx, cy) != t) continue;
      p.set(cx, cy, color);
      if (cx > 0) st.add(i - 1);
      if (cx < p.w - 1) st.add(i + 1);
      if (cy > 0) st.add(i - p.w);
      if (cy < p.h - 1) st.add(i + p.w);
    }
    d.touch();
  }

  Widget _sw(int c) => GestureDetector(
        onTap: () => setState(() {
          color = c;
          hex.text = (c & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
        }),
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(color: Color(c), border: Border.all(color: c == color ? Colors.white : Colors.black54, width: c == color ? 3 : 1)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final p = widget.doc.pix;
    return Column(children: [
      SizedBox(
        height: 54,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.all(8), children: [
          for (final e in tools.entries)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                avatar: Icon(e.value.$1, size: 18),
                label: Text(e.value.$2),
                selected: tool == e.key,
                onSelected: (_) => setState(() => tool = e.key),
              ),
            ),
          FilterChip(avatar: const Icon(Icons.flip, size: 18), label: const Text('Spiegeln'), selected: mirror, onSelected: (v) => setState(() => mirror = v)),
        ]),
      ),
      Expanded(
        child: Center(
          child: AspectRatio(
            aspectRatio: p.w / p.h,
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 20,
              panEnabled: tool == 'hand',
              child: LayoutBuilder(builder: (c, k) {
                final s = Size(k.maxWidth, k.maxHeight);
                return Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) => _down(e.localPosition, s),
                  onPointerMove: (e) => _move(e.localPosition, s),
                  onPointerUp: (_) => _up(),
                  onPointerCancel: (_) => _up(),
                  child: CustomPaint(size: s, painter: _PixPainter(im, p.w, p.h, widget.faces)),
                );
              }),
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Column(children: [
          Wrap(spacing: 4, runSpacing: 4, children: [for (final c in [...recent, ...mc]) _sw(c)]),
          const SizedBox(height: 6),
          Row(children: [
            Container(width: 28, height: 28, margin: const EdgeInsets.only(right: 10), color: Color(color)),
            SizedBox(
              width: 130,
              child: TextField(
                controller: hex,
                maxLength: 7,
                decoration: const InputDecoration(prefixText: '#', hintText: 'RRGGBB', isDense: true, counterText: ''),
                onSubmitted: (t) {
                  final s = t.replaceAll('#', '');
                  final v = int.tryParse(s, radix: 16);
                  if (v != null && s.length == 6) setState(() => color = 0xFF000000 | v);
                },
              ),
            ),
          ]),
        ]),
      ),
    ]);
  }
}

class _PixPainter extends CustomPainter {
  final ui.Image? im;
  final int w, h;
  final List<List<int>>? faces;
  _PixPainter(this.im, this.w, this.h, this.faces);

  @override
  void paint(Canvas canvas, Size s) {
    final cw = s.width / w, ch = s.height / h;
    canvas.drawRect(Offset.zero & s, Paint()..color = const Color(0xFFFFFFFF));
    final grey = Path();
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if ((x + y).isEven) grey.addRect(Rect.fromLTWH(x * cw, y * ch, cw, ch));
      }
    }
    canvas.drawPath(grey, Paint()..color = const Color(0xFFD8D8D8));
    if (im != null) {
      canvas.drawImageRect(im!, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Offset.zero & s, Paint()..filterQuality = FilterQuality.none);
    }
    final line = Paint()
      ..color = const Color(0x55000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .7;
    if (faces == null) {
      for (var x = 0; x <= w; x++) {
        canvas.drawLine(Offset(x * cw, 0), Offset(x * cw, s.height), line);
      }
      for (var y = 0; y <= h; y++) {
        canvas.drawLine(Offset(0, y * ch), Offset(s.width, y * ch), line);
      }
    } else {
      for (final f in faces!) {
        canvas.drawRect(Rect.fromLTWH(f[0] * cw, f[1] * ch, f[2] * cw, f[3] * ch), line);
      }
    }
  }

  @override
  bool shouldRepaint(_PixPainter o) => true;
}

// ───────────── 3D-Vorschau ─────────────

class SkinView extends StatefulWidget {
  final Doc doc;
  const SkinView(this.doc, {super.key});
  @override
  State<SkinView> createState() => _SkinViewState();
}

class _SkinViewState extends State<SkinView> with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();
  final sw = Stopwatch()..start();
  ui.Image? im;
  double yaw = .6, pitch = .2, zoom = 1, z0 = 1, last = 0;
  int anim = 0, bg = 0;
  bool turn = true, night = false;
  static const names = ['Idle', 'Gehen', 'Rennen', 'Winken', 'Springen'];

  @override
  void initState() {
    super.initState();
    widget.doc.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.doc.removeListener(_load);
    c.dispose();
    super.dispose();
  }

  void _load() => toUi(widget.doc.pix).then((i) {
        if (!mounted) {
          i.dispose();
          return;
        }
        final o = im;
        setState(() => im = i);
        o?.dispose();
      });

  @override
  Widget build(BuildContext context) => Column(children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: (_) => z0 = zoom,
            onScaleUpdate: (d) => setState(() {
              yaw += d.focalPointDelta.dx * .012;
              pitch = min(1.4, max(-1.4, pitch + d.focalPointDelta.dy * .012));
              zoom = min(4.0, max(.5, z0 * d.scale));
            }),
            child: AnimatedBuilder(
              animation: c,
              builder: (_, __) {
                final t = sw.elapsedMilliseconds / 1000;
                if (turn) yaw += min(.1, t - last) * .8;
                last = t;
                if (im == null) return const Center(child: CircularProgressIndicator());
                return CustomPaint(size: Size.infinite, painter: _P3(im!, t, yaw, pitch, zoom, anim, bg, night));
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, alignment: WrapAlignment.center, children: [
            for (var i = 0; i < names.length; i++) ChoiceChip(label: Text(names[i]), selected: anim == i, onSelected: (_) => setState(() => anim = i)),
            FilterChip(label: const Text('Drehen'), selected: turn, onSelected: (v) => setState(() => turn = v)),
            FilterChip(label: const Text('Nacht'), selected: night, onSelected: (v) => setState(() => night = v)),
            DropdownButton<int>(
              value: bg,
              items: const [
                DropdownMenuItem(value: 0, child: Text('Studio')),
                DropdownMenuItem(value: 1, child: Text('Gras')),
                DropdownMenuItem(value: 2, child: Text('Himmel')),
              ],
              onChanged: (v) => setState(() => bg = v ?? 0),
            ),
          ]),
        ),
      ]);
}

class _Q {
  final List<Offset> p;
  final double z, b;
  final List<int> uv;
  _Q(this.p, this.z, this.uv, this.b);
}

/// Software-Pipeline: Quader mit Außenschicht → gedreht, projiziert, sortiert, als Textur-Dreiecke gezeichnet
class _P3 extends CustomPainter {
  final ui.Image im;
  final double t, yaw, pitch, zoom;
  final int anim, bg;
  final bool night;
  _P3(this.im, this.t, this.yaw, this.pitch, this.zoom, this.anim, this.bg, this.night);

  /// Pose: Winkel (x, y, z) je Körperteil + Höhenversatz
  (Map<String, List<double>>, double) _pose() {
    final a = {for (final p in parts) p.n: [0.0, 0.0, 0.0]};
    var dy = 0.0;
    switch (anim) {
      case 0: // Idle: leichtes Atmen
        final b = sin(t * 2);
        a['armR']![2] = -.06 - .03 * b;
        a['armL']![2] = .06 + .03 * b;
        a['head']![1] = sin(t * .8) * .3;
        dy = b * .2;
      case 1: // Gehen / Rennen
      case 2:
        final f = anim == 1 ? 5.0 : 9.0, k = anim == 1 ? .7 : 1.1, sg = sin(t * f) * k;
        a['legR']![0] = sg;
        a['legL']![0] = -sg;
        a['armL']![0] = sg;
        a['armR']![0] = -sg;
        dy = anim == 2 ? cos(t * f * 2).abs() * .8 : 0.0;
      case 3: // Winken
        a['armR']![2] = -2.6 + sin(t * 8) * .25;
        a['armL']![2] = .06;
        a['head']![1] = sin(t * 2) * .2;
      default: // Springen
        final j = max(0.0, sin(t * 4));
        dy = j * 7;
        a['armR']![2] = -.3 - j;
        a['armL']![2] = .3 + j;
        a['legR']![0] = -.5 * j;
        a['legL']![0] = .5 * j;
    }
    return (a, dy);
  }

  List<double> _rot(List<double> p, P pa, List<double> a) {
    var x = p[0] - pa.px, y = p[1] - pa.py, z = p[2] - pa.pz;
    var c = cos(a[0]), s = sin(a[0]), q = y * c - z * s;
    z = y * s + z * c;
    y = q;
    c = cos(a[1]);
    s = sin(a[1]);
    q = x * c + z * s;
    z = -x * s + z * c;
    x = q;
    c = cos(a[2]);
    s = sin(a[2]);
    q = x * c - y * s;
    y = x * s + y * c;
    x = q;
    return [x + pa.px, y + pa.py, z + pa.pz];
  }

  Color _shade(double v) {
    final g = (v * 255).round();
    return night ? Color.fromARGB(255, (g * .45).round(), (g * .55).round(), (g * .85).round()) : Color.fromARGB(255, g, g, g);
  }

  @override
  void paint(Canvas canvas, Size s) {
    canvas.drawRect(
      Offset.zero & s,
      Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(0, s.height), bg == 0 ? const [Color(0xFF4A505A), Color(0xFF1B1E23)] : const [Color(0xFF7DB8F0), Color(0xFFDDF0FF)]),
    );
    if (bg == 1) canvas.drawRect(Rect.fromLTWH(0, s.height * .66, s.width, s.height * .34), Paint()..color = const Color(0xFF4C8C2B));
    final sc = min(s.height / 46, s.width / 34) * zoom, ox = s.width / 2, oy = s.height / 2;
    final cyw = cos(yaw), syw = sin(yaw), cp = cos(pitch), sp = sin(pitch);
    List<double> rotG(double x, double y, double z) {
      final x1 = x * cyw + z * syw, z1 = -x * syw + z * cyw;
      return [x1, y * cp - z1 * sp, y * sp + z1 * cp];
    }

    final (pose, dy) = _pose();
    final qs = <_Q>[];
    for (var layer = 0; layer < 2; layer++) {
      for (final pa in parts) {
        final e = layer == 0 ? 0.0 : pa.e;
        final fr = layer == 0 ? faces(pa.u, pa.v, pa.w, pa.h, pa.d) : faces(pa.ou, pa.ov, pa.w, pa.h, pa.d);
        for (var f = 0; f < 6; f++) {
          final pts = <Offset>[];
          var zs = 0.0;
          for (final c in corners(f, pa.x - e, pa.y - e, pa.z - e, pa.x + pa.w + e, pa.y + pa.h + e, pa.z + pa.d + e)) {
            final q = _rot(c, pa, pose[pa.n]!);
            final g = rotG(q[0], q[1] + dy - 16, q[2]);
            final k = 80 / (80 - g[2]);
            pts.add(Offset(ox + g[0] * sc * k, oy - g[1] * sc * k));
            zs += g[2];
          }
          final cr = (pts[1].dx - pts[0].dx) * (pts[3].dy - pts[0].dy) - (pts[1].dy - pts[0].dy) * (pts[3].dx - pts[0].dx);
          if (cr <= 0) continue; // Rückseite
          final n = rotG(_nrm[f][0], _nrm[f][1], _nrm[f][2]);
          final lit = min(1.0, max(0.0, n[0] * .35 + n[1] * .75 + n[2] * .55));
          qs.add(_Q(pts, zs / 4, fr[f], .6 + .4 * lit));
        }
      }
    }
    qs.sort((a, b) => a.z.compareTo(b.z)); // hinten zuerst
    final pos = <Offset>[], tc = <Offset>[], col = <Color>[];
    for (final q in qs) {
      final x0 = q.uv[0].toDouble(), y0 = q.uv[1].toDouble(), x1 = x0 + q.uv[2], y1 = y0 + q.uv[3];
      final t4 = [Offset(x0, y0), Offset(x1, y0), Offset(x1, y1), Offset(x0, y1)];
      final c = _shade(q.b);
      for (final i in const [0, 1, 2, 0, 2, 3]) {
        pos.add(q.p[i]);
        tc.add(t4[i]);
        col.add(c);
      }
    }
    if (pos.isEmpty) return;
    final paint = Paint()
      ..shader = ui.ImageShader(im, TileMode.clamp, TileMode.clamp, Float64List.fromList([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]), filterQuality: FilterQuality.none);
    canvas.drawVertices(ui.Vertices(ui.VertexMode.triangles, pos, textureCoordinates: tc, colors: col), BlendMode.modulate, paint);
  }

  @override
  bool shouldRepaint(_P3 o) => true;
}

// ───────────── Texture-Pack-Seiten ─────────────

class PackPage extends StatefulWidget {
  final Pack pack;
  const PackPage(this.pack, {super.key});
  @override
  State<PackPage> createState() => _PackPageState();
}

class _PackPageState extends State<PackPage> {
  Pack get p => widget.pack;

  Future<void> _edit(Tex t) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => TexPage(t)));
    t.thumb = null;
    if (mounted) setState(() {});
  }

  Future<void> _add() async {
    final nameC = TextEditingController(text: 'block/neu'), descC = TextEditingController();
    var res = 16;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Textur hinzufügen'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nameC, decoration: const InputDecoration(labelText: 'Pfad (block/…, item/…)')),
            TextField(controller: descC, decoration: const InputDecoration(labelText: 'KI-Beschreibung (optional)')),
            const SizedBox(height: 10),
            Wrap(spacing: 8, children: [for (final r in [16, 32, 64]) ChoiceChip(label: Text('$r px'), selected: res == r, onSelected: (_) => set(() => res = r))]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Hinzufügen')),
          ],
        ),
      ),
    );
    var rel = nameC.text.trim().replaceAll(RegExp(r'[^A-Za-z0-9_/]'), '_').replaceAll(RegExp(r'^/+'), '');
    if (ok != true || rel.isEmpty || !mounted) return;
    Pix px = solid(res, 0xFF808080);
    final desc = descC.text.trim();
    if (desc.isNotEmpty) px = await busy(context, () => aiTexture(desc, res)) ?? px;
    if (rel.endsWith('.png')) rel = rel.substring(0, rel.length - 4);
    if (mounted) setState(() => p.tex.add(Tex('assets/minecraft/textures/$rel.png', px)));
  }

  Future<void> _act(String a, Tex t) async {
    if (a == 'edit') return _edit(t);
    if (a == 'del') {
      setState(() => p.tex.remove(t));
      return;
    }
    Pix? n;
    if (a == 'ai') {
      final d = await askText(context, 'KI-Beschreibung', 'z. B. Diamanterz');
      if (d == null || d.isEmpty || !mounted) return;
      n = await busy(context, () => aiTexture(d, t.pix.w));
    } else {
      final r = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
      if (r == null || r.files.first.bytes == null || !mounted) return;
      n = await busy(context, () => decodePix(r.files.first.bytes!));
    }
    if (n != null && mounted) {
      final px = n;
      setState(() {
        t.pix = px;
        t.thumb = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(p.name), actions: [
          IconButton(icon: const Icon(Icons.add), tooltip: 'Textur hinzufügen', onPressed: _add),
          IconButton(
            icon: const Icon(Icons.archive),
            tooltip: 'Als ZIP exportieren',
            onPressed: () => shareBytes('texturepack_${safe(p.name)}_${p.version}.zip', exportZip(p), 'application/zip'),
          ),
        ]),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              const Text('Zielversion: '),
              DropdownButton<String>(
                value: p.version,
                items: [for (final v in packFormats.keys) DropdownMenuItem(value: v, child: Text(v))],
                onChanged: (v) => setState(() => p.version = v ?? p.version),
              ),
              const Spacer(),
              Text('Format ${packFormats[p.version]![0]}.${packFormats[p.version]![1]}'),
            ]),
          ),
          Expanded(
            child: p.tex.isEmpty
                ? const Center(child: Text('Noch keine Texturen – tippe oben auf +'))
                : ListView.builder(
                    itemCount: p.tex.length,
                    itemBuilder: (c, i) {
                      final t = p.tex[i];
                      t.thumb ??= pixToPng(t.pix);
                      return ListTile(
                        leading: Image.memory(t.thumb!, width: 48, height: 48, fit: BoxFit.contain, filterQuality: FilterQuality.none),
                        title: Text(t.path.replaceFirst('assets/minecraft/textures/', '')),
                        subtitle: Text('${t.pix.w}×${t.pix.h}'),
                        onTap: () => _edit(t),
                        trailing: PopupMenuButton<String>(
                          onSelected: (a) => _act(a, t),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
                            PopupMenuItem(value: 'ai', child: Text('KI-generieren')),
                            PopupMenuItem(value: 'rep', child: Text('Ersetzen (Bild)')),
                            PopupMenuItem(value: 'del', child: Text('Löschen')),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ]),
      );
}

class TexPage extends StatefulWidget {
  final Tex t;
  const TexPage(this.t, {super.key});
  @override
  State<TexPage> createState() => _TexPageState();
}

class _TexPageState extends State<TexPage> {
  late final Doc doc = Doc(widget.t.pix);

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.t.path.split('/').last), actions: [
          AnimatedBuilder(
            animation: doc,
            builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(icon: const Icon(Icons.undo), onPressed: doc.canUndo ? doc.undo : null),
              IconButton(icon: const Icon(Icons.redo), onPressed: doc.canRedo ? doc.redo : null),
            ]),
          ),
          IconButton(
            icon: const Icon(Icons.grid_on),
            tooltip: 'Nahtlos machen',
            onPressed: () {
              doc.snap();
              makeSeamless(doc.pix, force: true);
              doc.touch();
            },
          ),
        ]),
        body: Editor(doc),
      );
}
