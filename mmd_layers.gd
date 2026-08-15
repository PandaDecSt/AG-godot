class_name MMDLayerController
extends Node

# MMD 渲染「图层栈」控制面板。
# 挂在 ModelRoot 下，_ready 时由 mmd_importer.gd 调用 register() 喂入材质列表与描边对。
# 之后每帧把 Inspector 里的开关/顺序写到所有材质的 layer_mask / layer_order uniform，
# 并统一开关描边层（next_pass）。
#
# 图层 ID 映射（与着色器一致）：
#   0 = TOON 色阶(乘) | 1 = 镜面高光(加) | 2 = 边缘光(加) | 3 = 自发光(加) | 4 = SPHERE 高光
# Inspector 里改这些勾选框 / layer_order 数组，画面即时变化，无需重启。
#
# 注意：bloom 与上述 6 个是「不同性质」的开关——它是全屏后期辉光(对齐原版 bloomEnabled)，
# 作用于整幅画面，不是某个材质的图层，故只能整场景开/关，无法逐物体作用。

@export var toon_enabled := true
@export var specular_enabled := true
@export var rim_enabled := true
@export var emission_enabled := true
@export var sphere_enabled := true
@export var outline_enabled := true
@export var outline_thickness := 1.0   # 描边粗细（约等同于 PMX edgeScale；屏幕空间外扩系数，越大越粗）
@export var bloom_enabled := true      # 全局后期辉光(Glow)开关：勾=开，取消=整场景辉光关闭
@export_range(0.0, 1.0, 0.01) var bloom_threshold := 0.85   # 辉光触发门槛(归一化亮度)：越大越只抓最亮处发光
@export_range(0.0, 1.0, 0.01) var bloom_intensity := 0.08   # 辉光强度：越大光晕越浓（原版极淡≈0.05）

# 景深（DOF / bokeh 散景）：Godot 4.7 已移除 Environment.dof_blur_far_* 原生属性，
# 且 canvas_item 着色器不支持 hint_depth_texture（读不到 3D 深度），故「全屏 canvas_item 后处理」方案已弃用。
# 真·深度 DOF 需改用 CompositorEffect（渲染管线注入，可访问颜色+深度缓冲）。当前 DOF 暂未实现，
# dof_enabled 勾选时仅告警、不崩溃；dof_effect.gdshader 留作参考。待 CompositorEffect 版补齐。
@export var dof_enabled := false
@export_range(1.0, 40.0, 0.5) var dof_focus_distance := 8.0   # 对焦距离（世界单位，从相机算起）
@export_range(0.0, 2.0, 0.05) var dof_aperture := 0.6        # 光圈：越大虚化越强
@export_range(2.0, 48.0, 1.0) var dof_max_blur := 20.0      # 最大模糊半径（像素）

# 抗锯齿（全局渲染设置，挂根视口 Viewport）：
#   Disabled / MSAA 2x / 4x / 8x（多重采样，边缘最干净、不鬼影）/ FXAA / SMAA（屏幕空间后处理，略模糊）。
#   本场景用自定义着色器 + 相机自由旋转，默认 MSAA 4x；不列 TAA（时域累积在相机移动时会产生鬼影）。
@export_enum("Disabled", "MSAA 2x", "MSAA 4x", "MSAA 8x", "FXAA", "SMAA") var aa_mode := "MSAA 4x"
# 柔阴影（挂 SunLight + 项目设置）：
@export_range(0.0, 5.0, 0.1) var shadow_softness := 0.0   # 方向光区域光大小=半影宽度：0=硬阴影(边缘锐利)，越大阴影边缘越柔（实时生效）
@export_range(0.0, 0.5, 0.01) var shadow_bias := 0.3      # 阴影偏移：过小=自阴影痤疮(acne，点状噪点)，过大=悬浮(peter-panning)（实时生效）
@export_range(0.0, 2.0, 0.05) var shadow_normal_bias := 0.9   # 法线偏移：对骨骼蒙皮曲面消 acne 特别有效（实时生效）
@export_enum("Off", "Low", "Medium", "High", "Ultra") var shadow_quality := "Medium"   # PCF 采样质量（项目设置，改后可能需 Reload 当前项目生效）
@export var ground_enabled := true       # 显示/隐藏接收阴影的地面（角色投影落其上；F5 想只看角色可取消勾选）

