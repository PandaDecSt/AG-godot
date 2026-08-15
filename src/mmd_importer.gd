extends Node3D

# MMD 导入器（纯 GDScript 从零写）。
# 流程：PMXLoader 解析 → MMDModelBuilder 构建骨骼+网格+材质 → 挂到场景 →
#       自动取景相机 → 每帧把 SunLight 的视线空间光照方向喂给各材质（fragment 拿不到内置光照）。
const PMX_PATH := "res://models/model.pmx"

# ---- VMD 动作 ----
# motions.vmd：17040 骨骼帧/545 轨、130 表情帧/72 轨，骨骼名命中 504/545、表情命中 71/72
#（未命中的是模型里没有的多余发丝骨与 Mouth_Offest_Do，可忽略）。
# 同目录另有 motion.vmd 是纯表情且只命中 22/191 —— 那是给别的模型做的，不要用。
const VMD_PATH := "res://models/motions.vmd"
const AUTO_PLAY := true

# 运行期自动调试截图（debug_normal.png / debug_albedo.png）：默认关闭。
# 注意：开启后 F5 约 2.2 秒会把所有材质闪切到 debug_mode=1（纯贴图/无光照）0.2 秒再切回，
# 观感上像"光照突然切换又变回"，易误判。需要 AI 读图诊断时手动设 true 再 F5。
const AUTO_DEBUG_SHOTS := false

var _mats: Array = []
var _outline_pairs: Array = []
var _layer_ctrl = null
var _sun: DirectionalLight3D = null
var _cam: Camera3D = null
var _ground = null   # 接收阴影的地面（动态生成），交给 LayerController 统一显隐
var _player: VMDPlayer = null
var _time_slider: HSlider = null
var _time_label: Label = null
# 播放 HUD 里的勾选框引用，供键盘快捷键同步显示状态
var _chk_loop: CheckBox = null
var _chk_ik: CheckBox = null
var _chk_append: CheckBox = null
var _chk_morph: CheckBox = null

# reze 预设系统：当前 look pack / grade 与预设模块实例（运行态）
var _mp_presets = null          # MaterialPresets 实例（运行态动态加载，避免依赖全局类表）
var _cur_pack: String = "ag"    # 当前 look pack（ag / wuwa）
var _cur_grade: String = "Neutral"
# 逐部位编辑：role -> Array[ShaderMaterial]（由材质 meta "mp_role" 分组）
var _role_mats: Dictionary = {}
var _role_pick: OptionButton = null   # 部位选择下拉
var _role_edit_box: VBoxContainer = null  # 当前部位参数控件容器
var _editing_role: String = ""

# 逐材质预设指派：材质名 -> 其所属 ShaderMaterial 数组（PMX 材质名可能重复，故用数组）
var _mat_map: Dictionary = {}
var _mat_list: Array = []
var _mat_pick: OptionButton = null       # 部件（材质）选择下拉
var _preset_pick: OptionButton = null    # 目标预设选择下拉
var _mat_preset_label: Label = null      # 显示当前部件生效的预设
var _sel_mat_name: String = ""

# ---- 现代化 HUD 系统（取代原先散落、会挡画面/文字溢出的固定坐标面板）----
var _hud_layer = null          # CanvasLayer（layer 128）
var _hud_theme: Theme = null   # 统一主题（圆角半透明 + 紫色强调）
var _hud_toggle: Button = null # 常驻「≡ 面板」开关
var _hud_docks: Control = null  # 面板容器（整体隐藏用），鼠标穿透空白处
var _hud_visible: bool = true
var _left_dock: PanelContainer = null
var _right_dock: PanelContainer = null
var _left_scroll: ScrollContainer = null
var _right_scroll: ScrollContainer = null
var _left_w: float = 312.0
var _right_w: float = 346.0


