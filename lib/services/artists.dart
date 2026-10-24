import 'song_matcher.dart';

/// Vocal synthesizers (VOCALOID, UTAU, CeVIO, Synthesizer V…): listed as
/// artists, in their own section. Each line: the usual name first, then the
/// other spellings.
const virtualSingers = <List<String>>[
  ['初音ミク', 'Hatsune Miku', 'Miku', '初音未來', '初音未来'],
  ['鏡音リン', 'Kagamine Rin'],
  ['鏡音レン', 'Kagamine Len'],
  ['巡音ルカ', 'Megurine Luka'],
  ['KAITO'],
  ['MEIKO'],
  ['GUMI', 'Megpoid'],
  ['重音テト', 'Kasane Teto', 'Teto'],
  ['可不', 'KAFU'],
  ['星界', 'SEKAI'],
  ['裏命', 'RIME'],
  ['狐子', 'COKO'],
  ['羽累', 'HARU'],
  ['IA'],
  ['ONE', 'オネ'],
  ['flower', 'v flower', 'v4 flower'],
  ['歌愛ユキ', 'Kaai Yuki'],
  ['結月ゆかり', 'Yuzuki Yukari'],
  ['紲星あかり', 'Kizuna Akari'],
  ['音街ウナ', 'Otomachi Una'],
  ['小春六花', 'Koharu Rikka'],
  ['夏色花梨', 'Natsuki Karin'],
  ['花隈千冬', 'Hanakuma Chifuyu'],
  ['足立レイ', 'Adachi Rei'],
  ['雪歌ユフ', 'Yukika Yufu'],
  ['琴葉茜', 'Kotonoha Akane'],
  ['琴葉葵', 'Kotonoha Aoi'],
  ['東北きりたん', 'Tohoku Kiritan'],
  ['東北ずん子', 'Tohoku Zunko'],
  ['ずんだもん', 'Zundamon'],
  ['四国めたん', 'Shikoku Metan'],
  ['春日部つむぎ', 'Kasukabe Tsumugi'],
  ['冥鳴ひまり', 'Meimei Himari'],
  ['弦巻マキ', 'Tsurumaki Maki'],
  ['知声', 'Chis-A'],
  ['京町セイカ', 'Kyomachi Seika'],
  ['洛天依', 'Luo Tianyi'],
  ['言和', 'Yanhe'],
  ['乐正绫', '樂正綾', 'Yuezheng Ling'],
  ['乐正龙牙', 'Yuezheng Longya'],
  ['心华', '心華', 'Xin Hua'],
  ['徵羽摩柯', 'Zhiyu Moke'],
  ['墨清弦', 'Mo Qingxian'],
];

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
  ['ハチ'], // 米津玄師's VOCALOID name: kept apart, as he credits it apart
  ['BTS', '방탄소년단', 'Bangtan Boys'],
  ['IU', '아이유'],
  ['BLACKPINK', '블랙핑크'],
];

/// Folded spelling → its group's usual name (built-in tables).
final Map<String, String> _builtIn = {
  for (final group in [...virtualSingers, ...artistAliases])
    for (final name in group) _key(name): group.first,
};

final Set<String> _virtualKeys = {
  for (final group in virtualSingers)
    for (final name in group) _key(name),
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

/// One artist as the library shows it.
class ArtistInfo {
  ArtistInfo(this.key, this.name, {required this.virtual});
  final String key;
  String name;
  final bool virtual;
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

  /// The usual name for any spelling.
  String canonical(String name) => _builtIn[_key(name)] ?? _learnt[_key(name)] ?? name.trim();

  String keyOf(String name) => _key(canonical(name));

  bool isVirtual(String name) => _virtualKeys.contains(_key(canonical(name)));

  /// The artists a song is credited to, as keys (for grouping).
  List<String> keysOf(String credit) => [for (final k in {for (final n in splitArtists(credit)) keyOf(n)}) k];

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
  for (final group in [...virtualSingers, ...artistAliases])
    for (final name in group) foldText(name): [for (final n in group) foldText(n)],
};

/// Like [knownSpellings], from an already folded name.
List<String> knownSpellingsFolded(String folded) => _spellings[folded] ?? const [];

/// Every spelling of [name] the built-in tables know (folded), for matching.
List<String> knownSpellings(String name) {
  final group = _builtIn[_key(name)];
  if (group == null) return const [];
  for (final g in [...virtualSingers, ...artistAliases]) {
    if (g.first == group) return [for (final n in g) foldText(n)];
  }
  return const [];
}
