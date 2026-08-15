class_name MaterialPresets
extends RefCounted

# ============================================================================
# reze-design 材质预设系统（Godot 移植版）
# ----------------------------------------------------------------------------
# reze 的 reze-design 为不同材质角色(body/hair/eye/cloth/metal...) 提供了
# 具体的「预设图方案」(node-graph)，并按 look pack(AG/WuWa) 区分整体渲染风格，
# 再叠加 6 套 color grade。本模块把这些数据忠实复刻成 Godot NPR 着色器的 uniform，
# 让 mmd_builder 在构建材质时按角色自动套用、mmd_importer 在 HUD 上实时切换。
#
# 数据来源（忠实，不臆造）：
#   reze-design/content/graphs.json        —— AG / WuWa 各角色的节点图参数
#   reze-design/content/stage-graphs.json  —— 环境材质（本模块未直接采用，仅对齐思路）
#   reze-design/content/grades.json        —— 6 套 color grade 的色轮/对比/饱和
#   reze-design/lib/materials.ts           —— LookPack 定义(transform/exposure/world)
#   reze-design/lib/scene-settings.ts      —— world 颜色/强度、exposure 语义(2^EV)
#
# 映射关系（reze 节点 → 本着色器 uniform）：
#   ramp_linear_3 / ramp_cardinal  → toon_tex（彩色三段色阶，按角色烘焙）
#   hue_sat.saturation              → mat_saturation（per-material 饱和度）
#   hue_sat.value                   → mat_value（per-material 明度倍率）
#   layer_weight/facing.blend      → rim_strength（边缘光）
#   sphere_map.strength             → sphere_strength（SPHERE 强度）
#   principled(emissive)            → emission_strength
#   look pack transform/exposure    → tonemap_mode / exposure（2^EV）
#   look pack world                 → world_color（乘到环境光，染遍所有表面）
#   grade contrast/saturation       → contrast / saturation
#   grade shadows/highlights 色轮   → grade_shadow_tint / grade_highlight_tint（分色调）
# ============================================================================

const ROLES := ["body", "face", "hair", "eye", "cloth_smooth", "cloth_rough", "stockings", "metal", "accent"]

# 默认 look pack（reze 引擎自动分组默认填 AG）。
const DEFAULT_PACK := "ag"

# ---- AG（Aether Gazer）各角色预设 ----
# toon: 三段色阶 [阴影端, 中间调, 受光端(白)]，取自 reze ramp_cardinal 的 color0/color1 + 白。
# 灰度角色(body/hair/metal/cloth) 的 ramp_constant 用黑→白，故色阶为中性灰。
const AG := {
	"body": {
		"toon": [[0.2426, 0.068, 0.0588], [0.6677, 0.5024, 0.5126], [1.0, 1.0, 1.0]],
		"mat_saturation": 1.5, "mat_value": 1.0,
		"rim_strength": 0.24, "rim_color": [0.9842, 0.611, 0.5736], "rim_power": 3.0,
		"sphere_strength": 1.0, "emission": 0.12,
	},
	"face": {
		"toon": [[0.2426, 0.068, 0.0588], [0.6677, 0.5024, 0.5126], [1.0, 1.0, 1.0]],
		"mat_saturation": 1.6, "mat_value": 1.1,
		"rim_strength": 0.24, "rim_color": [0.9842, 0.611, 0.5736], "rim_power": 3.0,
		"sphere_strength": 1.0, "emission": 0.2,
	},
	"hair": {
		"toon": [[0.0, 0.0, 0.0], [0.5, 0.5, 0.5], [1.0, 1.0, 1.0]],
		"mat_saturation": 1.4, "mat_value": 1.0,
		"rim_strength": 0.5, "rim_color": [1.0, 0.9, 0.85], "rim_power": 2.5,
		"sphere_strength": 1.0, "emission": 0.1,
	},
	"eye": {
		"toon": [[0.15, 0.15, 0.15], [0.6, 0.6, 0.6], [1.0, 1.0, 1.0]],
		"mat_saturation": 1.1, "mat_value": 1.0,
		"rim_strength": 0.2, "rim_color": [0.9, 0.95, 1.0], "rim_power": 3.0,
		"sphere_strength": 1.0, "emission": 1.5,
	},
	"cloth_smooth": {
		"toon": [[0.0, 0.0, 0.0], [0.5, 0.5, 0.5], [1.0, 1.0, 1.0]],
		"mat_saturation": 1.0, "mat_value": 1.0,
		"rim_strength": 0.25, "rim_color": [0.9, 0.9, 0.95], "rim_power": 3.0,
		"sphere_strength": 1.0, "emission": 0.3,
	},
	"cloth_rough": {
		"toon": [[0.0, 0.0, 0.0], [0.5, 0.5, 0.5], [1.0, 1.0, 1.0]],
		"mat_saturation": 1.0, "mat_value": 1.0,
		"rim_strength": 0.22, "rim_color": [0.9, 0.9, 0.95], "rim_power": 3.0,
		"sphere_strength": 1.0, "emission": 0.3,
	},
	"stockings": {
		"toon": [[0.1, 0.1, 0.1], [0.55, 0.55, 0.55], [1.0, 1.0, 1.0]],
		"mat_saturation": 1.0, "mat_value": 1.15,
		"rim_strength": 0.4, "rim_color": [0.95, 0.9, 0.95], "rim_power": 2.0,
		"sphere_strength": 1.0, "emission": 0.1,
	},
	"metal": {
		"toon": [[0.0, 0.0, 0.0], [0.5, 0.5, 0.5], [1.0, 1.0, 1.0]],
		"mat_saturation": 1.2, "mat_value": 1.0,
		"rim_strength": 0.3, "rim_color": [1.0, 0.95, 0.85], "rim_power": 2.5,
		"sphere_strength": 1.0, "emission": 0.4,
	},
	"accent": {
		"toon": [[0.1, 0.1, 0.1], [0.55, 0.55, 0.55], [1.0, 1.0, 1.0]],
		"mat_saturation": 1.2, "mat_value": 1.0,
		"rim_strength": 0.3, "rim_color": [1.0, 0.9, 0.8], "rim_power": 3.0,
		"sphere_strength": 1.0, "emission": 0.15,
	},
}