func _ready() -> void:
	print("=== MMD build start ===")
	var loader := PMXLoader.new()
	var model := loader.parse(PMX_PATH)
	if model.is_empty():
		print("PARSE FAILED")
		return

	# ---- 解析校验（对照 WebGPU 权威基准）----
	print("name=%s" % model["name"])
	print("vertices=%d" % model["vertices"].size())
	print("indices=%d" % model["indices"].size())
	print("textures=%d" % model["textures"].size())
	print("materials=%d" % model["materials"].size())
	print("bones=%d" % model["bones"].size())
	print("morphs=%d" % model["morphs"].size())
	var vmorph := 0
	for m in model["morphs"]:
		if m["type"] == 1:
			vmorph += 1
	print("vertexMorphs=%d" % vmorph)
	print("rigidbodies=%d" % model["rigidbodies"].size())
	print("joints=%d" % model["joints"].size())

	# ---- 构建骨骼 + 网格 + 材质 ----
	var builder := MMDModelBuilder.new()
	var res := builder.build(model, "res://models")
	add_child(res["root"])

	var mi: MeshInstance3D = res["mesh_instance"]
	var surf_count := mi.mesh.get_surface_count()
	print("mesh surfaces=%d (期望=%d)" % [surf_count, model["materials"].size()])

	# 收集各 surface 材质，供每帧更新光照
	for s in surf_count:
		var sm := mi.mesh.surface_get_material(s)
		if sm != null:
			_mats.append(sm)

	# 收集描边层（base 材质 → 其 next_pass 描边材质），供图层面板统一开关
	for mat in _mats:
		if mat != null and mat.next_pass != null:
			_outline_pairs.append([mat, mat.next_pass])

	# ---- reze 预设系统：初始化模块实例并套用默认 look pack(AG) + grade(Neutral) ----
	# 设置全局 uniform（exposure/tonemap_mode/world_color/saturation/contrast/grade 分色调），
	# 让角色一进场景就是 reze AG 风格（filmic@0.6 + 品红世界色），而非着色器硬编码默认值。
	_mp_presets = (load("res://src/material_presets.gd") as Script).new()
	_cur_pack = _mp_presets.default_pack()
	_cur_grade = "Neutral"
	_build_role_mats()          # 按材质 meta "mp_role" 分组，供逐部位编辑器与 pack 切换用
	_build_mat_list()           # 按材质 meta "mp_name" 建部件列表，供逐材质预设指派 HUD
	_apply_preset(_cur_pack, _cur_grade)

	# 「图层栈」控制面板 LayerController 是 main.tscn 里与 ModelRoot 平级的静态节点
	# （直接挂 Main 下，避免作为 ModelRoot 子节点时 Godot 实例化报
	#  "Parent path './ModelRoot' has vanished" 的良性 warning 并被迫兜底挂错父）。
	# 这里只喂入材质与描边对。
	var lc = get_parent().get_node_or_null("LayerController")
	if lc == null:
		lc = get_node_or_null("/root/Main/LayerController")   # 兜底：按场景根绝对路径找
	if lc != null:
		lc.register(_mats, _outline_pairs)
		_layer_ctrl = lc
	else:
		print("WARN: 未找到 LayerController 节点，图层开关/调序不可用")

	# 相机与灯光引用
	_cam = get_parent().get_node_or_null("Camera") as Camera3D
	_sun = get_parent().get_node_or_null("SunLight") as DirectionalLight3D
	if _sun == null:
		_sun = get_tree().get_first_node_in_group("sun") as DirectionalLight3D
	# 运行期强制太阳角度+阴影参数（关键：避免"只 F5 不重开"导致 .tscn 改动不生效）。
	# 这样无论 Godot 有没有重载场景，F5 后太阳一定是 65° 仰角、阴影开启。
	if _sun != null:
		_sun.rotation_degrees = Vector3(-65, 0, 0)
		_sun.shadow_enabled = true
		_sun.light_angular_distance = 0.0
		# 与面板(LayerController)默认值保持一致，避免 _ready 时序把 bias 打回旧值造成首帧痤疮。
		_sun.shadow_bias = 0.3
		_sun.shadow_normal_bias = 0.9

	# ---- 把模型中心/尺寸写入 meta，供自由相机(free_camera.gd)自动取景 ----
	var aabb := mi.mesh.get_aabb()
	set_meta("mmd_center", aabb.get_center())
	set_meta("mmd_size", aabb.size)
	print("model aabb center=%s size=%s" % [aabb.get_center(), aabb.size])

	# ---- 地面（静态节点 ShadowGround 已在 main.tscn 中定义：水平、接收阴影、不投射）----
	# 这里只沿 Y 把它移到模型最低点之下，让角色投影正好落在脚边；并交给 LayerController 统一显隐。
	# 做成静态节点而非运行时 new()，是为了规避“外部改 .gd 后编辑器未重编译”导致旋转/生成不生效的坑。
	_ground = get_parent().get_node_or_null("ShadowGround")
	if _ground != null:
		# 关键：Godot 的 PlaneMesh【默认就是水平地面】（法线=本地+Y，顶点在 XZ 平面）。
		# 千万别绕 X 转 ±90°——那会把它立成竖直黑面！这里强制零旋转锁死水平。
		_ground.rotation_degrees = Vector3(0, 0, 0)
		var bottom := aabb.position.y   # 地面落在模型最低点（脚边），略微下沉避免 z-fighting
		_ground.position = Vector3(_ground.position.x, bottom - 0.01, _ground.position.z)
		# 运行期强制地面外观（关键：避免"只 F5 不重开"导致 .tscn 改动不生效）。
		# 亮蓝灰 + 不投射阴影 + 默认接收阴影 → 角色影子落上去对比明显。
		var gm: StandardMaterial3D = _ground.material_override
		if gm != null and gm is StandardMaterial3D:
			gm.albedo_color = Color(0.62, 0.64, 0.68)
			gm.roughness = 1.0
		_ground.cast_shadow = 0
		# 诊断：用【真实法线轴 +Y】验证运行时确实水平（之前误测 +Z 轴导致误判）
		var n = _ground.transform.basis * Vector3(0, 1, 0)
		print("GROUND rotation=", _ground.rotation_degrees, " normal_world=", n, " HORIZONTAL=", n.y > 0.9)
		if _layer_ctrl != null:
			_layer_ctrl.set_ground(_ground)
	else:
		print("WARN: 未找到静态 ShadowGround 节点，角色投影无处可落（检查 main.tscn）")

	# 运行期强制环境光（同样为避免"只 F5 不重开"导致 .tscn 改动不生效）：调低让地面阴影对比更分明。
	var we = get_parent().get_node_or_null("WorldEnv")
	if we != null and we.environment != null:
		we.environment.ambient_light_energy = 0.5

	# 注：隔离用“白方块”已改为 main.tscn 里的静态节点 ShadowTestBox（避免“外部改 .gd 后 F5 不重编译”导致不出现）。
	# 见 main.tscn 的 [node name="ShadowTestBox"]。

	for i in min(3, model["materials"].size()):
		var mm: Dictionary = model["materials"][i]
		print("  mat[%d]=%s edge=%s" % [i, mm["name"], (mm["flag"] & 0x10) != 0])

	# ---- 运行期诊断（排查“没贴图”）：把前几个材质真实的 uniform 打出来 ----
	for i in min(6, _mats.size()):
		var sm := _mats[i] as ShaderMaterial
		if sm == null:
			print("MATDIAG[%d] 不是 ShaderMaterial" % i)
			continue
		var ua = sm.get_shader_parameter("use_albedo")
		var at = sm.get_shader_parameter("albedo_tex")
		var ap := ""
		if at != null:
			ap = at.resource_path
		var bt = sm.get_shader_parameter("base_tint")
		print("MATDIAG[%d] use_albedo=%s albedo=%s base_tint=%s" % [i, ua, ap, bt])

	_update_light()

	# 描边诊断：究竟生成了几个描边对、多少材质带 edge flag（排查“开关没区别”）
	var edge_flag_cnt := 0
	for m in model["materials"]:
		if (m["flag"] & 0x10) != 0:
			edge_flag_cnt += 1
	print("OUTLINE_PAIRS=%d (材质带 edge flag 数=%d / 总材质=%d)" % [_outline_pairs.size(), edge_flag_cnt, model["materials"].size()])

	# ---- VMD 动作：解析 + 挂播放器 ----
	# 必须在 add_child(res["root"]) 之后：VMDPlayer.setup 里的 pose 语义自探测要调
	# skeleton.get_bone_global_pose()，骨骼需已在场景树内。
	_setup_motion(model, res)

	print("=== MMD build done ===")

	# ---- 自动截图：供 AI 直接读图诊断，无需用户描述画面 ----
	# 默认开启。F5 后约 2.2 秒，项目目录会多出 debug_normal.png / debug_albedo.png。
	#   debug_normal = 当前着色结果；debug_albedo = 强制纯贴图（排查“贴图是否到达 GPU”）。
	if AUTO_DEBUG_SHOTS:
		_capture_debug_shots()

	# 运行态 HUD：现代化面板系统（左上=播放/外观，右上=材质预设；H 键可整体隐藏）
	_init_hud()


