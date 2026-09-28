#!/usr/bin/env python3
"""Sense Corpus v1 generator — sense-annotated JSONL (S02 工作包 B).

与 golden-corpus 的关系：golden-v1.jsonl 只有 boundary+lemma 标注；本语料在
相同 schema 上扩展义项级标注，用于测「候选召回 → 义项消歧」链路的现状基线。

每个 target 字段：
  沿用 golden：surface, utf16_start, utf16_len, lemma, reading, pos_family,
               category, confidence（标注者对该义项判断的把握）
  扩展：expected_entry_id   — 期望命中的词典 entries.id（OOV 为 null）
        expected_sense_id   — 期望命中的 senses.id（OOV 为 null）
        expected_sense_fingerprint — glosses.source_fingerprint
              （jmdict-sense-fingerprint/1，含 sense_order，跨快照不稳定，
              仅作快照内审计参考；词典无 tomoshi 覆盖时可能为 null）
        ambiguity           — monosemous | polysemous | restricted | proper | oov
        auto_accept_expectation — accept（应可自动接受）| confirm（应进入确认）

ambiguity 口径（标注约定，非词典属性）：
  monosemous — 该 entry 在本词典内只有 1 个义项，且表面常见无同形 entry
  polysemous — 期望义项在同 entry 多义项 / 同表记多 entry 中需要上下文才能确定
  restricted — 义项或 entry 的选择受表记/读音限制约束
              （sense_form_restrictions / sense_reading_restrictions /
               同表记异读音多 entry，如 入る=はいる|いる、降る=ふる|くだる）
  proper     — 专名；词典内（東京）与词典外（田中）都覆盖
  oov        — 词典完全无该词条（expected_* = null）

验证约束：本脚本对随包词典 sqlite 执行只读校验——
  expected_entry_id 必须存在；expected_sense_id 必须属于该 entry；
  expected_sense_fingerprint 从 tomoshi gloss 回填（可能缺失→null）。
校验失败即中止，不会写出损坏 JSONL。

subset 划分：按句子的「主歧义层」分层（句内最严 target 决定分层，
优先级 oov > restricted > polysemous > proper > monosemous），每层内按
sentence_id 排序后每第 4 句进 validation（≈25%），其余进 dev。
validation 子集日后不参与调阈。

Run: python3 gen_sense_corpus.py   （在 fixture 目录内写 sense-v1.jsonl）
"""
import json, os, sqlite3, sys

def u16len(s):
    return len(s.encode("utf-16-le")) // 2

def dict_path():
    # fixture 目录 → Fixtures → OboeInfrastructureTests → Tests → OboeCore
    # → Packages → repo root
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.sep.join(here.split(os.sep)[:-6])
    return os.path.join(
        repo, "OboeApp", "Resources", "Dictionary", "japanese-dictionary.sqlite")

# (surface, lemma, reading, pos_family, category,
#  entry_id|None, sense_id|None, ambiguity, auto_accept, gloss_hint)
def T(surface, lemma, reading, pos, cat, eid, sid, amb, acc, hint):
    return (surface, lemma, reading, pos, cat, eid, sid, amb, acc, hint)

