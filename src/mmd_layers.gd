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
#   本场景用自定义着色器 + 相机自由旋转，默认 MSAA 4x。
#   TAA 时域抗锯齿单独做成开关（taa_enabled）：默认关——它把上一帧画面“拖”进来做累积，
#   自由旋转相机时会产生鬼影/拖影；想对比观感（远处抖动更顺）可临时勾上，看完再取消。
@export_enum("Disabled", "MSAA 2x", "MSAA 4x", "MSAA 8x", "FXAA", "SMAA") var aa_mode := "MSAA 4x"
@export var taa_enabled := false   # TAA 时域抗锯齿开关：勾=开（远处抖动更顺，但转相机有鬼影/拖影），取消=关（默认，画面干净）。运行时即时生效
@export var shadow_enabled := true   # 阴影主开关：勾=开启(角色自阴影+地面投影)，取消=完全关闭阴影显示。注意与下方 shadow_quality 的 "Off" 不同——"Off" 是【硬边阴影】(仍渲染)，本开关才是【不渲染阴影】
# 柔阴影（挂 SunLight + 项目设置）：
@export_range(0.0, 5.0, 0.1) var shadow_softness := 2.0   # 方向光区域光大小=半影宽度(→light_angular_distance)：0=硬阴影(边缘锐利)，越大 PCF 模糊越宽、把 15-tap 采样的颗粒平均掉（实时生效）。脸部自阴影默认给一点柔和半影遮低分辨率纹素边；调太大阴影会糊(与"脸要清晰"冲突)，故不过度加
@export_range(0.0, 4.0, 0.1) var shadow_blur := 0.0   # 阴影模糊半径倍增(→_sun.shadow_blur)：与上方 light_angular_distance(PCSS角径)是【两个不同机制】。官方文档提示：blur 越大，会把过滤产生的颗粒图案【越明显】(故默认0，先不动)。你加这个是为了亲手对比 shadow_blur 与 shadow_softness 的区别（实时生效，需 softness>0 才看得出效果）
@export_range(0.0, 0.5, 0.01) var shadow_bias := 0.5      # 阴影偏移：过小=自阴影痤疮(acne，点状噪点)，过大=悬浮(peter-panning)（实时生效）。开柔阴影后 PCF 跨纹素采样，需比硬阴影更大的 bias 才能压住黑点
@export_range(0.0, 2.0, 0.05) var shadow_normal_bias := 0.9   # 法线偏移：对骨骼蒙皮曲面消 acne 特别有效（实时生效）
@export_enum("Off", "Low", "Medium", "High", "Ultra") var shadow_pcf_quality := "Ultra"   # 阴影采样质量(PCF 采样级别)：3D 方向光唯一的“调高 PCF 采样”开关，经 RenderingServer.directional_soft_shadow_filter_set_quality() 运行时实时生效(无需重载)。档位=采样数/模糊质量：Off=硬边(0采样平滑)、Low=1、Medium=2、High=4、Ultra=5(最多采样→边缘最平滑、颗粒最细)。⚠️"Off"=硬边阴影(仍渲染、只是边缘锐利)，【不是】关闭阴影显示——要彻底关阴影请用上方 shadow_enabled。Godot 枚举 Ultra=5(非4)。
# 阴影分辨率 + 覆盖范围（方向光阴影尺寸是【项目级设置】，不是逐光源属性；本工程已 8192=最大）：
@export_enum("2048", "4096", "8192") var shadow_texture_size := "8192"   # 方向光阴影图尺寸：经 RenderingServer.directional_shadow_atlas_set_size() 运行时实时生效(无需重载)；越大脸部纹素越密、越清晰（占显存，单角色 8192 足够；降 4096 可省显存）
@export_range(20.0, 200.0, 5.0) var shadow_max_distance := 60.0   # 方向光阴影覆盖范围(世界单位)：越小，同样的 8192 阴影图被压进越浅的深度→每世界单位纹素数越密→PCF 颗粒越少、脸自阴影越锐利(实时生效)。代价：超出范围的地面不再接收阴影。角色特写 15~25 最佳，拉远看全身可调大
# 阴影分屏模式（治“投远放大”条纹的关键）：
#   "PSSM 4-split" = 默认，视锥按相机距离切 4 段、每段独立阴影图。远段分辨率低→角色高、影子投远→落进远段→条纹被放大(你看到的症状)。
#   "Single ortho"  = 不分屏，整段用【一张】正交阴影图(分辨率沿深度均匀分布，无“远段稀释”)。这正是 reze 的做法(单张紧贴角色阴影图)。
#                     代价：单图覆盖 0..max_distance 整段，若 max_distance 过大近处会偏糊；故配合把 max_distance 收到角色+落地影子范围内(≈40~60)即干净。
#                     此模式 = “路A”在 Godot 内的原生实现(单张紧贴阴影图)，无需自研纹理模糊管线(那要改引擎)。
@export_enum("PSSM 4-split", "Single ortho") var shadow_mode := "PSSM 4-split"
@export var shadow_blend_splits := false   # 分屏接缝平滑(仅 PSSM 模式有效)：牺牲一点细节换分段间过渡更顺，对“规则条纹/接缝亮带”有帮助。Single 模式忽略
@export_range(0.0, 100.0, 1.0) var shadow_pancake_size := 20.0   # 阴影相机近平面偏移(提高有效深度分辨率)：默认20；若出现大物体边缘伪影可下调(设0=关闭)。Single 模式下调可进一步压条纹
# 贴身阴影框（治“近处锯齿/远段条纹”的免费杠杆）：
#   每帧把 directional_shadow_max_distance 自动收到“刚好包住 角色 + 它投到地面的影子落点 + 余量”。
#   8192 阴影图因此压进最小世界范围→密度最高→脚下/投远影子都最清晰。无额外 GPU 开销（阴影图本来就每帧重画）。
#   代价：Godot 阴影范围绑定相机视锥，故密度上限仍受“相机离角色多远”卡着——相机近时最干净，相机远时效果有限。
@export var shadow_tight_fit := true   # 勾=自动贴身收紧(覆盖下方手动值)；取消=用上方 shadow_max_distance 手动值
@export_range(1.0, 20.0, 0.5) var shadow_tight_margin := 4.0   # 贴身余量(世界单位)：防影子落点被切边；越小密度越高但越易丢远端影子
@export_range(1.0, 5.0, 0.1) var shadow_tight_bias_boost := 2.0   # 贴身模式 bias 补偿倍数：max_distance 收紧→阴影图深度精度升高→曲面自遮挡(acne)更易显，按(60/fit_md)比例×此倍数放大 bias 压住(手动模式不受影响)
@export var ground_enabled := true       # 显示/隐藏接收阴影的地面（角色投影落其上；F5 想只看角色可取消勾选）