# ---- 动作装配 ----
func _setup_motion(model: Dictionary, res: Dictionary) -> void:
	if not FileAccess.file_exists(VMD_PATH):
		print("WARN: 找不到动作文件 %s，模型将保持静止站姿" % VMD_PATH)
		return
	var vl := VMDLoader.new()
	var vmd := vl.parse(VMD_PATH)
	if vmd.is_empty():
		print("WARN: VMD 解析失败，模型将保持静止站姿")
		return
	print("VMD model_name=%s 骨骼轨=%d 表情轨=%d" % [
		vmd.get("model_name", "?"), vmd["bone_tracks"].size(), vmd["morph_tracks"].size()])

	_player = VMDPlayer.new()
	_player.name = "VMDPlayer"
	add_child(_player)
	# 表情要同时写给【可见网格】和【阴影副本】：两者共享同一 ArrayMesh，
	# 但 blend shape 权重是 per-MeshInstance3D 的，只写一个会让影子停在无表情姿态。
	var targets: Array = [res["mesh_instance"]]
	var shadow := (res["skeleton"] as Skeleton3D).get_node_or_null("MMDMeshShadow")
	if shadow != null:
		targets.append(shadow)
	_player.setup(res["skeleton"], model["bones"], vmd, targets, res["mesh"], model["morphs"])
	_player.playing = AUTO_PLAY


func _capture_debug_shots() -> void:
	await get_tree().create_timer(2.0).timeout
	var vp := get_viewport()
	var names := ["normal", "albedo"]
	var modes := [0, 1]
	for i in modes.size():
		# 切到对应调试模式（第一帧已是 mode=0）
		for mat in _mats:
			if mat != null:
				mat.set_shader_parameter("debug_mode", modes[i])
		# 等渲染帧就绪（无头模式必须 process_frame 后纹理才可取）
		await get_tree().process_frame
		await get_tree().process_frame
		var img := vp.get_texture().get_image()
		if img != null:
			var p: String = "res://debug_" + names[i] + ".png"
			img.save_png(p)
			print("DEBUGSHOT %s -> %s" % [names[i], ProjectSettings.globalize_path(p)])
		else:
			print("DEBUGSHOT %s: get_image() 返回 null" % names[i])
	# 复位
	for mat in _mats:
		if mat != null:
			mat.set_shader_parameter("debug_mode", 0)


func _process(_dt: float) -> void:
	_update_light()
	# 播放进度回写 HUD（用 no_signal 避免触发 seek 造成自激）
	if _player != null and _time_slider != null:
		_time_slider.set_value_no_signal(_player.time)
		if _time_label != null:
			_time_label.text = "%.2f / %.2f s  %s" % [
				_player.time, _player.duration, "▶ 播放中" if _player.playing else "⏸ 暂停"]