# ------------------- 语料本体 -------------------
S = [
# ===== A. 上がる/上る/下がる 系（同表记不同义项的对照组）=====
("sc001","最近、値段が上がった。",[
  T("値段","値段","ねだん","noun","noun",1600160,74970,"monosemous","accept","price"),
  T("上がった","上がる","あがる","v5","poly-verb",1352290,42420,"polysemous","confirm","increase (price)")]),
("sc002","さっきまで降っていた雨が上がった。",[
  T("降っていた","降る","ふる","v5","homograph-entry",1282790,33508,"restricted","confirm","fall (rain); ふる-reading entry"),
  T("雨","雨","あめ","noun","poly-noun",1171900,19479,"polysemous","confirm","rain"),
  T("上がった","上がる","あがる","v5","poly-verb",1352290,42427,"polysemous","confirm","stop (rain)")]),
("sc003","彼は舞台で上がってしまった。",[
  T("舞台","舞台","ぶたい","noun","poly-noun",1499150,61555,"polysemous","confirm","stage"),
  T("上がって","上がる","あがる","v5","poly-verb",1352290,42431,"polysemous","confirm","get nervous/stage fright"),
  T("しまった","仕舞う","しまう","v5","aux-chain",1305380,36375,"polysemous","confirm","aux-v do accidentally")]),
("sc004","今年の給料は上がらなかった。",[
  T("今年","今年","ことし","noun","time",1579130,71677,"monosemous","accept","this year"),
  T("給料","給料","きゅうりょう","noun","noun",1230360,26922,"monosemous","accept","salary"),
  T("上がらなかった","上がる","あがる","v5","poly-verb",1352290,42420,"polysemous","confirm","increase (salary)")]),
("sc005","日が昇るのを眺めた。",[
  T("昇る","上る","のぼる","v5","restricted-form",1352570,42505,"restricted","confirm","rise (sun); forms 上る/昇る"),
  T("眺めた","眺める","ながめる","v1","poly-verb",1428830,52458,"polysemous","confirm","gaze at")]),
("sc006","彼は黙って階段を上った。",[
  T("階段","階段","かいだん","noun","noun",1203090,23364,"monosemous","accept","stairs"),
  T("上った","上る","のぼる","v5","restricted-form",1352570,42504,"restricted","confirm","ascend; forms 上る/登る (昇る excluded)")]),
("sc007","ガソリンの値段が下がった。",[
  T("下がった","下がる","さがる","v5","poly-verb",1184160,20984,"polysemous","confirm","come down (price)")]),
("sc008","彼女は怖くて一歩下がった。",[
  T("下がった","下がる","さがる","v5","poly-verb",1184160,20986,"polysemous","confirm","step back")]),
# ===== B. 掛かる/掛ける =====
("sc009","駅まで三十分掛かった。",[
  T("駅","駅","えき","noun","poly-noun",1175140,19867,"polysemous","confirm","station"),
  T("掛かった","掛かる","かかる","v5","poly-verb",1207590,23930,"polysemous","confirm","take (time)")]),
("sc010","壁に大きな絵が掛かっている。",[
  T("絵","絵","え","noun","poly-noun",1202270,23225,"polysemous","confirm","picture"),
  T("掛かっている","掛かる","かかる","v5","poly-verb",1207590,23931,"polysemous","confirm","hang")]),
("sc011","さっき母から電話が掛かってきた。",[
  T("電話","電話","でんわ","noun","poly-noun",1443840,54457,"polysemous","confirm","phone call"),
  T("掛かって","掛かる","かかる","v5","poly-verb",1207590,23942,"polysemous","confirm","get a call"),
  T("きた","来る","くる","vk","aux-chain",1547720,67680,"polysemous","confirm","aux-v come to be")]),
("sc012","古い車はエンジンが掛からない。",[
  T("車","車","くるま","noun","homograph-entry",1323080,38596,"polysemous","confirm","car; 車 also = 2773260"),
  T("掛からない","掛かる","かかる","v5","poly-verb",1207590,23934,"polysemous","confirm","start (engine)")]),
("sc013","出かける前に必ず鍵を掛ける。",[
  T("鍵","鍵","かぎ","noun","poly-noun",1260490,30744,"polysemous","confirm","key"),
  T("掛ける","掛ける","かける","v1","poly-verb",1207610,23961,"polysemous","confirm","secure (lock)")]),
("sc014","彼女は眼鏡を掛けて新聞を読んだ。",[
  T("眼鏡","眼鏡","めがね","noun","poly-noun",1577670,71447,"polysemous","confirm","glasses"),
  T("掛けて","掛ける","かける","v1","poly-verb",1207610,23954,"polysemous","confirm","put on (glasses)"),
  T("新聞","新聞","しんぶん","noun","noun",1362360,43815,"monosemous","accept","newspaper"),
  T("読んだ","読む","よむ","v5","poly-verb",1456360,56102,"polysemous","confirm","read")]),
("sc015","店の前で友達に電話を掛けた。",[
  T("店","店","みせ","noun","homograph-entry",1582120,72159,"polysemous","confirm","shop; 店 also = 1582125/2409230"),
  T("掛けた","掛ける","かける","v1","poly-verb",1207610,23955,"polysemous","confirm","make a call")]),
# ===== C. 取る/立つ/引く/切る =====
("sc016","彼は床の荷物を手に取った。",[
  T("荷物","荷物","にもつ","noun","poly-noun",1195430,22364,"polysemous","confirm","luggage"),
  T("取った","取る","とる","v5","poly-verb",1326980,39096,"polysemous","confirm","take/pick up")]),
("sc017","彼女は試験で満点を取った。",[
  T("試験","試験","しけん","noun","poly-noun",1312350,37279,"polysemous","confirm","exam"),
  T("満点","満点","まんてん","noun","poly-noun",1604340,75673,"polysemous","confirm","perfect score"),
  T("取った","取る","とる","v5","poly-verb",1326980,39098,"polysemous","confirm","get/win")]),
("sc018","大事な点はメモを取る習慣だ。",[
  T("取る","取る","とる","v5","poly-verb",1326980,39107,"polysemous","confirm","record/take down")]),
("sc019","昼食を取る時間さえない。",[
  T("取る","取る","とる","v5","poly-verb",1326980,39102,"polysemous","confirm","eat/have (meal)"),
  T("時間","時間","じかん","noun","poly-noun",1315920,37701,"polysemous","confirm","time")]),
("sc020","先生が来たので皆が立った。",[
  T("来た","来る","くる","vk","poly-verb",1547720,67678,"polysemous","confirm","come"),
  T("立った","立つ","たつ","v5","poly-verb",1597040,74450,"polysemous","confirm","stand up")]),
("sc021","彼は今年の市長選に立った。",[
  T("市長","市長","しちょう","noun","noun",1308610,36808,"monosemous","accept","mayor"),
  T("立った","立つ","たつ","v5","poly-verb",1597040,74458,"polysemous","confirm","stand for election")]),
("sc022","彼の浮気の噂が立っている。",[
  T("噂","噂","うわさ","noun","poly-noun",1172590,19565,"polysemous","confirm","rumour"),
  T("立っている","立つ","たつ","v5","poly-verb",1597040,74457,"polysemous","confirm","spread (rumour)")]),
("sc023","弟は風邪を引いて寝込んだ。",[
  T("風邪","風邪","かぜ","noun","noun",1583720,72412,"monosemous","accept","common cold"),
  T("引いて","引く","ひく","v5","poly-verb",1169250,19120,"polysemous","confirm","catch (cold)")]),
("sc024","意味が分からない時は辞書を引く。",[
  T("分からない","分かる","わかる","v5","poly-verb",1606560,76014,"polysemous","confirm","understand"),
  T("辞書","辞書","じしょ","noun","poly-noun",1318970,38073,"polysemous","confirm","dictionary"),
  T("引く","引く","ひく","v5","poly-verb",1169250,19122,"polysemous","confirm","look up (dictionary)")]),
("sc025","祖父は日曜に三味線を引く。",[
  T("三味線","三味線","しゃみせん","noun","noun",1579450,71720,"monosemous","accept","shamisen"),
  T("引く","引く","ひく","v5","poly-verb",1169250,19121,"polysemous","confirm","play (stringed)")]),
("sc026","彼女はそっとカーテンを引いた。",[
  T("引いた","引く","ひく","v5","poly-verb",1169250,19115,"polysemous","confirm","pull/draw")]),
("sc027","話が終わったので電話を切った。",[
  T("切った","切る","きる","v5","poly-verb",1384830,46697,"polysemous","confirm","hang up (phone)")]),
("sc028","母は包丁で人参を切った。",[
  T("包丁","包丁","ほうちょう","noun","poly-noun",1515530,63605,"polysemous","confirm","kitchen knife"),
  T("人参","人参","にんじん","noun","poly-noun",1367800,44476,"polysemous","confirm","carrot"),
  T("切った","切る","きる","v5","poly-verb",1384830,46694,"polysemous","confirm","cut")]),
# ===== D. 当たる/通る/開く/着く/決まる/決める =====
("sc029","宝くじが当たった。",[
  T("宝くじ","宝くじ","たからくじ","noun","poly-noun",1516170,63681,"polysemous","confirm","lottery"),
  T("当たった","当たる","あたる","v5","poly-verb",1448810,55110,"polysemous","confirm","win (lottery)")]),
("sc030","ボールが窓に当たった。",[
  T("窓","窓","まど","noun","noun",1401400,48863,"monosemous","accept","window"),
  T("当たった","当たる","あたる","v5","poly-verb",1448810,55106,"polysemous","confirm","be hit")]),
("sc031","法案が国会を通った。",[
  T("法案","法案","ほうあん","noun","noun",1517160,63841,"monosemous","accept","bill (law)"),
  T("国会","国会","こっかい","noun","poly-noun",1286240,33942,"polysemous","confirm","National Diet"),
  T("通った","通る","とおる","v5","poly-verb",1433030,53058,"polysemous","confirm","pass (bill)")]),
("sc032","毎朝この道を通る。",[
  T("毎朝","毎朝","まいあさ","noun","time",1524700,64778,"monosemous","accept","every morning"),
  T("道","道","みち","noun","homograph-entry",1454080,55812,"polysemous","confirm","road; 道 also = 2158900/2268290"),
  T("通る","通る","とおる","v5","poly-verb",1433030,53051,"polysemous","confirm","go along")]),
("sc033","市役所で会議を開いた。",[
  T("会議","会議","かいぎ","noun","noun",1198360,22728,"monosemous","accept","meeting"),
  T("開いた","開く","ひらく","v5","poly-verb",1202440,23249,"polysemous","confirm","hold (meeting)")]),
("sc034","彼は銀行に口座を開いた。",[
  T("銀行","銀行","ぎんこう","noun","noun",1243490,28541,"monosemous","accept","bank"),
  T("口座","口座","こうざ","noun","noun",1276150,32675,"monosemous","accept","account"),
  T("開いた","開く","ひらく","v5","poly-verb",1202440,23252,"polysemous","confirm","open (account)")]),
("sc035","新しいファイルを開いた。",[
  T("新しい","新しい","あたらしい","adj-i","adj-i",1361490,43720,"monosemous","accept","new"),
  T("開いた","開く","ひらく","v5","poly-verb",1202440,23254,"polysemous","confirm","open (file)")]),
("sc036","この店はまだ開いている。",[
  T("店","店","みせ","noun","homograph-entry",1582120,72159,"polysemous","confirm","shop"),
  T("開いている","開く","あく","v5","poly-verb",1202440,23247,"polysemous","confirm","open (for business)")]),
("sc037","電車に乗って学校に着いた。",[
  T("電車","電車","でんしゃ","noun","noun",1443530,54423,"monosemous","accept","train"),
  T("着いた","着く","つく","v5","poly-verb",1422970,51726,"polysemous","confirm","arrive")]),
("sc038","食事の席に着いてください。",[
  T("席","席","せき","noun","poly-noun",1382250,46349,"polysemous","confirm","seat"),
  T("着いて","着く","つく","v5","poly-verb",1422970,51727,"polysemous","confirm","sit at")]),
("sc039","旅行の日程が決まった。",[
  T("日程","日程","にってい","noun","noun",1464300,57118,"monosemous","accept","schedule"),
  T("決まった","決まる","きまる","v5","poly-verb",1591420,73588,"polysemous","confirm","be decided")]),
("sc040","彼は行く店と決まっている。",[
  T("決まっている","決まる","きまる","v5","poly-verb",1591420,73589,"polysemous","confirm","always the same")]),
("sc041","そのスーツは彼に決まっている。",[
  T("決まっている","決まる","きまる","v5","poly-verb",1591420,73592,"polysemous","confirm","look good")]),
("sc042","進路を早く決めなさい。",[
  T("決めなさい","決める","きめる","v1","poly-verb",1254180,29898,"polysemous","confirm","decide")]),
("sc043","彼は朝食を抜くと決めている。",[
  T("決めている","決める","きめる","v1","poly-verb",1254180,29901,"polysemous","confirm","always do (habit)")]),
# ===== E. 落ちる/起きる/走る/受ける 等 =====
("sc044","木の葉が地面に落ちた。",[
  T("葉","葉","は","noun","poly-noun",1546550,67531,"polysemous","confirm","leaf"),
  T("落ちた","落ちる","おちる","v1","poly-verb",1548550,67777,"polysemous","confirm","fall")]),
("sc045","兄は大学の試験に落ちた。",[
  T("試験","試験","しけん","noun","poly-noun",1312350,37279,"polysemous","confirm","exam"),
  T("落ちた","落ちる","おちる","v1","poly-verb",1548550,67784,"polysemous","confirm","fail (exam)")]),
("sc046","二人はゆっくり恋に落ちた。",[
  T("恋","恋","こい","noun","noun",1558670,69132,"monosemous","accept","love"),
  T("落ちた","落ちる","おちる","v1","poly-verb",1548550,67787,"polysemous","confirm","fall (in love)")]),
("sc047","今年の売上が落ちている。",[
  T("売上","売上","うりあげ","noun","noun",1588500,73092,"monosemous","accept","sales"),
  T("落ちている","落ちる","おちる","v1","poly-verb",1548550,67779,"polysemous","confirm","decrease")]),
("sc048","毎朝六時に起きる。",[
  T("起きる","起きる","おきる","v1","poly-verb",1223640,26047,"polysemous","confirm","get up")]),
("sc049","夜中に大きな地震が起きた。",[
  T("地震","地震","じしん","noun","homograph-entry",1421210,51489,"polysemous","confirm","earthquake; dup entry 2862777"),
  T("起きた","起きる","おきる","v1","poly-verb",1223640,26049,"polysemous","confirm","occur")]),
("sc050","彼は昼まで起きていた。",[
  T("起きていた","起きる","おきる","v1","poly-verb",1223640,26048,"polysemous","confirm","be awake")]),
("sc051","子供たちが公園を走った。",[
  T("公園","公園","こうえん","noun","noun",1273270,32346,"monosemous","accept","park"),
  T("走った","走る","はしる","v5","poly-verb",1402540,49012,"polysemous","confirm","run")]),
("sc052","トラックが高速を走る。",[
  T("高速","高速","こうそく","noun","poly-noun",1283700,33626,"polysemous","confirm","highway"),
  T("走る","走る","はしる","v5","poly-verb",1402540,49013,"polysemous","confirm","run (vehicle)")]),
("sc053","空に稲妻が走った。",[
  T("稲妻","稲妻","いなずま","noun","noun",1167860,18927,"monosemous","accept","lightning"),
  T("走った","走る","はしる","v5","poly-verb",1402540,49017,"polysemous","confirm","flash (lightning)")]),
("sc054","彼はたくさんの手紙を受けた。",[
  T("手紙","手紙","てがみ","noun","noun",1327720,39231,"monosemous","accept","letter"),
  T("受けた","受ける","うける","v1","poly-verb",1329590,39482,"polysemous","confirm","receive")]),
("sc055","彼女は来月手術を受ける。",[
  T("手術","手術","しゅじゅつ","noun","poly-noun",1327790,39240,"polysemous","confirm","surgery"),
  T("受ける","受ける","うける","v1","poly-verb",1329590,39486,"polysemous","confirm","undergo")]),
("sc056","この映画は若者に受けた。",[
  T("受けた","受ける","うける","v1","poly-verb",1329590,39493,"polysemous","confirm","be well-received")]),
("sc057","氷が水に浮いている。",[
  T("氷","氷","こおり","noun","homograph-entry",1488840,60270,"polysemous","confirm","ice; 3 entries"),
  T("水","水","みず","noun","homograph-entry",1371260,44907,"polysemous","confirm","water; also Wed/shaved-ice entry"),
  T("浮いている","浮く","うく","v5","poly-verb",1497420,61333,"polysemous","confirm","float")]),
("sc058","船が静かに海に沈んだ。",[
  T("船","船","ふね","noun","poly-noun",1602800,75445,"polysemous","confirm","ship"),
  T("海","海","うみ","noun","noun",1201190,23112,"monosemous","accept","sea"),
  T("沈んだ","沈む","しずむ","v5","poly-verb",1431670,52819,"polysemous","confirm","sink")]),
("sc059","彼は悔しさで心が沈んでいる。",[
  T("心","心","こころ","noun","homograph-entry",1595125,74168,"polysemous","confirm","heart; also 1360480 mind"),
  T("沈んでいる","沈む","しずむ","v5","poly-verb",1431670,52821,"polysemous","confirm","feel depressed")]),
("sc060","次の角を右に曲がって。",[
  T("角","角","かど","noun","homograph-entry",1206110,23750,"polysemous","confirm","street corner; 5 entries for 角"),
  T("曲がって","曲がる","まがる","v5","poly-verb",1239730,28028,"polysemous","confirm","turn")]),
("sc061","鉄の釘が錆びて曲がっている。",[
  T("釘","釘","くぎ","noun","noun",1436840,53588,"monosemous","accept","nail"),
  T("錆びて","錆びる","さびる","v1","v1",1299640,35647,"monosemous","accept","rust"),
  T("曲がっている","曲がる","まがる","v5","poly-verb",1239730,28027,"polysemous","confirm","bend")]),
# ===== F. 多义形容词 =====
("sc062","この荷物はとても重い。",[
  T("重い","重い","おもい","adj-i","poly-adj",1335750,40251,"polysemous","confirm","heavy")]),
("sc063","彼の犯した罪は重い。",[
  T("罪","罪","つみ","noun","poly-noun",1296680,35261,"polysemous","confirm","crime"),
  T("重い","重い","おもい","adj-i","poly-adj",1335750,40255,"polysemous","confirm","serious (crime)")]),
("sc064","この布のバッグは軽い。",[
  T("布","布","ぬの","noun","poly-noun",1496840,61250,"polysemous","confirm","cloth"),
  T("軽い","軽い","かるい","adj-i","poly-adj",1252560,29691,"polysemous","confirm","light (weight)")]),
("sc065","軽い気持ちで約束した。",[
  T("軽い","軽い","かるい","adj-i","poly-adj",1252560,29693,"polysemous","confirm","non-serious"),
  T("約束","約束","やくそく","noun","poly-noun",1538130,66520,"polysemous","confirm","promise")]),
("sc066","あの山はとても高い。",[
  T("山","山","やま","noun","homograph-entry",1302680,36019,"polysemous","confirm","mountain; 13 senses"),
  T("高い","高い","たかい","adj-i","poly-adj",1283190,33558,"polysemous","confirm","high/tall")]),
("sc067","この時計は少し高い。",[
  T("時計","時計","とけい","noun","noun",1316140,37728,"monosemous","accept","watch"),
  T("高い","高い","たかい","adj-i","poly-adj",1283190,33559,"polysemous","confirm","expensive")]),
("sc068","彼女は声が高い。",[
  T("声","声","こえ","noun","homograph-entry",1380440,46139,"polysemous","confirm","voice; also 2843115"),
  T("高い","高い","たかい","adj-i","poly-adj",1283190,33562,"polysemous","confirm","high-pitched")]),
("sc069","この川は浅くて泳げない。",[
  T("川","川","かわ","noun","poly-noun",1390020,47426,"polysemous","confirm","river"),
  T("浅くて","浅い","あさい","adj-i","poly-adj",1390800,47513,"polysemous","confirm","shallow"),
  T("泳げない","泳ぐ","およぐ","v5","inflection",1174340,19765,"polysemous","confirm","swim (potential-neg)")]),
("sc070","幸い傷は浅かった。",[
  T("傷","傷","きず","noun","poly-noun",1580260,71842,"polysemous","confirm","wound"),
  T("浅かった","浅い","あさい","adj-i","poly-adj",1390800,47514,"polysemous","confirm","slight (wound)")]),
("sc071","彼は入社して日が浅い。",[
  T("浅い","浅い","あさい","adj-i","poly-adj",1390800,47515,"polysemous","confirm","short (time)/early")]),
("sc072","今日は風が強い。",[
  T("強い","強い","つよい","adj-i","poly-adj",1236070,27551,"polysemous","confirm","strong")]),
("sc073","彼は数学に強い。",[
  T("数学","数学","すうがく","noun","noun",1372980,45124,"monosemous","accept","mathematics"),
  T("強い","強い","つよい","adj-i","poly-adj",1236070,27553,"polysemous","confirm","good at")]),
("sc074","このテントの布は強い。",[
  T("強い","強い","つよい","adj-i","poly-adj",1236070,27554,"polysemous","confirm","durable")]),
("sc075","電気を消すと部屋が暗い。",[
  T("電気","電気","でんき","noun","poly-noun",1443000,54368,"polysemous","confirm","electric light"),
  T("部屋","部屋","へや","noun","poly-noun",1499320,61578,"polysemous","confirm","room"),
  T("暗い","暗い","くらい","adj-i","poly-adj",1154330,17113,"polysemous","confirm","dark")]),
("sc076","彼はいつも暗い顔をしている。",[
  T("暗い","暗い","くらい","adj-i","poly-adj",1154330,17114,"polysemous","confirm","depressed/gloomy")]),
("sc077","私はその分野に暗い。",[
  T("暗い","暗い","くらい","adj-i","poly-adj",1154330,17118,"polysemous","confirm","unfamiliar")]),
("sc078","朝の部屋は明るい。",[
  T("明るい","明るい","あかるい","adj-i","poly-adj",1532350,65767,"polysemous","confirm","bright")]),
("sc079","彼女は明るい性格だ。",[
  T("性格","性格","せいかく","noun","poly-noun",1375290,45429,"polysemous","confirm","character"),
  T("明るい","明るい","あかるい","adj-i","poly-adj",1532350,65769,"polysemous","confirm","cheerful")]),
("sc080","彼は歴史に明るい。",[
  T("明るい","明るい","あかるい","adj-i","poly-adj",1532350,65771,"polysemous","confirm","knowledgeable")]),
("sc081","このパンは少し固い。",[
  T("固い","固い","かたい","adj-i","poly-adj",1257110,30289,"polysemous","confirm","hard")]),
("sc082","彼の挨拶はいつも固い。",[
  T("挨拶","挨拶","あいさつ","noun","poly-noun",1151120,16697,"polysemous","confirm","greeting"),
  T("固い","固い","かたい","adj-i","poly-adj",1257110,30295,"polysemous","confirm","formal/stuffy")]),
("sc083","このケーキは甘い。",[
  T("甘い","甘い","あまい","adj-i","poly-adj",1213400,24691,"polysemous","confirm","sweet")]),
("sc084","彼の見通しは甘い。",[
  T("見通し","見通し","みとおし","noun","poly-noun",1604610,75717,"polysemous","confirm","forecast"),
  T("甘い","甘い","あまい","adj-i","poly-adj",1213400,24695,"polysemous","confirm","naive")]),
("sc085","あの先生は生徒に甘い。",[
  T("甘い","甘い","あまい","adj-i","poly-adj",1213400,24694,"polysemous","confirm","lenient")]),
("sc086","このカレーはとても辛い。",[
  T("辛い","辛い","からい","adj-i","poly-adj",1365850,44249,"polysemous","confirm","spicy")]),
("sc087","故郷との別れは辛かった。",[
  T("故郷","故郷","こきょう","noun","homograph-entry",1603050,75489,"polysemous","confirm","hometown; 3 entries"),
  T("別れ","別れ","わかれ","noun","poly-noun",1509490,62863,"polysemous","confirm","parting"),
  T("辛かった","辛い","つらい","adj-i","homograph-entry",1365860,44253,"polysemous","confirm","heart-breaking; emotional 辛い entry")]),
("sc088","毎日の残業が辛い。",[
  T("残業","残業","ざんぎょう","noun","noun",1304560,36258,"monosemous","accept","overtime"),
  T("辛い","辛い","つらい","adj-i","homograph-entry",1365860,44254,"polysemous","confirm","tough/difficult")]),
("sc089","このスープは熱い。",[
  T("熱い","熱い","あつい","adj-i","poly-adj",1467720,57548,"polysemous","confirm","hot (touch)")]),
("sc090","彼は野球に熱い。",[
  T("野球","野球","やきゅう","noun","noun",1537300,66403,"monosemous","accept","baseball"),
  T("熱い","熱い","あつい","adj-i","poly-adj",1467720,57549,"polysemous","confirm","passionate")]),
("sc091","今一番熱い話題だ。",[
  T("話題","話題","わだい","noun","poly-noun",1562400,69613,"polysemous","confirm","topic"),
  T("熱い","熱い","あつい","adj-i","poly-adj",1467720,57553,"polysemous","confirm","hot (topic)")]),
("sc092","この水は冷たい。",[
  T("水","水","みず","noun","homograph-entry",1371260,44907,"polysemous","confirm","water"),
  T("冷たい","冷たい","つめたい","adj-i","poly-adj",1556730,68907,"polysemous","confirm","cold (touch)")]),
("sc093","彼女は冷たい返事をした。",[
  T("返事","返事","へんじ","noun","noun",1512220,63203,"monosemous","accept","reply"),
  T("冷たい","冷たい","つめたい","adj-i","poly-adj",1556730,68908,"polysemous","confirm","coldhearted")]),
("sc094","彼は足が速い。",[
  T("足","足","あし","noun","poly-noun",1404630,49280,"polysemous","confirm","leg"),
  T("速い","速い","はやい","adj-i","poly-adj",1404975,49344,"polysemous","confirm","fast; same entry as 早い")]),
("sc095","彼はいつも返事が早い。",[
  T("早い","早い","はやい","adj-i","poly-adj",1404975,49345,"polysemous","confirm","early; same entry as 速い")]),
("sc096","迎えに来るのが遅い。",[
  T("迎え","迎え","むかえ","noun","poly-noun",1253180,29773,"polysemous","confirm","meeting/greeting"),
  T("遅い","遅い","おそい","adj-i","poly-adj",1421970,51599,"polysemous","confirm","slow/late")]),
("sc097","彼の説明はいつも長い。",[
  T("説明","説明","せつめい","noun","noun",1386460,46977,"monosemous","accept","explanation"),
  T("長い","長い","ながい","adj-i","poly-adj",1429750,52591,"polysemous","confirm","long (time)")]),
("sc098","この路地は車一台分しかないほど狭い。",[
  T("車","車","くるま","noun","homograph-entry",1323080,38596,"polysemous","confirm","car"),
  T("狭い","狭い","せまい","adj-i","poly-adj",1237680,27756,"polysemous","confirm","narrow")]),
("sc099","彼は心が狭い。",[
  T("心","心","こころ","noun","homograph-entry",1595125,74168,"polysemous","confirm","heart"),
  T("狭い","狭い","せまい","adj-i","poly-adj",1237680,27757,"polysemous","confirm","narrow-minded")]),
# ===== G. 多义名词 =====
("sc100","彼女は幼いが気が強い。",[
  T("幼い","幼い","おさない","adj-i","adj-i",1545110,67344,"polysemous","confirm","very young"),
  T("気","気","き","noun","poly-noun",1221520,25782,"polysemous","confirm","nature/disposition")]),
("sc101","その話を聞いて気が重い。",[
  T("気","気","き","noun","poly-noun",1221520,25784,"polysemous","confirm","mood/feelings"),
  T("重い","重い","おもい","adj-i","poly-adj",1335750,40252,"polysemous","confirm","heavy (feeling)")]),
("sc102","夜道では気を付けて。",[
  T("気","気","き","noun","poly-noun",1221520,25786,"polysemous","confirm","care/attention")]),
("sc103","私は彼に手を貸した。",[
  T("手","手","て","noun","poly-noun",1327190,39151,"polysemous","confirm","hand/worker/help")]),
("sc104","この仕事は手が掛かる。",[
  T("仕事","仕事","しごと","noun","poly-noun",1304970,36310,"polysemous","confirm","work"),
  T("手","手","て","noun","poly-noun",1327190,39152,"polysemous","confirm","trouble/effort"),
  T("掛かる","掛かる","かかる","v5","poly-verb",1207590,23930,"polysemous","confirm","take (effort)")]),
("sc105","何かいい手があるはずだ。",[
  T("手","手","て","noun","poly-noun",1327190,39153,"polysemous","confirm","means/trick")]),
("sc106","昨日歩きすぎて足が痛い。",[
  T("昨日","昨日","きのう","noun","time",1579260,71693,"monosemous","accept","yesterday"),
  T("足","足","あし","noun","poly-noun",1404630,49280,"polysemous","confirm","leg")]),
("sc107","この村は車がないと足がない。",[
  T("村","村","むら","noun","noun",1406820,49579,"monosemous","accept","village"),
  T("足","足","あし","noun","poly-noun",1404630,49284,"polysemous","confirm","transportation")]),
("sc108","彼は近眼で目が悪い。",[
  T("目","目","め","noun","poly-noun",1604890,75755,"polysemous","confirm","eyesight")]),
("sc109","彼女は骨董を見る目がある。",[
  T("骨董","骨董","こっとう","noun","noun",1288700,34249,"monosemous","accept","antique"),
  T("見る","見る","みる","v1","poly-verb",1259290,30558,"polysemous","confirm","see"),
  T("目","目","め","noun","poly-noun",1604890,75760,"polysemous","confirm","discernment")]),
("sc110","この計画には成功する目がある。",[
  T("計画","計画","けいかく","noun","noun",1252090,29634,"monosemous","accept","plan"),
  T("成功","成功","せいこう","noun","poly-noun",1375690,45489,"polysemous","confirm","success"),
  T("目","目","め","noun","poly-noun",1604890,75762,"polysemous","confirm","chance")]),
("sc111","風が強くて桜が散った。",[
  T("風","風","かぜ","noun","poly-noun",1499720,61626,"polysemous","confirm","wind"),
  T("桜","桜","さくら","noun","poly-noun",1593710,73934,"polysemous","confirm","cherry")]),
("sc112","寒くて風を引いた。",[
  T("寒くて","寒い","さむい","adj-i","poly-adj",1210360,24351,"polysemous","confirm","cold (weather)"),
  T("風","風","かぜ","noun","poly-noun",1499720,61628,"polysemous","confirm","cold/flu; same surface as wind"),
  T("引いた","引く","ひく","v5","poly-verb",1169250,19120,"polysemous","confirm","catch (cold)")]),
("sc113","彼は頭が良い。",[
  T("頭","頭","あたま","noun","poly-noun",1582310,72195,"polysemous","confirm","brains"),
  T("良い","良い","よい","adj-i","poly-adj",1605820,75909,"polysemous","confirm","good")]),
("sc114","朝から頭が痛い。",[
  T("朝","朝","あさ","noun","homograph-entry",1428280,52385,"polysemous","confirm","morning; also dynasty entry"),
  T("頭","頭","あたま","noun","poly-noun",1582310,72193,"polysemous","confirm","head")]),
("sc115","彼はこの組織の頭だ。",[
  T("組織","組織","そしき","noun","poly-noun",1397630,48387,"polysemous","confirm","organization"),
  T("頭","頭","あたま","noun","poly-noun",1582310,72196,"polysemous","confirm","leader")]),
("sc116","額から汗の玉が落ちた。",[
  T("額","額","ひたい","noun","homograph-entry",1207510,23915,"polysemous","confirm","forehead; also amount entry"),
  T("汗","汗","あせ","noun","poly-noun",1213060,24653,"polysemous","confirm","sweat"),
  T("玉","玉","たま","noun","poly-noun",1240530,28127,"polysemous","confirm","droplet"),
  T("落ちた","落ちる","おちる","v1","poly-verb",1548550,67777,"polysemous","confirm","fall")]),
("sc117","箱の中を見てください。",[
  T("箱","箱","はこ","noun","poly-noun",1585650,72692,"polysemous","confirm","box"),
  T("中","中","なか","noun","homograph-entry",1457730,56316,"polysemous","confirm","inside; also 1423310"),
  T("見て","見る","みる","v1","poly-verb",1259290,30558,"polysemous","confirm","see")]),
("sc118","答えは表の上を見てください。",[
  T("表","表","ひょう","noun","homograph-entry",1489350,60343,"polysemous","confirm","table; also surface entry"),
  T("上","上","うえ","noun","poly-noun",1352130,42372,"polysemous","confirm","the above (in writing)"),
  T("見て","見る","みる","v1","poly-verb",1259290,30558,"polysemous","confirm","see")]),
("sc119","橋の下に船が見える。",[
  T("橋","橋","はし","noun","poly-noun",1237410,27720,"polysemous","confirm","bridge"),
  T("下","下","した","noun","homograph-entry",1184140,20978,"polysemous","confirm","beneath; 3 entries")]),
# ===== H. 表记/读音限制义项 =====
("sc120","彼は明後日の方角を向いていた。",[
  T("明後日","明後日","あさって","noun","restricted-reading",1584640,72531,"restricted","confirm","wrong direction; あさって-only sense")]),
("sc121","明日の世界を考える。",[
  T("明日","明日","あす","noun","restricted-reading",1584660,72534,"restricted","confirm","near future; あす-only sense")]),
("sc122","今日の日本経済は大きく変わった。",[
  T("今日","今日","こんにち","noun","restricted-reading",1579110,71676,"restricted","confirm","these days; こんにち-only sense"),
  T("日本","日本","にほん","proper","proper",1582710,72264,"proper","accept","Japan")]),
("sc123","明日は雨らしい。",[
  T("明日","明日","あした","noun","poly-noun",1584660,72533,"polysemous","confirm","tomorrow (unrestricted sense)")]),
# ===== I. 助动词链（aux-v 义项）=====
("sc124","約束を忘れてしまった。",[
  T("約束","約束","やくそく","noun","poly-noun",1538130,66520,"polysemous","confirm","promise"),
  T("忘れて","忘れる","わすれる","v1","v1",1519210,64065,"monosemous","accept","forget"),
  T("しまった","仕舞う","しまう","v5","aux-chain",1305380,36375,"polysemous","confirm","aux-v accidentally")]),
("sc125","前もって予習しておいた。",[
  T("予習","予習","よしゅう","noun","noun",1543070,67107,"monosemous","accept","preparation"),
  T("おいた","置く","おく","v5","aux-chain",1421850,51585,"polysemous","confirm","aux-v do in advance")]),
("sc126","一度この料理を試してみた。",[
  T("料理","料理","りょうり","noun","poly-noun",1554310,68607,"polysemous","confirm","cooking"),
  T("試して","試す","ためす","v5","v5",1312260,37268,"monosemous","accept","try"),
  T("みた","見る","みる","v1","aux-chain",1259290,30562,"polysemous","confirm","aux-v try")]),
("sc127","友達に荷物を手伝ってもらった。",[
  T("手伝って","手伝う","てつだう","v5","poly-verb",1328190,39296,"polysemous","confirm","help"),
  T("もらった","貰う","もらう","v5","aux-chain",1535910,66240,"polysemous","confirm","aux-v get someone to do")]),
("sc128","この傾向は今後も続いていく。",[
  T("続いて","続く","つづく","v5","poly-verb",1405790,49449,"polysemous","confirm","continue"),
  T("いく","行く","いく","v5","aux-chain",1578850,71638,"polysemous","confirm","aux-v continue ... steadily")]),
("sc129","最近だんだん寒くなってきた。",[
  T("寒く","寒い","さむい","adj-i","poly-adj",1210360,24351,"polysemous","confirm","cold"),
  T("きた","来る","くる","vk","aux-chain",1547720,67680,"polysemous","confirm","aux-v come to be")]),
("sc130","彼はずっと本を読んでいる。",[
  T("本","本","ほん","noun","homograph-entry",1522150,64416,"polysemous","confirm","book; also origin entry"),
  T("読んで","読む","よむ","v5","poly-verb",1456360,56102,"polysemous","confirm","read"),
  T("いる","居る","いる","v1","aux-chain",1577980,71490,"polysemous","confirm","aux-v be ...-ing")]),
# ===== J. 同表记多 entry（homograph）=====
("sc131","夜、雨が激しく降った。",[
  T("夜","夜","よる","noun","poly-noun",1536350,66298,"polysemous","confirm","night"),
  T("降った","降る","ふる","v5","homograph-entry",1282790,33508,"restricted","confirm","fall (rain); ふる-only entry")]),
("sc132","彼はゆっくり山道を降った。",[
  T("山道","山道","やまみち","noun","noun",1303090,36081,"monosemous","accept","mountain path"),
  T("降った","降る","くだる","v5","homograph-entry",1184450,21041,"restricted","confirm","descend; くだる-only entry")]),
("sc133","彼女はそっと部屋に入った。",[
  T("部屋","部屋","へや","noun","poly-noun",1499320,61578,"polysemous","confirm","room"),
  T("入った","入る","はいる","v5","restricted-reading",1465590,57256,"restricted","confirm","enter; はいる entry (vs いる 1465580)")]),
("sc134","彼は朝早く家を出た。",[
  T("朝","朝","あさ","noun","homograph-entry",1428280,52385,"polysemous","confirm","morning"),
  T("家","家","いえ","noun","homograph-entry",1191730,21921,"polysemous","confirm","house; many 家 entries"),
  T("出た","出る","でる","v1","poly-verb",1338240,40555,"polysemous","confirm","leave/exit")]),
("sc135","この小説は有名な雑誌に出た。",[
  T("小説","小説","しょうせつ","noun","noun",1348430,41882,"monosemous","accept","novel"),
  T("雑誌","雑誌","ざっし","noun","noun",1299400,35616,"monosemous","accept","magazine"),
  T("出た","出る","でる","v1","poly-verb",1338240,40560,"polysemous","confirm","be published")]),
# ===== K. 单词义（auto-accept 期望层）=====
("sc136","彼女は優しい人だ。",[
  T("優しい","優しい","やさしい","adj-i","adj-i",1539040,66654,"monosemous","accept","kind")]),
("sc137","この公園は広い。",[
  T("公園","公園","こうえん","noun","noun",1273270,32346,"monosemous","accept","park"),
  T("広い","広い","ひろい","adj-i","adj-i",1278410,32959,"monosemous","accept","spacious")]),
("sc138","試験に受かった。",[
  T("受かった","受かる","うかる","v5","v5",1329580,39481,"monosemous","accept","pass (exam)")]),
("sc139","窓を閉じてください。",[
  T("閉じて","閉じる","とじる","v1","v1",1508550,62752,"monosemous","accept","close")]),
("sc140","彼女は美しい花を育てた。",[
  T("美しい","美しい","うつくしい","adj-i","adj-i",1486360,59965,"monosemous","accept","beautiful")]),
("sc141","弟は楽しい一日を過ごした。",[
  T("楽しい","楽しい","たのしい","adj-i","adj-i",1207240,23883,"monosemous","accept","fun")]),
("sc142","明日は晴れるだろう。",[
  T("晴れる","晴れる","はれる","v1","poly-verb",1376470,45601,"polysemous","confirm","clear up")]),
# ===== L. 专名 =====
("sc143","田中さんは東京に住んでいる。",[
  T("田中","田中","たなか","proper","proper-oov",None,None,"proper","confirm","surname; not in JMdict"),
  T("東京","東京","とうきょう","proper","proper-dict",1447690,54973,"proper","accept","Tokyo"),
  T("住んでいる","住む","すむ","v5","v5",1334040,40052,"monosemous","accept","live/reside")]),
("sc144","山田さんと佐藤さんが来た。",[
  T("山田","山田","やまだ","proper","proper-oov",None,None,"proper","confirm","surname; not in JMdict"),
  T("佐藤","佐藤","さとう","proper","proper-oov",None,None,"proper","confirm","surname; not in JMdict")]),
("sc145","彼は大阪から北海道へ引っ越した。",[
  T("大阪","大阪","おおさか","proper","proper-dict",2078800,123087,"proper","accept","Osaka"),
  T("北海道","北海道","ほっかいどう","proper","proper-dict",1520810,64261,"proper","accept","Hokkaido")]),
("sc146","京都は日本の古都だ。",[
  T("京都","京都","きょうと","proper","proper-dict",1652350,81174,"proper","accept","Kyoto"),
  T("日本","日本","にほん","proper","proper-dict",1582710,72264,"proper","accept","Japan")]),
# ===== M. OOV（词典缺失）=====
("sc147","その動画がバズって話題になった。",[
  T("動画","動画","どうが","noun","poly-noun",1451290,55473,"polysemous","confirm","video"),
  T("バズって","バズる","ばずる","v5","oov",None,None,"oov","confirm","go viral; JMdict 缺失")]),
("sc148","彼女の歌は本当にエモい。",[
  T("歌","歌","うた","noun","poly-noun",1193180,22096,"polysemous","confirm","song"),
  T("エモい","エモい","えもい","adj-i","oov",None,None,"oov","confirm","emotional; JMdict 缺失")]),
("sc149","毎月サブスクの料金を払っている。",[
  T("サブスク","サブスク","さぶすく","noun","oov",None,None,"oov","confirm","subscription; JMdict 缺失"),
  T("料金","料金","りょうきん","noun","noun",1554280,68604,"monosemous","accept","fee"),
  T("払っている","払う","はらう","v5","poly-verb",1501620,61882,"polysemous","confirm","pay")]),
("sc150","最近はタイパを重視する人が多い。",[
  T("タイパ","タイパ","たいぱ","noun","oov",None,None,"oov","confirm","time-performance; JMdict 缺失"),
  T("重視","重視","じゅうし","noun","noun",1336260,40316,"monosemous","accept","importance")]),
("sc151","彼はぴえんの顔文字を送った。",[
  T("ぴえん","ぴえん","ぴえん","noun","oov",None,None,"oov","confirm","pleading-face slang; JMdict 缺失"),
  T("顔文字","顔文字","かおもじ","noun","noun",1960330,110942,"monosemous","accept","emoticon")]),
("sc152","メタバースのイベントに参加した。",[
  T("メタバース","メタバース","めたばーす","noun","oov",None,None,"oov","confirm","metaverse; JMdict 缺失"),
  T("参加","参加","さんか","noun","noun",1302090,35950,"monosemous","accept","participation")]),
# ===== N. 活用覆盖（同义项的不同活用形）=====
("sc153","値段がどんどん上がっている。",[
  T("上がっている","上がる","あがる","v5","inflection",1352290,42420,"polysemous","confirm","increase (te-iru)")]),
("sc154","彼は走っている途中で転んだ。",[
  T("走っている","走る","はしる","v5","inflection",1402540,49012,"polysemous","confirm","run (te-iru)")]),
("sc155","彼女は泳げないと言った。",[
  T("泳げない","泳ぐ","およぐ","v5","inflection",1174340,19765,"polysemous","confirm","swim (potential-neg)"),
  T("言った","言う","いう","v5","poly-verb",1587040,72889,"polysemous","confirm","say")]),
("sc156","昨日はとても寒かった。",[
  T("昨日","昨日","きのう","noun","time",1579260,71693,"monosemous","accept","yesterday"),
  T("寒かった","寒い","さむい","adj-i","inflection",1210360,24351,"polysemous","confirm","cold (past)")]),
("sc157","彼はその本を読み終わった。",[
  T("読み終わった","読み終わる","よみおわる","v5","compound-verb",1915110,106671,"monosemous","accept","finish reading")]),
("sc158","午後から雨が降りそうだ。",[
  T("降りそう","降る","ふる","v5","inflection",1282790,33508,"restricted","confirm","rain (そう)")]),
# ===== O. 长句（≥40 字）=====
("sc159","昨日の夜、近所の図書館で借りた本を読んでいたら、急に雷が鳴り始めて、窓の外では稲妻が走り、大きな音に猫が驚いて逃げてしまった。",[
  T("昨日","昨日","きのう","noun","time",1579260,71693,"monosemous","accept","yesterday"),
  T("近所","近所","きんじょ","noun","noun",1242350,28398,"monosemous","accept","neighbourhood"),
  T("図書館","図書館","としょかん","noun","noun",1370420,44777,"monosemous","accept","library"),
  T("借りた","借りる","かりる","v1","poly-verb",1323560,38654,"polysemous","confirm","borrow"),
  T("本","本","ほん","noun","homograph-entry",1522150,64416,"polysemous","confirm","book"),
  T("読んでいた","読む","よむ","v5","poly-verb",1456360,56102,"polysemous","confirm","read"),
  T("雷","雷","かみなり","noun","homograph-entry",1585060,72612,"polysemous","confirm","thunder; several entries"),
  T("稲妻","稲妻","いなずま","noun","noun",1167860,18927,"monosemous","accept","lightning"),
  T("走り","走る","はしる","v5","poly-verb",1402540,49017,"polysemous","confirm","flash"),
  T("音","音","おと","noun","homograph-entry",1576900,71327,"polysemous","confirm","sound; 3 entries"),
  T("猫","猫","ねこ","noun","poly-noun",1467640,57532,"polysemous","confirm","cat"),
  T("驚いて","驚く","おどろく","v5","poly-verb",1238680,27879,"polysemous","confirm","be surprised"),
  T("逃げて","逃げる","にげる","v1","poly-verb",1450330,55335,"polysemous","confirm","flee"),
  T("しまった","仕舞う","しまう","v5","aux-chain",1305380,36375,"polysemous","confirm","aux-v accidentally")]),
("sc160","彼女は十年ぶりに故郷の港に戻り、錆びた桟橋の先で、沈んでいく夕日を眺めながら、昔の友達との約束を思い出していた。",[
  T("故郷","故郷","こきょう","noun","homograph-entry",1603050,75489,"polysemous","confirm","hometown"),
  T("港","港","みなと","noun","poly-noun",1279990,33163,"polysemous","confirm","harbour"),
  T("戻り","戻る","もどる","v5","poly-verb",1535880,66233,"polysemous","confirm","return"),
  T("錆びた","錆びる","さびる","v1","v1",1299640,35647,"monosemous","accept","rusted"),
  T("桟橋","桟橋","さんばし","noun","noun",1303650,36157,"monosemous","accept","pier"),
  T("沈んで","沈む","しずむ","v5","poly-verb",1431670,52820,"polysemous","confirm","set (sun)"),
  T("いく","行く","いく","v5","aux-chain",1578850,71638,"polysemous","confirm","aux-v steadily"),
  T("夕日","夕日","ゆうひ","noun","noun",1542750,67075,"monosemous","accept","evening sun"),
  T("眺め","眺める","ながめる","v1","poly-verb",1428830,52459,"polysemous","confirm","look out over"),
  T("昔","昔","むかし","noun","poly-noun",1382370,46368,"polysemous","confirm","old days"),
  T("約束","約束","やくそく","noun","poly-noun",1538130,66520,"polysemous","confirm","promise"),
  T("思い出して","思い出す","おもいだす","v5","v5",1309260,36887,"monosemous","accept","recall")]),
("sc161","新しい会議室の扉を開けると、壁一面の窓から夕日が差し込み、机の上に置かれた古い地図と時計が薄暗い光の中に浮かんで見えた。",[
  T("新しい","新しい","あたらしい","adj-i","adj-i",1361490,43720,"monosemous","accept","new"),
  T("会議室","会議室","かいぎしつ","noun","noun",1198380,22730,"monosemous","accept","conference room"),
  T("扉","扉","とびら","noun","poly-noun",1483380,59578,"polysemous","confirm","door"),
  T("開ける","開ける","あける","v1","poly-verb",1202450,23261,"polysemous","confirm","open (door)"),
  T("窓","窓","まど","noun","noun",1401400,48863,"monosemous","accept","window"),
  T("夕日","夕日","ゆうひ","noun","noun",1542750,67075,"monosemous","accept","evening sun"),
  T("机","机","つくえ","noun","noun",1220210,25612,"monosemous","accept","desk"),
  T("古い","古い","ふるい","adj-i","poly-adj",1265070,31298,"polysemous","confirm","old"),
  T("地図","地図","ちず","noun","noun",1421290,51497,"monosemous","accept","map"),
  T("時計","時計","とけい","noun","noun",1316140,37728,"monosemous","accept","clock")]),
]

