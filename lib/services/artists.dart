import 'song_matcher.dart';

/// The same person or band written several ways (scripts, romanisation,
/// simplified / traditional Chinese). Members who also release on their own
/// (Ayase in YOASOBI, ikura) stay separate.
const artistAliases = <List<String>>[
  ['米津玄師', 'Kenshi Yonezu'],
  ['李榮浩', '李荣浩', 'Ronghao Li', 'Li Ronghao'],
  ['韋禮安', '韦礼安', 'WeiBird', 'Wei Li-an'],
  ['周杰倫', '周杰伦', 'Jay Chou'],
  ['林俊傑', '林俊杰', 'JJ Lin'],
  ['鄧紫棋', '邓紫棋', 'G.E.M.'],
  ['五月天', 'Mayday'],
  ['蔡依林', 'Jolin Tsai'],
  ['陳奕迅', '陈奕迅', 'Eason Chan'],
  ['告五人', 'Accusefive'],
  ['田馥甄', 'Hebe Tien'],
  ['孫燕姿', '孙燕姿', 'Stefanie Sun'],
  ['張惠妹', '张惠妹', 'A-Mei', 'aMEI'],
  ['盧廣仲', '卢广仲', 'Crowd Lu'],
  ['八三夭', '831'],
  ['宇多田ヒカル', 'Hikaru Utada', 'Utada Hikaru'],
  ['ヨルシカ', 'Yorushika'],
  ['ずっと真夜中でいいのに。', 'ZUTOMAYO', 'ずとまよ'],
  ['藤井風', 'Fujii Kaze'],
  ['Official髭男dism', 'Official HIGE DANdism', 'Higedan', 'ヒゲダン'],
  ['優里', 'Yuuri'],
  ['あいみょん', 'Aimyon'],
  ['幾田りら', 'Lilas Ikuta', 'Lilas'],
  ['須田景凪', 'Keina Suda'],
  ['米米CLUB', 'Kome Kome Club'],
  ['緑黄色社会', 'Ryokuoushoku Shakai'],
  ['ツユ', 'TUYU'],
  ['キタニタツヤ', 'Tatsuya Kitani'],
  ['菅田将暉', 'Masaki Suda'],
  ['中島みゆき', 'Miyuki Nakajima'],
  ['椎名林檎', 'Sheena Ringo'],
  ['東京事変', 'Tokyo Jihen'],
  ['back number', 'バックナンバー'],
  ['斉藤和義', 'Kazuyoshi Saito'],
  ['美波', 'Minami'],
  ['花譜', 'KAF'],
  ['理芽', 'RIM'],
  ['ヰ世界情緒', 'Isekaijoucho'],
  ['BTS', '방탄소년단', 'Bangtan Boys'],
  ['IU', '아이유'],
  ['BLACKPINK', '블랙핑크'],
];

/// Folded spelling → its group's usual name (built-in tables).
final Map<String, String> _builtIn = {
  for (final group in artistAliases)
    for (final name in group) _key(name): group.first,
};

/// Spelling-free key: width, case, punctuation, and the order of Latin words
/// (「Li Ronghao」 = 「Ronghao Li」).
String _key(String name) {
  final spaced = spacedText(name);
  final words = spaced.split(' ').where((w) => w.isNotEmpty).toList();
  final latin = words.isNotEmpty && words.every((w) => !RegExp(r'[぀-ヿ㐀-鿿가-힯]').hasMatch(w));
  if (latin && words.length > 1) return (words..sort()).join();
  return foldText(name);
}

final _split = RegExp(
  r'\s*(?:,|;|&|＆|、|，|×|\s[xX]\s|/|／|\bfeat\.?|\bft\.?|\bfeaturing\b|\bwith\b|\bvs\.?\b|\band\b)\s*',
  caseSensitive: false,
);

/// The names in a credit, in order, each once:
/// 「YOASOBI, YOASOBI, Ayase」→ [YOASOBI, Ayase];
/// 「DECO*27 feat. 初音ミク」→ [DECO*27, 初音ミク]; 「YOASOBI - Topic」→ [YOASOBI].
List<String> splitArtists(String raw) {
  final out = <String>[];
  final seen = <String>{};
  final cleaned = raw.replaceAll(RegExp(r'\s*-\s*topic$', caseSensitive: false), '').replaceAll(RegExp(r'\bVEVO\b'), '');
  for (final part in cleaned.split(_split)) {
    final name = part.trim();
    if (name.isEmpty || name == '未知演出者') continue;
    if (seen.add(_key(name))) out.add(name);
  }
  return out;
}

/// Names the user changed in OuOPlayer (歌手頁 →「重新命名歌手」): the
/// artist's usual name → the user's name. Kept in the settings table (so it
/// is in backups); the song files are never touched.
class ArtistRenames {
  static Map<String, String> _names = const {};
  static Map<String, String> _byKey = const {};
  static Map<String, List<String>> _spellings = const {};

  /// Original name → new name.
  static Map<String, String> get all => _names;