# ---- WuWa（Wuthering Waves）各角色预设 ----
# toon 三段色阶直接取自 reze ramp_linear_3 的 color0/color1/color2（已是彩色）。
const WUWA := {
	"body": {
		"toon": [[0.74, 0.4, 0.44], [1.0, 0.8, 0.78], [1.0, 0.98, 0.97]],
		"mat_saturation": 1.22, "mat_value": 1.0,
		"rim_strength": 0.35, "rim_color": [0.9, 0.95, 1.0], "rim_power": 3.0,
		"sphere_strength": 0.6, "emission": 0.12,
	},
	"face": {
		"toon": [[0.76, 0.48, 0.5], [1.0, 0.86, 0.82], [1.0, 0.99, 0.98]],
		"mat_saturation": 1.05, "mat_value": 1.1,
		"rim_strength": 0.35, "rim_color": [0.9, 0.95, 1.0], "rim_power": 3.0,
		"sphere_strength": 0.35, "emission": 0.15,
	},
	"hair": {
		"toon": [[0.16, 0.22, 0.71], [0.72, 0.66, 0.94], [0.88, 0.9, 1.0]],
		"mat_saturation": 1.22, "mat_value": 1.0,
		"rim_strength": 0.4, "rim_color": [0.9, 0.95, 1.0], "rim_power": 3.0,
		"sphere_strength": 1.35, "emission": 0.1,
	},
	"eye": {
		"toon": [[0.62, 0.58, 0.86], [0.94, 0.9, 1.0], [1.0, 1.0, 1.0]],
		"mat_saturation": 1.12, "mat_value": 1.0,
		"rim_strength": 0.25, "rim_color": [0.9, 0.95, 1.0], "rim_power": 3.0,
		"sphere_strength": 1.0, "emission": 1.0,
	},
	"cloth_smooth": {
		"toon": [[0.34, 0.4, 0.8], [0.92, 0.74, 0.9], [1.0, 0.97, 0.99]],
		"mat_saturation": 1.45, "mat_value": 1.0,
		"rim_strength": 0.35, "rim_color": [0.9, 0.95, 1.0], "rim_power": 3.0,
		"sphere_strength": 0.5, "emission": 0.15,
	},
	"cloth_rough": {
		"toon": [[0.34, 0.4, 0.8], [0.92, 0.74, 0.9], [1.0, 0.97, 0.99]],
		"mat_saturation": 1.3, "mat_value": 1.0,
		"rim_strength": 0.32, "rim_color": [0.9, 0.95, 1.0], "rim_power": 3.0,
		"sphere_strength": 0.5, "emission": 0.15,
	},
	"stockings": {
		"toon": [[0.3, 0.35, 0.6], [0.85, 0.8, 0.92], [1.0, 0.98, 1.0]],
		"mat_saturation": 1.2, "mat_value": 1.1,
		"rim_strength": 0.4, "rim_color": [0.9, 0.95, 1.0], "rim_power": 2.5,
		"sphere_strength": 0.8, "emission": 0.1,
	},
	"metal": {
		"toon": [[0.28, 0.3, 0.5], [0.94, 0.86, 0.68], [1.0, 0.98, 0.9]],
		"mat_saturation": 1.4, "mat_value": 1.0,
		"rim_strength": 0.45, "rim_color": [1.0, 0.95, 0.85], "rim_power": 2.5,
		"sphere_strength": 2.2, "emission": 0.3,
	},
	"accent": {
		"toon": [[0.3, 0.35, 0.7], [0.85, 0.82, 0.95], [1.0, 0.98, 1.0]],
		"mat_saturation": 1.25, "mat_value": 1.0,
		"rim_strength": 0.35, "rim_color": [0.9, 0.95, 1.0], "rim_power": 3.0,
		"sphere_strength": 1.0, "emission": 0.15,
	},
}

