class_name VMDLoader
extends RefCounted

# 纯 GDScript 解析 VMD 2.0 动作文件（MMD 动画格式）。
# 对齐 reze/engine/src/vmd-loader.ts：
#   bone 帧 = 111B(15名+4帧号+12位移+16旋转+64插值)
#   morph 帧 = 23B(15名+4帧号+4权重)
#   camera = 61B / light = 28B / ik-show = 9B 起（MVP 暂不解析，动作播放不需要）
# 默认 30 FPS；返回按骨骼名 / morph 名索引的关键帧数组（每轨已按帧号升序排序）。
#
# 名字解码：VMD 用 Shift-JIS，Godot 无内置解码器，故用 sjis_map.gd 的码点映射表 + ASCII 直读。
# PMX 骨骼名是 UTF-16，两者解码成同一 Unicode 字符串即可按名匹配。

const SJIS := preload("res://sjis_map.gd")
const FPS := 30.0

# 全角→半角归一化（对齐 AfterglowWeb src/utils/vmd-loader.ts:32 normalizeBoneName）。
# MMD 的骨骼/表情名常混用全角字符（例：VMD 里是「右足ＩＫ」「左親指０」，PMX 里是「右足IK」「左親指0」），
# 不归一化就匹配不上 → 整条骨骼/morph 轨被丢弃。AfterglowWeb 对 VMD 名与 PMX 名都跑这一步，
# 这里同样对解析出的 VMD 名跑，vmd_player 里再对骨架/PMX 名跑同一函数，保证两侧一致。
static func normalize_bone_name(s: String) -> String:
	var out := ""
	for i in s.length():
		var c := s.unicode_at(i)
		if c >= 0xFF01 and c <= 0xFF5E:
			out += String.chr(c - 0xFEE0)   # 全角 ASCII/数字/标点 → 半角
		elif c == 0x3000:
			out += " "                       # 全角空格 → 半角空格
		else:
			out += s[i]
	return out

func parse(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[VMDLoader] 无法打开: " + path)
		return {}
	f.get_buffer(30)            # header "Vocaloid Motion Data 0002..."
	f.get_buffer(20)            # model name（固定 20 字节，跳过）
	var bone_count := f.get_32()
	var bone_tracks := {}
	for i in bone_count:
		var name := normalize_bone_name(_decode_name(f))
		var frame := f.get_32()
		var p := Vector3(f.get_float(), f.get_float(), f.get_float())
		var q := Quaternion(f.get_float(), f.get_float(), f.get_float(), f.get_float())
		var interp := f.get_buffer(64)
		var rec := {"frame": frame, "pos": p, "rot": q, "interp": interp}
		if not bone_tracks.has(name):
			bone_tracks[name] = []
		bone_tracks[name].append(rec)
	_sort_tracks(bone_tracks)
	var morph_count := f.get_32()
	var morph_tracks := {}
	for i in morph_count:
		var name := normalize_bone_name(_decode_name(f))
		var frame := f.get_32()
		var w := f.get_float()
		var rec := {"frame": frame, "weight": w}
		if not morph_tracks.has(name):
			morph_tracks[name] = []
		morph_tracks[name].append(rec)
	_sort_tracks(morph_tracks)
	f.close()
	return {"fps": FPS, "bone_tracks": bone_tracks, "morph_tracks": morph_tracks}

func _sort_tracks(tracks: Dictionary) -> void:
	for k in tracks.keys():
		var arr: Array = tracks[k]
		arr.sort_custom(func(a, b): return a["frame"] < b["frame"])

# 解 15 字节定长 Shift-JIS 名字（NUL 截断）。单字节 ASCII 直读；
# 半角片假名(0xA1-0xDF) 与双字节(0x81-0x9F/0xE0-0xFC 起) 查 SJIS_MAP。
func _decode_name(f: FileAccess) -> String:
	var raw := PackedByteArray()
	raw.resize(15)
	for i in 15:
		raw[i] = f.get_8()
	var out := ""
	var i := 0
	while i < 15:
		var b := raw[i]
		if b == 0:
			break
		if b < 0x80:
			out += String.chr(b)
			i += 1
		elif b >= 0xA1 and b <= 0xDF:
			if SJIS.SJIS_MAP.has(b):
				out += SJIS.SJIS_MAP[b]
			else:
				out += String.chr(b)
			i += 1
		else:
			if i + 1 < 15:
				var cp := (b << 8) | raw[i + 1]
				if SJIS.SJIS_MAP.has(cp):
					out += SJIS.SJIS_MAP[cp]
				else:
					out += "?"
				i += 2
			else:
				i += 1
	return out
