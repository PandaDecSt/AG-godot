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

	# 运行态 HUD：屏幕左下角拖滑块即可实时调描边粗细（材质运行态才创建，编辑态拖 Inspector 不生效）
	_add_outline_hud()
	_add_motion_hud()
	_add_preset_hud()   # reze 预设：Look pack / Grade 切换（AG/WuWa + 6 套 grade）


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


# 运行态 HUD：屏幕左下角加一个滑块，直接调描边粗细（解决「编辑态拖 Inspector 不生效」的困惑）
func _add_outline_hud() -> void:
	if _layer_ctrl == null:
		return
	var layer := CanvasLayer.new()
	layer.layer = 128
	var label := Label.new()
	label.text = "描边粗细 Outline"
	label.position = Vector2(16, 8)
	layer.add_child(label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 8.0
	slider.step = 0.1
	slider.value = _layer_ctrl.outline_thickness
	slider.size = Vector2(220, 24)
	slider.position = Vector2(16, 30)
	layer.add_child(slider)
	slider.value_changed.connect(_on_outline_thick)
	get_tree().root.call_deferred("add_child", layer)
	print("HUD: 左下角已添加「描边粗细」滑块（拖动即生效）")


func _on_outline_thick(v: float) -> void:
	if _layer_ctrl != null:
		_layer_ctrl.outline_thickness = v


# ---- 动作播放 HUD（左下角）----
# 做成运行态 HUD 而不是 Inspector 属性，理由同描边滑块：编辑态改属性对运行时实例不生效。
func _add_motion_hud() -> void:
	if _player == null:
		return
	var layer := CanvasLayer.new()
	layer.layer = 128
	var box := VBoxContainer.new()
	box.position = Vector2(16, 70)
	box.custom_minimum_size = Vector2(260, 0)
	layer.add_child(box)

	var head := Label.new()
	head.text = "动作  空格=播/停  R=重播  I=IK  M=表情"
	box.add_child(head)

	_time_label = Label.new()
	_time_label.text = "0.00 / %.2f s" % _player.duration
	box.add_child(_time_label)

	_time_slider = HSlider.new()
	_time_slider.min_value = 0.0
	_time_slider.max_value = maxf(_player.duration, 0.001)
	_time_slider.step = 0.01
	_time_slider.custom_minimum_size = Vector2(240, 20)
	box.add_child(_time_slider)
	# 只有用户真的拖动才 seek；播放时的滑块跟随用 set_value_no_signal 写，避免自激循环
	_time_slider.drag_ended.connect(func(changed: bool):
		if changed and _player != null:
			_player.seek(_time_slider.value))

	var sp_row := Label.new()
	sp_row.text = "速度 1.00x"
	box.add_child(sp_row)
	var sp := HSlider.new()
	sp.min_value = 0.1
	sp.max_value = 2.0
	sp.step = 0.05
	sp.value = 1.0
	sp.custom_minimum_size = Vector2(240, 20)
	box.add_child(sp)
	sp.value_changed.connect(func(v: float):
		if _player != null:
			_player.speed = v
		sp_row.text = "速度 %.2fx" % v)

	var row := HBoxContainer.new()
	box.add_child(row)
	_chk_loop = _mk_check("循环", _player.loop, func(on: bool): _player.loop = on)
	_chk_ik = _mk_check("IK", _player.ik_enabled, func(on: bool): _player.ik_enabled = on)
	_chk_append = _mk_check("付与親", _player.append_enabled, func(on: bool): _player.append_enabled = on)
	_chk_morph = _mk_check("表情", _player.morph_enabled, func(on: bool):
		_player.morph_enabled = on
		if not on:
			_player.clear_all_morphs())
	row.add_child(_chk_loop)
	row.add_child(_chk_ik)
	row.add_child(_chk_append)
	row.add_child(_chk_morph)

	get_tree().root.call_deferred("add_child", layer)
	print("HUD: 左下角已添加「动作播放」面板（时间/速度/循环/IK/付与親/表情）")


func _mk_check(text: String, pressed: bool, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = pressed
	c.toggled.connect(cb)
	return c


# ---- reze 预设：套用当前 look pack + grade 到全部材质（全局 uniform 逐材质写入）----
func _apply_preset(pack: String, grade: String) -> void:
	_cur_pack = pack
	_cur_grade = grade
	if _mp_presets == null:
		return
	_mp_presets.apply_look(_mats, pack, grade)
	print("PRESET apply_look pack=%s grade=%s  (材质数=%d)" % [pack, grade, _mats.size()])


# ---- reze 预设 HUD（左下角）：Look pack（AG/WuWa）与 Grade（6 套）实时切换 ----
# 对齐 reze-design 的「对不同材质有具体的预设图方案」：AG/WuWa 两套整体风格 +
# 6 套 color grade，运行时一键切换，无需重开场景。
func _add_preset_hud() -> void:
	if _mp_presets == null:
		_mp_presets = (load("res://src/material_presets.gd") as Script).new()
	var layer := CanvasLayer.new()
	layer.layer = 128
	var box := VBoxContainer.new()
	box.position = Vector2(16, 360)
	box.custom_minimum_size = Vector2(240, 0)
	layer.add_child(box)

	var head := Label.new()
	head.text = "reze 预设  Look / Grade"
	box.add_child(head)

	# Look pack 下拉（ag / wuwa）
	var looks: Array = _mp_presets.look_list()
	var look_btn := OptionButton.new()
	for p in looks:
		look_btn.add_item(p)
	look_btn.selected = maxi(0, looks.find(_cur_pack))
	box.add_child(look_btn)
	look_btn.item_selected.connect(func(idx: int):
		if idx < 0 or idx >= looks.size():
			return
		_apply_preset(looks[idx], _cur_grade))

	# Grade 下拉（6 套）
	var grades: Array = _mp_presets.grade_list()
	var grade_btn := OptionButton.new()
	for g in grades:
		grade_btn.add_item(g)
	grade_btn.selected = maxi(0, grades.find(_cur_grade))
	box.add_child(grade_btn)
	grade_btn.item_selected.connect(func(idx: int):
		if idx < 0 or idx >= grades.size():
			return
		_apply_preset(_cur_pack, grades[idx]))

	get_tree().root.call_deferred("add_child", layer)
	print("HUD: 左下角已添加「reze 预设」面板（Look pack:%s / Grade:%s 切换）" % [_cur_pack, _cur_grade])