# 自检开关：按 F9 把角色所有材质切到【阴影衰减视图】(debug_mode=4 → 显示 ATTENUATION)。
# 自定义着色器 mmd_material.gdshader 第145行明确响应 debug_mode==4：DIFFUSE_LIGHT = vec3(ATTENUATION)。
# ATTENUATION 是方向光阴影衰减：1=无阴影(角色表面亮白) / 0=全阴影(角色表面全黑)。
# 用途：若角色表面出现【点状明暗噪点】= 影子副本 MMDMeshShadow 在阴影深度通道有自阴影(acne) → shadow map 本身就是噪点 → 地面收到噪点阴影。
#        若角色表面【干净平滑】(整体白、只有被遮挡处整块黑) = shadow map 正常，点状来自别处(如接收端/分辨率)。
# 再按一次 F9 切回正常渲染。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F9:
				for mat in _mats:
					if mat == null:
						continue
					# 注意：get_shader_parameter 返回 Variant，uniform 未初始化时可能是 Nil，
					# 不能标 : int 否则报 "assign value of type 'Nil' to a variable of type 'int'"。
					var cur = mat.get_shader_parameter("debug_mode")
					if cur == null:
						cur = 0
					mat.set_shader_parameter("debug_mode", 4 if cur == 0 else 0)
				var shown = _mats[0].get_shader_parameter("debug_mode") if (_mats.size() > 0 and _mats[0] != null) else -1
				print("F9 debug_mode -> ", shown, " (4=看阴影衰减视图/点状即acne确诊; 0=正常)")
			KEY_SPACE:
				if _player != null:
					_player.toggle_play()
					print("SPACE 播放状态 -> ", "播放中" if _player.playing else "暂停")
			KEY_R:
				if _player != null:
					_player.rewind_to_start()
					_player.playing = true
					print("R 重播")
			KEY_I:
				if _player != null and _chk_ik != null:
					_player.ik_enabled = not _player.ik_enabled
					_chk_ik.button_pressed = _player.ik_enabled
					print("I IK -> ", _player.ik_enabled)
			KEY_M:
				if _player != null and _chk_morph != null:
					_player.morph_enabled = not _player.morph_enabled
					_chk_morph.button_pressed = _player.morph_enabled
					if not _player.morph_enabled:
						_player.clear_all_morphs()
					print("M 表情 -> ", _player.morph_enabled)
			KEY_H:
				_on_hud_toggle()
				print("H HUD 面板 -> ", "显示" if _hud_visible else "隐藏")


func _update_light() -> void:
	if _sun == null or _cam == null or _mats.is_empty():
		return
	# DirectionalLight3D 沿自身 -Z 照射，故“指向光源”方向 = 自身 +Z 轴（世界空间）。
	# 直接传世界空间光向；着色器里用 inverse(VIEW_MATRIX) 把 NORMAL/VIEW 转回世界空间后再点积，
	# 对齐 AfterglowWeb main-fs.ts 的 worldNormal·lightDir（toon 明暗是几何体相对场景光的真实 terminator，
	# 不随相机变化）。不要再转成相机局部空间，否则明暗交界算错。
	var world_dir: Vector3 = (_sun.global_transform.basis * Vector3(0, 0, 1)).normalized()
	var col: Color = _sun.light_color * _sun.light_energy
	# AfterglowWeb 的 scene.lightColor 固定为 (2,2,2)（pmx-viewer.ts:750），Godot 默认光强为 1；
	# 这里乘 2 对齐原版亮度，用户仍可经 SunLight.light_energy 二次调节。
	var col3: Vector3 = Vector3(col.r, col.g, col.b) * 2.0
	for mat in _mats:
		if mat != null:
			mat.set_shader_parameter("light_dir", world_dir)
			mat.set_shader_parameter("light_color", col3)


# ============================================================
#  现代化 HUD 系统（取代原先散落、会挡画面 / 文字溢出的多个固定坐标面板）
#  - 所有面板停靠在【左上 / 右上】边缘，永不直接盖住居中的角色
#  - 面板可整体隐藏（按钮 / 快捷键 H），且每个面板可单独折叠
#  - 视口缩放时自动夹取尺寸与位置，文字 / 控件绝不会跑到窗口外
#  - 半透明圆角深色 + 紫色强调色，统一 Theme；空白处鼠标穿透到 3D 视口
# ============================================================

# 统一主题：圆角半透明面板 + 紫色强调 + 合适字号
func _make_hud_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 14
	var pnl := StyleBoxFlat.new()
	pnl.bg_color = Color(0.09, 0.10, 0.14, 0.88)
	pnl.set_border_width_all(1)
	pnl.border_color = Color(0.46, 0.32, 0.78, 0.85)
	pnl.corner_radius_top_left = 12; pnl.corner_radius_top_right = 12
	pnl.corner_radius_bottom_left = 12; pnl.corner_radius_bottom_right = 12
	pnl.content_margin_left = 12; pnl.content_margin_right = 12
	pnl.content_margin_top = 10; pnl.content_margin_bottom = 12
	t.set_stylebox("panel", "PanelContainer", pnl)
	var btn := StyleBoxFlat.new()
	btn.bg_color = Color(0.24, 0.17, 0.40, 1.0)
	btn.set_corner_radius_all(8)
	t.set_stylebox("normal", "Button", btn)
	var btn_h := StyleBoxFlat.new()
	btn_h.bg_color = Color(0.36, 0.25, 0.58, 1.0)
	btn_h.set_corner_radius_all(8)
	t.set_stylebox("hover", "Button", btn_h)
	t.set_color("font_color", "Label", Color(0.92, 0.93, 0.97))
	t.set_color("font_color", "Button", Color(0.96, 0.95, 1.0))
	return t


# 生成一个带标题栏（可折叠）+ 滚动内容区的停靠面板。
# content 由调用方提供（左侧放 VBox，右侧放 TabContainer）。
func _make_dock(title: String, content: Control) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _make_dock_style())
	var vb := VBoxContainer.new()
	vb.name = "VB"
	vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.add_child(vb)
	var hb := HBoxContainer.new()
	vb.add_child(hb)
	var t := Label.new()
	t.text = title
	t.add_theme_color_override("font_color", Color(0.82, 0.68, 1.0))
	t.add_theme_font_size_override("font_size", 15)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(t)
	var collapse := Button.new()
	collapse.text = "▾"
	collapse.custom_minimum_size = Vector2(30, 24)
	hb.add_child(collapse)
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(scroll)
	scroll.add_child(content)
	collapse.pressed.connect(func():
		scroll.visible = not scroll.visible
		collapse.text = "▾" if scroll.visible else "▸")
	return p