# 合成顺序：图层 ID 的排列，越靠前越先合成（数组长度保持 5，内容 0..4 互不重复）。
@export var layer_order: Array = [0, 1, 2, 3, 4]

var _mats: Array = []
var _outline_pairs: Array = []   # 元素为 [base_material, outline_material]
var _env: Environment = null      # 缓存场景 Environment（辉光挂在它上面，全屏后期）
var _sun: DirectionalLight3D = null   # 缓存 SunLight 节点（柔阴影参数挂它上面）
var _ground: Node3D = null          # 缓存接收阴影的地面（显隐由 ground_enabled 控制）
var _last_aa := ""
var _last_taa := false
var _last_soft := -1.0
var _last_blur := -1.0
var _last_bias := -1.0
var _last_nb := -1.0
var _tight_prec := 1.0           # 贴身模式精度补偿因子(仅 tight 模式>1)；bias 每帧按其放大以压 acne
var _last_tight_prec := 1.0
var _last_sq := ""
var _last_ts := ""
var _last_md := -1.0
var _last_mode := ""
var _last_blend := false
var _last_pancake := -1.0
var _last_tight := true          # shadow_tight_fit 上次值(切换时清缓存强制重写)
var _last_fit_md := -1.0         # 贴身模式算出的 max_distance 上次值
var _char_mesh: VisualInstance3D = null   # 角色网格(取世界 AABB 用)，懒解析缓存
var _last_shadow_on := true
const DOF_EFFECT := preload("res://src/dof_compositor.gd")
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
	_apply_taa()
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