# ---- Look pack（整体渲染风格）----
# reze: AG = filmic @ exposure 0.6(EV) world #ed6aff str 0.66
#       WuWa = standard @ exposure 0   world #fdf2f8 str 0.36
# exposure 语义为 EV（曝光值）：mult = 2^EV。AG 0.6 → 1.5157，WuWa 0 → 1.0。
# 本字段直接存乘子。
const LOOK := {
	"ag": {"tonemap_mode": 1, "exposure": 1.5157, "world_hex": "#ed6aff", "world_strength": 0.66},
	"wuwa": {"tonemap_mode": 0, "exposure": 1.0, "world_hex": "#fdf2f8", "world_strength": 0.36},
}

# ---- 6 套 color grade ----
# 取自 reze grades.json。contrast/saturation 直接对应；shadows/highlights 为 [h,s,v] 色轮，
# 用作分色调（split-tone）的暗端/亮端染色。Sakura 仅有 [h,s]（缺 v）→ v 默认 0.5。
const GRADES := {
	"Neutral":    {"contrast": 1.0,  "saturation": 1.0,  "shadow": [0.0, 0.0, 0.0],    "high": [0.0, 0.0, 0.0]},
	"Bloody":     {"contrast": 1.45, "saturation": 0.75, "shadow": [358.0, 0.55, 0.36], "high": [2.0, 0.5, 0.545]},
	"Cyberpunk":  {"contrast": 1.42, "saturation": 1.5,  "shadow": [184.0, 0.36, 0.41], "high": [328.0, 0.3, 0.47]},
	"Divine":     {"contrast": 1.15, "saturation": 1.9,  "shadow": [30.0, 0.15, 0.38],  "high": [0.0, 0.18, 0.63]},
	"Moonlit":    {"contrast": 0.95, "saturation": 0.5,  "shadow": [214.0, 0.59, 0.46], "high": [206.0, 0.49, 0.4]},
	"Sakura":     {"contrast": 0.96, "saturation": 1.08, "shadow": [305.0, 0.12], "high": [352.0, 0.18]},
}

# 分色调强度（reze 色轮转 RGB 后叠加，0.6 避免过艳）。
const GRADE_TINT_SCALE := 0.6

var _ramp_cache := {}


# ====================== 对外接口 ======================

func pack_presets(pack: String) -> Dictionary:
	return AG if pack == "ag" else WUWA


func default_pack() -> String:
	return DEFAULT_PACK


func role_list() -> Array:
	return ROLES


func grade_list() -> Array:
	return GRADES.keys()


func look_list() -> Array:
	return LOOK.keys()


# 子串判定：用 String.find(sub)>=0（比 contains 更可靠，避开本版本 contains 的异常行为）。
func _has(n: String, sub: String) -> bool:
	return n.find(sub) >= 0