func _make_dock_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.09, 0.10, 0.14, 0.88)
	s.set_border_width_all(1)
	s.border_color = Color(0.46, 0.32, 0.78, 0.85)
	s.set_corner_radius_all(12)
	s.content_margin_left = 12; s.content_margin_right = 12
	s.content_margin_top = 10; s.content_margin_bottom = 12
	return s


# 把面板锚到左上（具体矩形在 _on_viewport_resize 里按视口夹取）。
func _pin_dock(p: Control, w: float) -> void:
	p.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	p.custom_minimum_size = Vector2(w, 0)


func _add_hsep(vb: VBoxContainer) -> void:
	var h := HSeparator.new()
	h.modulate = Color(1, 1, 1, 0.18)
	vb.add_child(h)


func _mk_label(txt: String) -> Label:
	var l := Label.new()
	l.text = txt
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


# 构建整个 HUD（在 _ready 末尾调用一次，取代原先 5 个散落的 _add_*_hud）。
func _init_hud() -> void:
	if _mp_presets == null:
		_mp_presets = (load("res://src/material_presets.gd") as Script).new()
	_hud_theme = _make_hud_theme()

	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 128
	get_tree().root.call_deferred("add_child", _hud_layer)

	# 全局开关（常驻可见，用于唤回面板）
	_hud_toggle = Button.new()
	_hud_toggle.text = "≡ 面板"
	_hud_toggle.theme = _hud_theme
	_hud_toggle.tooltip_text = "显示 / 隐藏所有控制面板（快捷键 H）"
	_hud_toggle.custom_minimum_size = Vector2(86, 32)
	_hud_toggle.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_hud_toggle.offset_right = -12.0
	_hud_toggle.offset_top = 12.0
	_hud_toggle.offset_left = -12.0 - 86.0
	_hud_toggle.offset_bottom = 12.0 + 32.0
	_hud_toggle.pressed.connect(_on_hud_toggle)
	_hud_layer.add_child(_hud_toggle)

	# 面板容器（可被整体隐藏）；设为 IGNORE 让空白处的鼠标穿透到 3D 视口
	_hud_docks = Control.new()
	_hud_docks.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud_docks.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(_hud_docks)

	# 左停靠：播放 / 外观
	var left_vb := VBoxContainer.new()
	left_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left_dock = _make_dock("播放 / 外观", left_vb)
	_pin_dock(_left_dock, _left_w)
	_hud_docks.add_child(_left_dock)
	_left_scroll = _left_dock.get_node("VB/Scroll") as ScrollContainer
	_build_left_dock(left_vb)

	# 右停靠：材质预设（reze）— 两个标签页
	var tabs := TabContainer.new()
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_right_dock = _make_dock("材质预设 (reze)", tabs)
	_pin_dock(_right_dock, _right_w)
	_hud_docks.add_child(_right_dock)
	_right_scroll = _right_dock.get_node("VB/Scroll") as ScrollContainer
	_build_right_dock(tabs)

	_hud_visible = true
	get_viewport().size_changed.connect(_on_viewport_resize)
	_on_viewport_resize()
	print("HUD: 现代化面板已构建（左侧=播放/外观，右侧=材质预设；H 键可隐藏）")


func _on_hud_toggle() -> void:
	_hud_visible = not _hud_visible
	_hud_docks.visible = _hud_visible
	_hud_toggle.text = "≡ 面板" if _hud_visible else "≡ 显示"


# 视口尺寸变化时重新夹取面板矩形（左/右上停靠，高度按视口夹取，内容过多则在面板内滚动）
func _on_viewport_resize() -> void:
	if _hud_layer == null:
		return
	var vp = get_viewport().size
	var m := 12.0
	# 左停靠（左上角）
	var lw := minf(_left_w, maxf(160.0, vp.x - 2.0 * m))
	_left_dock.custom_minimum_size = Vector2(lw, 0)
	_left_dock.offset_left = m
	_left_dock.offset_top = 12.0
	_left_dock.offset_right = m + lw
	_left_dock.offset_bottom = 12.0 + maxf(140.0, vp.y - 12.0 - m)
	# 右停靠（右上角，但避开顶部开关按钮：top=58）
	var rw := minf(_right_w, maxf(180.0, vp.x - 2.0 * m))
	_right_dock.custom_minimum_size = Vector2(rw, 0)
	_right_dock.offset_right = vp.x - m
	_right_dock.offset_top = 58.0
	_right_dock.offset_left = vp.x - m - rw
	_right_dock.offset_bottom = 58.0 + maxf(140.0, vp.y - 58.0 - m)