# 合成顺序：图层 ID 的排列，越靠前越先合成（数组长度保持 5，内容 0..4 互不重复）。
@export var layer_order: Array = [0, 1, 2, 3, 4]

var _mats: Array = []
var _outline_pairs: Array = []   # 元素为 [base_material, outline_material]
var _env: Environment = null      # 缓存场景 Environment（辉光挂在它上面，全屏后期）
var _sun: DirectionalLight3D = null   # 缓存 SunLight 节点（柔阴影参数挂它上面）
var _ground = null                  # 缓存接收阴影的地面（显隐由 ground_enabled 控制）
var _last_aa := ""
var _last_soft := -1.0
var _last_bias := -1.0
var _last_nb := -1.0
var _last_sq := ""
const DOF_EFFECT := preload("res://dof_compositor.gd")
var _dof_effect: DOFEffect = null


func register(materials: Array, outline_pairs: Array) -> void:
	_mats = materials
	_outline_pairs = outline_pairs

# 由 mmd_importer.gd 在生成地面后调用，把地面节点交给本面板统一显隐。
func set_ground(g) -> void:
	_ground = g

func _ready() -> void:
	# 诊断：确认是否拿到了材质/描边对（排查“调厚度没反应”）。
	# 同时立即应用一次，保证运行首帧就有正确值。
	print("LC ready: pairs=%d thickness=%.2f" % [_outline_pairs.size(), outline_thickness])
	_process(0.0)


func _process(_dt: float) -> void:
	var mask := 0
	if toon_enabled:
		mask |= 1
	if specular_enabled:
		mask |= 2
	if rim_enabled:
		mask |= 4
	if emission_enabled:
		mask |= 8
	if sphere_enabled:
		mask |= 16

	var order_arr := _normalize_order(layer_order)
	for mat in _mats:
		if mat == null:
			continue
		mat.set_shader_parameter("layer_mask", mask)
		mat.set_shader_parameter("layer_order", order_arr)

	for pair in _outline_pairs:
		var base_mat: ShaderMaterial = pair[0]
		var out_mat: ShaderMaterial = pair[1]
		if base_mat == null:
			continue
		base_mat.next_pass = out_mat if outline_enabled else null
		if out_mat != null:
			out_mat.set_shader_parameter("edge_size", outline_thickness)

	# 全局后期辉光：由 WorldEnvironment 挂到 world_3d 的 Environment 控制（整场景开/关）。
	# _env 在 WorldEnv._ready 之后才有效，故延迟到 _process 首次取，取到后缓存复用。
	if _env == null:
		var w3d = get_viewport().get_world_3d()
		if w3d != null:
			_env = w3d.environment
	if _env != null:
		_env.glow_enabled = bloom_enabled
		_env.glow_normalized = true        # 关键：阈值按归一化亮度解释，否则 0~1 画面抓不到亮区、辉光静默不亮
		_env.glow_hdr_threshold = bloom_threshold
		_env.glow_intensity = bloom_intensity
		_apply_dof()

	# 抗锯齿 + 柔阴影：全局渲染设置，运行时改（对齐 bloom 面板化思路，统一在 LayerController 调参）。
	if _sun == null:
		_sun = get_parent().get_node_or_null("SunLight")
	_apply_aa()
	_apply_shadow()
	if _ground != null:
		_ground.visible = ground_enabled