# TAA 时域抗锯齿：独立于 MSAA/FXAA 的全局开关。
# 关键坑：TAA 是「视口属性」(Viewport.use_taa)，不是单纯的项目设置——运行时改 ProjectSettings
# 不会让已在跑的根视口重新套用，必须直接写根视口的 use_taa 属性才会即时生效。
# （之前硬编码在 project.godot 是“加载时”读进根视口的，所以那时有效；纯运行时改 setting 无效。）
# TAA 把历史帧累积进当前帧做超采样，远处高频抖动更顺，但相机运动时历史帧对不齐 → 鬼影/拖影。
# 本场景相机自由旋转，故默认关；想对比观感可临时勾上 taa_enabled（运行时即时生效）。
func _apply_taa() -> void:
	if taa_enabled == _last_taa:
		return
	_last_taa = taa_enabled
	var vp := get_tree().get_root().get_viewport()
	vp.use_taa = taa_enabled
	# 同步项目设置（作为“默认值”保持一致；个别驱动在窗口重配置时会回读，避免被覆盖回关）。
	ProjectSettings.set_setting("rendering/anti_aliasing/quality/use_taa", taa_enabled)

# 柔阴影：半影宽度(shadow_softness→light_angular_distance)、偏移(shadow_bias/shadow_normal_bias)、覆盖范围(shadow_max_distance) 是 DirectionalLight3D 实时属性；
# 而采样质量(shadow_pcf_quality)、阴影图尺寸(shadow_texture_size) 虽是方向光【整屏共享】设置(非逐光源)，但 Godot 提供 RenderingServer 运行时接口，可直接实时调整(无需改 project.godot、无需重载项目)。
func _apply_shadow() -> void:
	if _sun != null:
		if shadow_enabled != _last_shadow_on:
			_sun.shadow_enabled = shadow_enabled
			_last_shadow_on = shadow_enabled
		if shadow_softness != _last_soft:
			_sun.light_angular_distance = shadow_softness
			_last_soft = shadow_softness
		if shadow_blur != _last_blur:
			_sun.shadow_blur = shadow_blur
			_last_blur = shadow_blur
		if shadow_bias != _last_bias or _tight_prec != _last_tight_prec:
			_sun.shadow_bias = shadow_bias * _tight_prec
			_last_bias = shadow_bias
			_last_tight_prec = _tight_prec
		if shadow_normal_bias != _last_nb or _tight_prec != _last_tight_prec:
			_sun.shadow_normal_bias = shadow_normal_bias * _tight_prec
			_last_nb = shadow_normal_bias
			_last_tight_prec = _tight_prec
		# 阴影图分辨率：方向光【整屏共享】阴影图；尺寸用 RenderingServer 运行时接口直接设，实时生效、无需改 project.godot、无需重载。
		if shadow_texture_size != _last_ts:
			var ts := 8192
			match shadow_texture_size:
				"2048": ts = 2048
				"4096": ts = 4096
				"8192": ts = 8192
			RenderingServer.directional_shadow_atlas_set_size(ts, true)  # true=16bit 深度(省显存且质量无损)
			_last_ts = shadow_texture_size
		# 阴影覆盖范围：方向光逐光源属性，实时生效。
		# 贴身模式(shadow_tight_fit)下每帧自动收到“角色+地面影子落点+余量”，密度最高；
		# 否则用手动 shadow_max_distance。模式切换时强制重写(清两个缓存)。
		if shadow_tight_fit != _last_tight:
			_last_md = -1.0
			_last_fit_md = -1.0
			_last_tight = shadow_tight_fit
		if shadow_tight_fit:
			var fit_md := _compute_tight_max_distance()
			if fit_md > 0.0:
				if abs(fit_md - _last_fit_md) > 0.5:
					_sun.directional_shadow_max_distance = fit_md
					_last_fit_md = fit_md
				# 精度比补偿：基准 60；max_distance 越小→阴影图深度精度越高→曲面自遮挡(acne)越易显，
				# 按此比例放大 bias(再乘用户 boost)压住，避免胸部等凸起曲面冒异常自阴影块。
				_tight_prec = clampf(60.0 / maxf(fit_md, 1.0), 1.0, 6.0) * shadow_tight_bias_boost
			else:
				_tight_prec = 1.0
		else:
			_tight_prec = 1.0
			if shadow_max_distance != _last_md:
				_sun.directional_shadow_max_distance = shadow_max_distance
				_last_md = shadow_max_distance
		# 分屏模式：PSSM 4-split(默认) vs Single ortho(单张紧贴阴影图，reze 式，治投远条纹)。
		if shadow_mode != _last_mode:
			_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS if shadow_mode == "PSSM 4-split" else DirectionalLight3D.SHADOW_ORTHOGONAL
			_last_mode = shadow_mode
		# 分屏接缝平滑(仅 PSSM 模式有效)。
		if shadow_blend_splits != _last_blend:
			_sun.directional_shadow_blend_splits = shadow_blend_splits
			_last_blend = shadow_blend_splits
		# 阴影相机近平面偏移(深度分辨率)；Single 模式下下调可进一步压条纹。
		if shadow_pancake_size != _last_pancake:
			_sun.directional_shadow_pancake_size = shadow_pancake_size
			_last_pancake = shadow_pancake_size
	if shadow_pcf_quality != _last_sq:
		_last_sq = shadow_pcf_quality
		var q := 2
		match shadow_pcf_quality:
			"Off":
				q = 0
			"Low":
				q = 1
			"Medium":
				q = 2
			"High":
				q = 4
			"Ultra":
				q = 5
		RenderingServer.directional_soft_shadow_filter_set_quality(q)  # 运行时实时生效，无需重载