  static void set(Map<String, String> names) {
    _names = Map.unmodifiable(names);
    _byKey = {for (final e in names.entries) _key(e.key): e.value};
    final groups = <String, Set<String>>{};
    for (final e in names.entries) {
      groups.putIfAbsent(foldText(e.value), () => {foldText(e.value)}).add(foldText(e.key));
    }
    _spellings = {
      for (final g in groups.values)
        for (final n in g) n: g.toList(),
    };
  }

  static String? of(String usualName) => _byKey[_key(usualName)];

  /// The table after renaming the artist shown as [from] to [to]: names that
  /// already led to [from] follow it, and naming it back drops the entry.
  /// Only the spelling may change too (「yoasobi」→「YOASOBI」).
  static Map<String, String> renamed(Map<String, String> names, String from, String to) {
    final out = <String, String>{};
    var found = false;
    for (final e in names.entries) {
      if (_key(e.value) == _key(from)) {
        found = true;
        if (e.key.trim() != to.trim()) out[e.key] = to;
      } else {
        out[e.key] = e.value;
      }
    }
    if (!found && from.trim() != to.trim()) out[from] = to;
    return out;
  }

  /// The table without the names that lead to [shown] (「還原原本的名字」).
  static Map<String, String> restored(Map<String, String> names, String shown) =>
      {for (final e in names.entries) if (_key(e.value) != _key(shown)) e.key: e.value};

  /// The original names behind [shown].
  static List<String> originals(String shown) => [for (final e in _names.entries) if (_key(e.value) == _key(shown)) e.key];
}

/// One artist as the library shows it.
class ArtistInfo {
  ArtistInfo(this.key, this.name);
  final String key;
  String name;
}

/// Turns credits into artists. Built-in spellings first, then pairs learnt
/// from the library itself: a credit like 「韋禮安 WeiBird」 teaches that
/// 「韋禮安」 and 「WeiBird」 are one artist.
class ArtistDirectory {
  ArtistDirectory(Iterable<String> credits) {
    // Learn bilingual names: a CJK half and a Latin half of one name.
    for (final credit in credits) {
      for (final name in splitArtists(credit)) {
        final cjk = name.replaceAll(RegExp(r"[A-Za-z0-9 .'\-*]+"), ' ').trim();
        final latin = name.replaceAll(RegExp(r"[^A-Za-z0-9 .'\-*]+"), ' ').trim();
        if (cjk.isEmpty || latin.isEmpty || cjk.contains(' ')) continue;
        final group = _canonical(cjk) ?? _canonical(latin) ?? cjk;
        _learnt[_key(cjk)] = group;
        _learnt[_key(latin)] = group;
        _learnt[_key(name)] = group;
      }
    }
  }

  final _learnt = <String, String>{};

  String? _canonical(String name) => _builtIn[_key(name)];

  /// The usual name for any spelling, or the user's own name for the artist.
  String canonical(String name) {
    final usual = _builtIn[_key(name)] ?? _learnt[_key(name)] ?? name.trim();
    return ArtistRenames.of(usual) ?? usual;
  }

  String keyOf(String name) => _key(canonical(name));

  /// The artists a song is credited to, as keys (for grouping).
  List<String> keysOf(String credit) => [for (final k in {for (final n in splitArtists(credit)) keyOf(n)}) k];

  /// The artist a song is listed under: the first one credited
  /// (「YOASOBI, Ayase」→ YOASOBI; 「DECO*27 feat. 初音ミク」→ DECO*27), in its
  /// usual spelling. Null for 「未知演出者」.
  String? primary(String credit) {
    final names = splitArtists(credit);
    return names.isEmpty ? null : canonical(names.first);
  }

  String? primaryKey(String credit) {
    final p = primary(credit);
    return p == null ? null : keyOf(p);
  }

  /// The artists a song is credited to, as their usual names.
  List<String> namesOf(String credit) {
    final seen = <String>{};
    return [
      for (final n in splitArtists(credit))
        if (seen.add(keyOf(n))) canonical(n),
    ];
  }
}

/// Folded spelling → every folded spelling of its group (for the matcher).
final Map<String, List<String>> _spellings = {
  for (final group in artistAliases)
    for (final name in group) foldText(name): [for (final n in group) foldText(n)],
};

/// Like [knownSpellings], from an already folded name.
List<String> knownSpellingsFolded(String folded) {
  final user = ArtistRenames._spellings[folded];
  if (user == null) return _spellings[folded] ?? const [];
  return {...user, for (final n in user) ...?_spellings[n], ...?_spellings[folded]}.toList();
}

/// Every spelling of [name] the built-in tables know (folded), for matching.
List<String> knownSpellings(String name) {
  final group = _builtIn[_key(name)];
  final out = <String>{...knownSpellingsFolded(foldText(name))};
  if (group != null) {
    for (final g in artistAliases) {
      if (g.first == group) out.addAll([for (final n in g) foldText(n)]);
    }
  }
  return out.toList();
}