# 把 PMX 材质名自动分类成角色（对齐 reze 引擎的 auto-grouping）。
# 匹配不到返回 "default"（构建时保留 PMX 自带 toon，不套角色预设）。
func classify_role(name: String) -> String:
	var n := name.to_lower()
	# 眼睛（优先级最高，避免被 hair/cloth 误吞）
	if _has(n, "eye") or _has(n, "目") or _has(n, "アイ") or _has(n, "瞳") or _has(n, "まつげ") or _has(n, " eyelash") or _has(n, "まゆ") or _has(n, "brow"):
		return "eye"
	# 头发
	if _has(n, "hair") or _has(n, "髪") or _has(n, "ヘア") or _has(n, "毛"):
		return "hair"
	# 袜子 / 丝袜
	if _has(n, "sock") or _has(n, "stock") or _has(n, "ストッキング") or _has(n, "ソックス") or _has(n, "靴下") or _has(n, "タイツ") or _has(n, "tights") or _has(n, "ニーソ") or _has(n, "panty") or _has(n, "ガータ"):
		return "stockings"
	# 脸 / 皮肤（名含 face/頭/顔 归 face，其余身体相关归 body）
	if _has(n, "face") or _has(n, "head") or _has(n, "頭") or _has(n, "肌") or _has(n, "スキン") or _has(n, "skin") or _has(n, "体") or _has(n, "body") or _has(n, "ボディ") or _has(n, "裸") or _has(n, "上半身") or _has(n, "下半身") or _has(n, "首") or _has(n, "手") or _has(n, "足") or _has(n, "arm") or _has(n, "leg") or _has(n, "歯") or _has(n, "齿") or _has(n, "舌") or _has(n, "唇") or _has(n, "口腔"):
		if _has(n, "face") or _has(n, "頭") or _has(n, "ヘッド") or _has(n, "頬") or _has(n, "口") or _has(n, "顔") or _has(n, "nose") or _has(n, "chin"):
			return "face"
		return "body"
	# 金属（先判 metal，再判配饰）
	if _has(n, "metal") or _has(n, "金属") or _has(n, "鎧") or _has(n, "armor") or _has(n, "鎖") or _has(n, "環") or _has(n, "チェーン") or _has(n, "chain"):
		return "metal"
	# 配饰（缎带/装饰/首饰）
	if _has(n, "アクセ") or _has(n, "accessory") or _has(n, "装飾") or _has(n, "リボン") or _has(n, "ribbon") or _has(n, "装備") or _has(n, "gear") or _has(n, "gem") or _has(n, "宝石") or _has(n, "ジュエル"):
		return "accent"
	# 鞋子
	if _has(n, "shoe") or _has(n, "靴") or _has(n, "ブーツ") or _has(n, "boot"):
		return "cloth_smooth"
	# 布料（衣服/裙/制服等）；粗糙布料走 cloth_rough
	if _has(n, "cloth") or _has(n, "服") or _has(n, "スカート") or _has(n, "skirt") or _has(n, "制服") or _has(n, "ドレス") or _has(n, "dress") or _has(n, "着") or _has(n, "布") or _has(n, "コート") or _has(n, "coat") or _has(n, "ジャケット") or _has(n, "パンツ") or _has(n, "シャツ") or _has(n, "shirt") or _has(n, "スーツ") or _has(n, "suit") or _has(n, "エプロン") or _has(n, "apron"):
		if _has(n, "rough") or _has(n, "绒") or _has(n, "麻") or _has(n, "ニット") or _has(n, "knit") or _has(n, "フリース") or _has(n, "毛布") or _has(n, "ベルベット") or _has(n, "velvet"):
			return "cloth_rough"
		return "cloth_smooth"
	return "default"


# 取某角色在某 pack 下的三段色阶颜色（找不到则回退中性灰）。
func role_ramp_colors(pack: String, role: String) -> Array:
	var presets := pack_presets(pack)
	if presets.has(role) and presets[role].has("toon"):
		return presets[role]["toon"]
	# 中性灰度色阶（视觉接近旧版回退 ramp，避免背光死黑）
	return [[0.30, 0.30, 0.30], [0.65, 0.65, 0.65], [1.0, 1.0, 1.0]]