# 抗锯齿：映射到根视口 Viewport 的 msaa_3d / screen_space_aa 属性（运行时即时生效）。
# 用根视口而非 get_viewport()，避免挂在子 Window 时只改到子窗口（Godot 已知坑）。
func _apply_aa() -> void:
	if aa_mode == _last_aa:
		return
	_last_aa = aa_mode
	var vp := get_tree().get_root().get_viewport()
	match aa_mode:
		"Disabled":
			vp.msaa_3d = Viewport.MSAA_DISABLED
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		"MSAA 2x":
			vp.msaa_3d = Viewport.MSAA_2X
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		"MSAA 4x":
			vp.msaa_3d = Viewport.MSAA_4X
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		"MSAA 8x":
			vp.msaa_3d = Viewport.MSAA_8X
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		"FXAA":
			vp.msaa_3d = Viewport.MSAA_DISABLED
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
		"SMAA":
			vp.msaa_3d = Viewport.MSAA_DISABLED
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA

# 柔阴影：半影宽度(shadow_softness→light_angular_distance) 与 偏移(shadow_bias) 是 DirectionalLight3D 实时属性；
# 采样质量(shadow_quality) 走项目设置，改后通常即时，个别驱动可能需 Reload 当前项目。
func _apply_shadow() -> void:
	if _sun != null:
		if shadow_softness != _last_soft:
			_sun.light_angular_distance = shadow_softness
			_last_soft = shadow_softness
		if shadow_bias != _last_bias:
			_sun.shadow_bias = shadow_bias
			_last_bias = shadow_bias
		if shadow_normal_bias != _last_nb:
			_sun.shadow_normal_bias = shadow_normal_bias
			_last_nb = shadow_normal_bias
	if shadow_quality != _last_sq:
		_last_sq = shadow_quality
		var q := 2
		match shadow_quality:
			"Off":
				q = 0
			"Low":
				q = 1
			"Medium":
				q = 2
			"High":
				q = 3
			"Ultra":
				q = 4
		ProjectSettings.set_setting("rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality", q)

# 景深（DOF）：Godot 4.7 无原生 Environment DOF，故用自定义全屏后处理。
# 首次调用时建一个最上层 CanvasLayer + ColorRect（挂 dof_effect.gdshader），之后每帧把面板参数写进去；
# dof_enabled=false 时把 ColorRect 隐藏（不采样、零开销）。
# 景深（DOF）：Godot 4.7 无原生 Environment DOF，改用 CompositorEffect（渲染管线注入，RD 级）读颜色+深度缓冲做 bokeh。
# 挂在活动 Camera3D 的 compositor.compositor_effects 上（Godot 4.7 属性名是 compositor_effects，不是 effects）；dof_enabled 控制 effect.enabled（关闭时引擎直接跳过本 effect，不崩）。
func _ensure_dof() -> void:
	if _dof_effect != null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	if cam.compositor == null:
		cam.compositor = Compositor.new()
	_dof_effect = DOF_EFFECT.new()
	# 注意：compositor_effects 的 getter 返回数组副本，直接 .append() 不会持久化，
	# 必须“读出来→append→整段写回”才生效（无头实测 REF a.size=1 c.size=0，ASSIGN c.size=1 验证）。
	var fx_list := cam.compositor.compositor_effects
	if not fx_list.has(_dof_effect):
		fx_list.append(_dof_effect)
		cam.compositor.compositor_effects = fx_list

func _apply_dof() -> void:
	if _dof_effect == null:
		_ensure_dof()
	if _dof_effect == null:
		return
	_dof_effect.enabled = dof_enabled
	_dof_effect.dof_on = 1.0 if dof_enabled else 0.0
	_dof_effect.focus_distance = dof_focus_distance
	_dof_effect.aperture = dof_aperture
	_dof_effect.max_blur = dof_max_blur
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		_dof_effect.cam_near = cam.near
		_dof_effect.cam_far = cam.far

# 把用户填的 layer_order 规整成长度 5、0..4 各出现一次的排列（多去少补）。
func _normalize_order(arr: Array) -> PackedInt32Array:
	var seen := {}
	var out := PackedInt32Array()
	for v in arr:
		var id: int = int(v)
		if id >= 0 and id <= 4 and not seen.has(id):
			out.append(id)
			seen[id] = true
	for id in 5:
		if not seen.has(id):
			out.append(id)
	return out