# ---- 左侧停靠内容：动作播放 + 描边 + reze Look/Grade ----
func _build_left_dock(vb: VBoxContainer) -> void:
	if _player != null:
		var head := Label.new(); head.text = "动作"; head.add_theme_font_size_override("font_size", 14); vb.add_child(head)
		_time_label = Label.new(); _time_label.text = "0.00 / %.2f s" % _player.duration; vb.add_child(_time_label)
		_time_slider = HSlider.new()
		_time_slider.min_value = 0.0; _time_slider.max_value = maxf(_player.duration, 0.001)
		_time_slider.step = 0.01; _time_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vb.add_child(_time_slider)
		_time_slider.drag_ended.connect(func(changed: bool):
			if changed and _player != null: _player.seek(_time_slider.value))
		var sp_row := Label.new(); sp_row.text = "速度 1.00x"; vb.add_child(sp_row)
		var sp := HSlider.new(); sp.min_value = 0.1; sp.max_value = 2.0; sp.step = 0.05; sp.value = 1.0
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL; vb.add_child(sp)
		sp.value_changed.connect(func(v: float):
			if _player != null: _player.speed = v
			sp_row.text = "速度 %.2fx" % v)
		var row := HBoxContainer.new(); vb.add_child(row)
		_chk_loop = _mk_check("循环", _player.loop, func(on: bool): _player.loop = on)
		_chk_ik = _mk_check("IK", _player.ik_enabled, func(on: bool): _player.ik_enabled = on)
		_chk_append = _mk_check("付与親", _player.append_enabled, func(on: bool): _player.append_enabled = on)
		_chk_morph = _mk_check("表情", _player.morph_enabled, func(on: bool):
			_player.morph_enabled = on; if not on: _player.clear_all_morphs())
		row.add_child(_chk_loop); row.add_child(_chk_ik); row.add_child(_chk_append); row.add_child(_chk_morph)
		_add_hsep(vb)
	if _layer_ctrl != null:
		var ol := Label.new(); ol.text = "描边粗细"; vb.add_child(ol)
		var ols := HSlider.new(); ols.min_value = 0.0; ols.max_value = 8.0; ols.step = 0.1
		ols.value = _layer_ctrl.outline_thickness; ols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vb.add_child(ols)
		ols.value_changed.connect(func(v: float):
			if _layer_ctrl != null: _layer_ctrl.outline_thickness = v)
		_add_hsep(vb)
	if _mp_presets != null:
		var rh := Label.new(); rh.text = "reze 预设（Look / Grade）"
		rh.add_theme_color_override("font_color", Color(0.82, 0.68, 1.0)); vb.add_child(rh)
		var looks: Array = _mp_presets.look_list()
		var look_btn := OptionButton.new(); look_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for p in looks: look_btn.add_item(p)
		look_btn.selected = maxi(0, looks.find(_cur_pack)); vb.add_child(look_btn)
		look_btn.item_selected.connect(func(idx: int):
			if idx >= 0 and idx < looks.size(): _apply_preset(looks[idx], _cur_grade))
		var grades: Array = _mp_presets.grade_list()
		var grade_btn := OptionButton.new(); grade_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for g in grades: grade_btn.add_item(g)
		grade_btn.selected = maxi(0, grades.find(_cur_grade)); vb.add_child(grade_btn)
		grade_btn.item_selected.connect(func(idx: int):
			if idx >= 0 and idx < grades.size(): _apply_preset(_cur_pack, grades[idx]))
	var hint := Label.new()
	hint.text = "空格=播/停  R=重播  I=IK  M=表情  H=面板"
	hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.78))
	hint.add_theme_font_size_override("font_size", 11)
	vb.add_child(hint)


# ---- 右侧停靠内容：标签页「逐部位编辑」+「部件预设指派」----
func _build_right_dock(tabs: TabContainer) -> void:
	# 标签 1：逐部位预设编辑
	var t1 := ScrollContainer.new(); t1.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	t1.size_flags_horizontal = Control.SIZE_EXPAND_FILL; t1.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var v1 := VBoxContainer.new(); v1.size_flags_horizontal = Control.SIZE_EXPAND_FILL; t1.add_child(v1)
	tabs.add_child(t1); tabs.set_tab_title(tabs.get_child_count() - 1, "逐部位编辑")
	_role_pick = OptionButton.new(); _role_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var roles: Array = _mp_presets.role_list()
	for r in roles:
		if _role_mats.has(r) and _role_mats[r].size() > 0:
			_role_pick.add_item(r)
	if _role_pick.item_count > 0:
		_role_pick.selected = 0
		_editing_role = _role_pick.get_item_text(0)
	v1.add_child(_role_pick)
	_role_pick.item_selected.connect(_on_role_selected)
	var reset := Button.new(); reset.text = "还原 reze 默认"; reset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v1.add_child(reset); reset.pressed.connect(_on_role_reset)
	_role_edit_box = VBoxContainer.new(); _role_edit_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v1.add_child(_role_edit_box)
	_rebuild_role_controls()

	# 标签 2：部件材质预设指派
	var t2 := ScrollContainer.new(); t2.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	t2.size_flags_horizontal = Control.SIZE_EXPAND_FILL; t2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var v2 := VBoxContainer.new(); v2.size_flags_horizontal = Control.SIZE_EXPAND_FILL; t2.add_child(v2)
	tabs.add_child(t2); tabs.set_tab_title(tabs.get_child_count() - 1, "部件预设指派")
	if _mat_list.is_empty():
		v2.add_child(_mk_label("（无可用材质）"))
		return
	var ml := Label.new(); ml.text = "① 选择部件（材质）"; v2.add_child(ml)
	_mat_pick = OptionButton.new(); _mat_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for n in _mat_list: _mat_pick.add_item(n)
	v2.add_child(_mat_pick); _mat_pick.item_selected.connect(_on_mat_pick_selected)
	_mat_preset_label = Label.new(); v2.add_child(_mat_preset_label)
	var pl := Label.new(); pl.text = "② 指派到材质预设"; v2.add_child(pl)
	_preset_pick = OptionButton.new(); _preset_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for p in _mp_presets.preset_names(): _preset_pick.add_item(p)
	v2.add_child(_preset_pick)
	var apply_btn := Button.new(); apply_btn.text = "应用所选预设"; apply_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v2.add_child(apply_btn); apply_btn.pressed.connect(_on_mat_preset_apply)
	var reset_btn := Button.new(); reset_btn.text = "还原（用角色默认）"; reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v2.add_child(reset_btn); reset_btn.pressed.connect(_on_mat_preset_reset)
	_sel_mat_name = _mat_list[0]
	_refresh_mat_preset_ui()