# ------------------- 分层抽样 -------------------
SEVERITY = {"oov": 4, "restricted": 3, "polysemous": 2, "proper": 1, "monosemous": 0}

def sentence_stratum(targets):
    return max(targets, key=lambda t: SEVERITY[t[7]])[7]

def assign_subsets(rows):
    """每层内按 sentence_id 排序、每第 4 句（idx%4==1）进 validation。"""
    by_stratum = {}
    for sid, _, targets in rows:
        by_stratum.setdefault(sentence_stratum(targets), []).append(sid)
    subset = {}
    for stratum, sids in by_stratum.items():
        for i, sid in enumerate(sorted(sids)):
            subset[sid] = "validation" if i % 4 == 1 else "dev"
    return subset

# ------------------- 词典校验 -------------------
def verify(conn):
    """校验全部 expected id；返回 {sense_id: fingerprint|None}。"""
    fps = {}
    problems = []
    for sid, text, targets in S:
        for t in targets:
            surf, lemma, reading, pos, cat, eid, sid_, amb, acc, hint = t
            if amb == "oov" or (amb == "proper" and eid is None):
                if eid is not None or sid_ is not None:
                    problems.append(f"{sid}:{surf} OOV/proper-oov must be null ids")
                continue
            if eid is None:
                # 允许「低价值 target 不标 entry」（skip annotation）
                continue
            row = conn.execute(
                "SELECT primary_form FROM entries WHERE id=?", (eid,)).fetchone()
            if not row:
                problems.append(f"{sid}:{surf} entry {eid} not found")
                continue
            if sid_ is None:
                problems.append(f"{sid}:{surf} entry {eid} missing sense_id")
                continue
            row2 = conn.execute(
                "SELECT sense_order FROM senses WHERE id=? AND entry_id=?",
                (sid_, eid)).fetchone()
            if not row2:
                problems.append(f"{sid}:{surf} sense {sid_} not in entry {eid}")
                continue
            fp = conn.execute(
                "SELECT source_fingerprint FROM glosses "
                "WHERE sense_id=? AND source_fingerprint IS NOT NULL LIMIT 1",
                (sid_,)).fetchone()
            fps[sid_] = fp[0] if fp else None
    return fps, problems