# 烘焙某角色在某 pack 下的 toon 色阶贴图（128×1 RGBA，缓存复用）。
func bake_ramp(pack: String, role: String) -> Texture2D:
	var key := pack + ":" + role
	if _ramp_cache.has(key):
		return _ramp_cache[key]
	var cols: Array = role_ramp_colors(pack, role)
	var c0 := Color(cols[0][0], cols[0][1], cols[0][2])
	var c1 := Color(cols[1][0], cols[1][1], cols[1][2])
	var c2 := Color(cols[2][0], cols[2][1], cols[2][2])
	var img := Image.create(128, 1, false, Image.FORMAT_RGBA8)
	for x in 128:
		var t := float(x) / 127.0
		var c: Color
		if t < 0.5:
			c = c0.lerp(c1, t / 0.5)
		else:
			c = c1.lerp(c2, (t - 0.5) / 0.5)
		img.set_pixel(x, 0, Color(c.r, c.g, c.b, 1.0))
	var tex := ImageTexture.create_from_image(img)
	_ramp_cache[key] = tex
	return tex


# 对单个材质套用角色预设（toon 色阶 + per-material uniform）。
# 注意：调用方需【先】用 PMX 自身 toon 设好 toon_tex（见 mmd_builder._build_material），
# 本函数仅在 role 命中时才覆盖 toon_tex 与角色相关 uniform；"default" 仅设中性值、不动 toon。
func apply_role(mat: ShaderMaterial, pack: String, role: String) -> void:
	var presets := pack_presets(pack)
	if role == "default" or not presets.has(role):
		mat.set_shader_parameter("mat_saturation", 1.0)
		mat.set_shader_parameter("mat_value", 1.0)
		mat.set_shader_parameter("sphere_strength", 1.0)
		return
	var p: Dictionary = presets[role]
	mat.set_shader_parameter("toon_tex", bake_ramp(pack, role))
	mat.set_shader_parameter("mat_saturation", p.get("mat_saturation", 1.0))
	mat.set_shader_parameter("mat_value", p.get("mat_value", 1.0))
	mat.set_shader_parameter("sphere_strength", p.get("sphere_strength", 1.0))
	mat.set_shader_parameter("rim_strength", p.get("rim_strength", 0.3))
	var rc: Array = p.get("rim_color", [1.0, 0.85, 0.7])
	mat.set_shader_parameter("rim_color", Vector3(rc[0], rc[1], rc[2]))
	mat.set_shader_parameter("rim_power", p.get("rim_power", 3.0))
	mat.set_shader_parameter("emission_strength", p.get("emission", mat.get_shader_parameter("emission_strength")))


# 对所有材质套用 look pack + grade（全局 uniform，逐材质写入）。
func apply_look(mats: Array, pack: String, grade_name: String) -> void:
	var lp: Dictionary = LOOK.get(pack, LOOK["ag"])
	var world_hex: String = lp["world_hex"]
	var world_col := Color.from_string(world_hex, Color.WHITE)
	# mix(白, world, strength)：strength 越大越偏向 world 色（染遍所有表面）。
	var world_tint := Color.WHITE.lerp(world_col, float(lp["world_strength"]))
	var g: Dictionary = GRADES.get(grade_name, GRADES["Neutral"])

	var shadow_tint := _hsv_to_vec3(g["shadow"]) * GRADE_TINT_SCALE
	var high_tint := _hsv_to_vec3(g["high"]) * GRADE_TINT_SCALE

	for m in mats:
		if not (m is ShaderMaterial):
			continue
		m.set_shader_parameter("exposure", float(lp["exposure"]))
		m.set_shader_parameter("tonemap_mode", int(lp["tonemap_mode"]))
		m.set_shader_parameter("world_color", Vector3(world_tint.r, world_tint.g, world_tint.b))
		m.set_shader_parameter("saturation", float(g["saturation"]))
		m.set_shader_parameter("contrast", float(g["contrast"]))
		m.set_shader_parameter("grade_shadow_tint", shadow_tint)
		m.set_shader_parameter("grade_highlight_tint", high_tint)


# HSV([h°,s,v]) → Vector3(RGB)。h 超出 [0,360] 取模；缺 v 默认 0.5。
func _hsv_to_vec3(hsv: Array) -> Vector3:
	var h := float(hsv[0]) / 360.0
	var s := float(hsv[1]) if hsv.size() > 1 else 0.0
	var v := float(hsv[2]) if hsv.size() > 2 else 0.5
	var c := Color.from_hsv(fmod(h, 1.0), s, v)
	return Vector3(c.r, c.g, c.b)