# ---- 动作播放 HUD（左下角）----
# 做成运行态 HUD 而不是 Inspector 属性，理由同描边滑块：编辑态改属性对运行时实例不生效。
# （已废弃）原 _add_motion_hud：其逻辑已并入 _build_left_dock，统一进现代化 HUD 系统。
# 保留此注释占位，避免误调用；函数体已移除。


func _mk_check(text: String, pressed: bool, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = pressed
	c.toggled.connect(cb)
	return c


# ---- reze 预设：套用当前 look pack + grade 到全部材质（全局 uniform 逐材质写入）----
# 同时重新套用各部位的角色预设（含运行期覆盖），使切换 look pack 时色阶/边缘光也跟着换
# （AG 灰度色阶 ↔ WuWa 彩色色阶在此切换；与 reze 的「look pack 改变整体观感」一致）。
func _apply_preset(pack: String, grade: String) -> void:
	_cur_pack = pack
	_cur_grade = grade
	if _mp_presets == null:
		return
	for r in _role_mats.keys():
		for mat in _role_mats[r]:
			# 尊重逐材质预设指派：解析「指派优先，否则角色回退」后套用，
			# 这样切 look pack（AG↔WuWa）时，被改指派成 silk 的布料仍保持 silk、其余跟随 pack。
			_apply_mat_with_override(mat, pack, r)
	_mp_presets.apply_look(_mats, pack, grade)
	# 编辑器若已打开，刷新成当前 pack 的值
	if _role_edit_box != null and _editing_role != "":
		_rebuild_role_controls()
	print("PRESET apply_look pack=%s grade=%s  (材质数=%d)" % [pack, grade, _mats.size()])


# 按材质 meta "mp_role" 把 _mats 分组：role -> Array[ShaderMaterial]。
func _build_role_mats() -> void:
	_role_mats.clear()
	for mat in _mats:
		if mat == null or not mat.has_meta("mp_role"):
			continue
		var r: String = mat.get_meta("mp_role")
		if not _role_mats.has(r):
			_role_mats[r] = []
		_role_mats[r].append(mat)


# 按材质 meta "mp_name" 建部件列表（供逐材质预设指派 HUD 选中具体部件）。
func _build_mat_list() -> void:
	_mat_map.clear()
	_mat_list.clear()
	for mat in _mats:
		if mat == null or not mat.has_meta("mp_name"):
			continue
		var n: String = mat.get_meta("mp_name")
		if not _mat_map.has(n):
			_mat_map[n] = []
		_mat_map[n].append(mat)
		if not _mat_list.has(n):
			_mat_list.append(n)


# 解析「逐材质指派优先，否则角色回退」后套用预设（供 pack 切换 / 指派应用共用）。
func _apply_mat_with_override(mat: ShaderMaterial, pack: String, role_fallback: String) -> void:
	var mat_name: String = mat.get_meta("mp_name", "")
	_mp_presets.apply_material(mat, pack, mat_name, role_fallback)


# ---- reze 逐部位编辑 HUD（右上角）：选部位→拉滑块/取色器→实时套用，带「还原 reze 默认」----
# 对齐 reze-design 的「对每个部位的材质修改着色器预设」：节点图参数可单独调、随场景生效。
# （已废弃）原 _add_role_editor：其逻辑已并入 _build_right_dock（"逐部位编辑" 标签页）。
# 保留此注释占位，避免误调用；函数体已移除。


func _on_role_selected(idx: int) -> void:
	if _role_pick == null or idx < 0 or idx >= _role_pick.item_count:
		return
	_editing_role = _role_pick.get_item_text(idx)
	_rebuild_role_controls()


# 重建当前部位的参数控件（读取 get_role_params，反映 reze 默认或运行期覆盖）。
func _rebuild_role_controls() -> void:
	if _role_edit_box == null or _editing_role == "":
		return
	for c in _role_edit_box.get_children():
		c.queue_free()
	var params: Dictionary = _mp_presets.get_role_params(_cur_pack, _editing_role)

	# 色阶三段（暗端 / 中间 / 亮端）取色器
	var toon: Array = params.get("toon", [[0.30, 0.30, 0.30], [0.65, 0.65, 0.65], [1.0, 1.0, 1.0]])
	var tnames := ["色阶·暗端", "色阶·中间", "色阶·亮端"]
	for i in 3:
		var row := HBoxContainer.new()
		var lab := Label.new()
		lab.text = tnames[i]
		lab.custom_minimum_size = Vector2(86, 0)
		row.add_child(lab)
		var cp := ColorPickerButton.new()
		cp.color = Color(toon[i][0], toon[i][1], toon[i][2])
		row.add_child(cp)
		cp.color_changed.connect(_on_role_toon_color_changed.bind(i))
		_role_edit_box.add_child(row)

	# 标量滑块（来自 material_presets.ROLE_SLIDERS）
	for s in _mp_presets.ROLE_SLIDERS:
		var key: String = s["key"]
		var row := HBoxContainer.new()
		var lab := Label.new()
		lab.text = s["label"]
		lab.custom_minimum_size = Vector2(86, 0)
		row.add_child(lab)
		var sl := HSlider.new()
		sl.min_value = float(s["min"]); sl.max_value = float(s["max"]); sl.step = float(s["step"])
		sl.value = float(params.get(key, 1.0))
		sl.custom_minimum_size = Vector2(130, 0)
		row.add_child(sl)
		var val := Label.new()
		val.text = "%.2f" % sl.value
		val.custom_minimum_size = Vector2(44, 0)
		row.add_child(val)
		sl.value_changed.connect(func(v: float):
			val.text = "%.2f" % v
			_on_role_slider_changed(key, v))
		_role_edit_box.add_child(row)

	# 边缘光颜色取色器
	var rc: Array = params.get("rim_color", [1.0, 0.85, 0.7])
	var rrow := HBoxContainer.new()
	var rlab := Label.new()
	rlab.text = "边缘光颜色"
	rlab.custom_minimum_size = Vector2(86, 0)
	rrow.add_child(rlab)
	var rcp := ColorPickerButton.new()
	rcp.color = Color(rc[0], rc[1], rc[2])
	rrow.add_child(rcp)
	rcp.color_changed.connect(_on_role_rim_color_changed)
	_role_edit_box.add_child(rrow)


func _on_role_slider_changed(key: String, v: float) -> void:
	if _editing_role == "":
		return
	_mp_presets.set_role_override(_cur_pack, _editing_role, key, v)
	_reapply_editing_role()


func _on_role_toon_color_changed(c: Color, idx: int) -> void:
	if _editing_role == "":
		return
	var params: Dictionary = _mp_presets.get_role_params(_cur_pack, _editing_role)
	var cols: Array = params.get("toon", [[0.30, 0.30, 0.30], [0.65, 0.65, 0.65], [1.0, 1.0, 1.0]]).duplicate(true)
	cols[idx] = [c.r, c.g, c.b]
	_mp_presets.set_role_override(_cur_pack, _editing_role, "toon", cols)
	_reapply_editing_role()


func _on_role_rim_color_changed(c: Color) -> void:
	if _editing_role == "":
		return
	_mp_presets.set_role_override(_cur_pack, _editing_role, "rim_color", [c.r, c.g, c.b])
	_reapply_editing_role()


func _reapply_editing_role() -> void:
	if _editing_role == "" or not _role_mats.has(_editing_role):
		return
	for mat in _role_mats[_editing_role]:
		# 只重套「当前仍生效为该角色」的材质；已被改指派成别的预设（如 silk）的部件不受影响。
		if _effective_preset(mat, _editing_role) == _editing_role:
			_mp_presets.apply_role(mat, _cur_pack, _editing_role)


# 取某材质当前生效的预设名（逐材质指派优先，否则角色回退）。
func _effective_preset(mat: ShaderMaterial, role_fallback: String) -> String:
	var mat_name: String = mat.get_meta("mp_name", "")
	return _mp_presets.get_material_preset(mat_name, role_fallback)


func _on_role_reset() -> void:
	if _editing_role == "":
		return
	_mp_presets.clear_role_override(_cur_pack, _editing_role)
	_reapply_editing_role()
	_rebuild_role_controls()


# ---- reze 预设：逐材质预设指派 HUD（顶部中间）----
# 实现 reze「对模型的不同部位应用不同的材质预设」：选中某个部件（材质），
# 从目录里挑一套目标预设（角色预设 / 材质类型扩展如 leather·silk），
# 整块部件换上该预设的全部参数，其他部件不受影响；「还原」回到它自动归类的角色。
# （已废弃）原 _add_material_reassign_hud：其逻辑已并入 _build_right_dock（"部件预设指派" 标签页）。
# 保留此注释占位，避免误调用；函数体已移除。


func _refresh_mat_preset_ui() -> void:
	if _mat_pick == null or _preset_pick == null or _sel_mat_name == "":
		return
	var role: String = ""
	if _mat_map.has(_sel_mat_name) and _mat_map[_sel_mat_name].size() > 0:
		role = _mat_map[_sel_mat_name][0].get_meta("mp_role", "")
	var eff: String = _mp_presets.get_material_preset(_sel_mat_name, role)
	_mat_preset_label.text = "当前生效预设：%s\n（自动归类角色：%s）" % [eff, role]
	var pidx: int = 0
	for i in _preset_pick.item_count:
		if _preset_pick.get_item_text(i) == eff:
			pidx = i
			break
	_preset_pick.selected = pidx


func _on_mat_pick_selected(idx: int) -> void:
	if idx < 0 or idx >= _mat_pick.item_count:
		return
	_sel_mat_name = _mat_pick.get_item_text(idx)
	_refresh_mat_preset_ui()


func _on_mat_preset_apply() -> void:
	if _sel_mat_name == "" or not _mat_map.has(_sel_mat_name):
		return
	var chosen: String = _preset_pick.get_item_text(_preset_pick.selected)
	var mats: Array = _mat_map[_sel_mat_name]
	var role: String = mats[0].get_meta("mp_role", "")
	# 选了和自动角色相同 / default → 视为清除指派（回到角色默认）。
	if chosen == role or chosen == "default":
		_mp_presets.clear_material_preset(_sel_mat_name)
	else:
		_mp_presets.set_material_preset(_sel_mat_name, chosen)
	for mat in mats:
		_apply_mat_with_override(mat, _cur_pack, role)
	_refresh_mat_preset_ui()


func _on_mat_preset_reset() -> void:
	if _sel_mat_name == "" or not _mat_map.has(_sel_mat_name):
		return
	var mats: Array = _mat_map[_sel_mat_name]
	var role: String = mats[0].get_meta("mp_role", "")
	_mp_presets.clear_material_preset(_sel_mat_name)
	for mat in mats:
		_apply_mat_with_override(mat, _cur_pack, role)
	_refresh_mat_preset_ui()


# （已废弃）原 _add_preset_hud：其 Look/Grade 切换逻辑已并入 _build_left_dock。
# 保留此注释占位，避免误调用；函数体已移除。