# ------------------- 写出 -------------------
def main():
    conn = sqlite3.connect(f"file:{dict_path()}?mode=ro", uri=True)
    fps, problems = verify(conn)
    if problems:
        for p in problems:
            print("VERIFY-FAIL:", p, file=sys.stderr)
        sys.exit(1)

    subsets = assign_subsets(S)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sense-v1.jsonl")
    ntargets = 0
    stats = {}
    with open(out, "w", encoding="utf-8") as f:
        for sid, text, targets in S:
            tlist = []
            claimed = []
            for surf, lemma, reading, pos, cat, eid, sid_, amb, acc, hint in targets:
                occ = []
                idx = text.find(surf)
                while idx >= 0:
                    occ.append(idx)
                    idx = text.find(surf, idx + 1)
                if not occ:
                    raise SystemExit(f"{sid}: surface {surf!r} not in {text!r}")
                pick = None
                for i in occ:
                    st = u16len(text[:i])
                    r = (st, st + u16len(surf))
                    if all(not (c[0] <= r[0] and r[1] <= c[1]) for c in claimed):
                        pick = i
                        break
                if pick is None:
                    raise SystemExit(f"{sid}: {surf!r} always inside claimed range")
                start = u16len(text[:pick])
                claimed.append((start, start + u16len(surf)))
                tlist.append({
                    "surface": surf, "utf16_start": start,
                    "utf16_len": u16len(surf), "lemma": lemma, "reading": reading,
                    "pos_family": pos, "category": cat,
                    "confidence": "high",
                    "expected_entry_id": eid, "expected_sense_id": sid_,
                    "expected_sense_fingerprint": fps.get(sid_) if sid_ else None,
                    "ambiguity": amb, "auto_accept_expectation": acc,
                    "sense_gloss_hint": hint,
                })
                ntargets += 1
                key = (amb, subsets[sid])
                stats[key] = stats.get(key, 0) + 1
            f.write(json.dumps({
                "sentence_id": sid, "subset": subsets[sid],
                "text": text, "targets": tlist,
            }, ensure_ascii=False) + "\n")
    print(f"wrote {len(S)} sentences, {ntargets} targets -> {out}")
    for (amb, sub), n in sorted(stats.items()):
        print(f"  {amb:11s} {sub:10s} {n}")

if __name__ == "__main__":
    main()