# ---- 贴身阴影框：算“刚好包住角色 + 它投到地面的影子落点”的方向光阴影覆盖范围 ----
# 返回世界单位；<=0 表示尚未就绪(角色/相机/光没解析到)，调用方忽略不改写。
# 机理：8192 阴影图被压进“角色+影子落点”这片最小世界范围 → 每世界单位纹素数最高 → 桌面/投远影子都最锐利。
func _compute_tight_max_distance() -> float:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null or _sun == null:
		return 0.0
	# 角色网格懒解析(模型在 ModelRoot._ready 构建，树序已保证存在；仍容错重试)
	if _char_mesh == null:
		var mr = get_parent().get_node_or_null("ModelRoot")
		if mr != null and mr.get_child_count() > 0:
			_char_mesh = _find_char_mesh(mr)
	if _char_mesh == null:
		return 0.0
	var local_aabb: AABB = _char_mesh.get_aabb()
	var aabb: AABB = _char_mesh.global_transform * local_aabb
	if aabb.size.length() < 0.001:
		return 0.0
	var center: Vector3 = aabb.get_center()    # 世界空间角色中心
	var half_h := aabb.size.y * 0.5
	var top := center + Vector3(0.0, half_h, 0.0)    # 角色头顶(世界)
	var base := center - Vector3(0.0, half_h, 0.0)   # 角色脚底(世界)
	# 地面高度(影子落点所在平面)；无地面节点则取脚底
	var ground_y := base.y
	if _ground != null:
		ground_y = _ground.global_position.y
	# 光照行进方向(从光指向场景)：world_dir 是“指向光源”(光的 +Z)，取反得行进向
	var world_dir: Vector3 = (_sun.global_transform.basis * Vector3(0, 0, 1)).normalized()
	var travel := -world_dir                   # 指向场景(一般向下)
	# 把头顶沿光照方向投到地面，得到影子最远落点
	var landing := top
	if abs(travel.y) > 1e-4:
		var t := (ground_y - top.y) / travel.y
		if t > 0.0:
			landing = top + travel * t
	# 取 相机→{头顶, 脚底, 影子落点} 的最远距离，作为阴影覆盖范围(沿视锥深度)
	var cam_p := cam.global_position
	var d_top := cam_p.distance_to(top)
	var d_base := cam_p.distance_to(base)
	var d_land := cam_p.distance_to(landing)
	var md := maxf(d_top, maxf(d_base, d_land)) + shadow_tight_margin
	md = clampf(md, 15.0, 200.0)              # 太小影子消失、太大无意义
	return md

# 递归找第一个网格实例(MeshInstance3D 已含其子类 SkinnedMesh3D)作为角色 AABB 来源
func _find_char_mesh(from: Node) -> VisualInstance3D:
	if from is MeshInstance3D:
		return from as VisualInstance3D
	for c in from.get_children():
		var r := _find_char_mesh(c)
		if r != null:
			return r
	return null

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
