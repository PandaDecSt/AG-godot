class_name MMDModelBuilder
extends RefCounted

# 用 PMXLoader 解析出的 model 字典，在 Godot 4.7 里构建：
#   Skeleton3D（骨骼 + 父子 + 局部rest）+ ArrayMesh（按材质切 surface，带 BONES/WEIGHTS）
#   + Skin（create_skin_from_rest_transforms：bind=全局rest逆）+ MeshInstance3D（挂载材质）。
# 为什么不能依赖 create_skin_from_rest_transforms()：该 helper 的 bind pose 取的是
#   get_bone_rest(i) = 骨骼【局部】rest（相对父节点），而 PMX 顶点是【模型空间/全局】坐标。
# 蒙皮着色器算 final = Σ w_i * bone_global_pose_i * bind_pose_i^{-1} * vertex，
# 若 bind_pose=局部rest，静止(pose=IDENTITY)时 bone_matrix = bone_global_pose_i * 局部rest_i^{-1}
#   = 父链全局变换（≠单位矩阵）→ 所有归属于子骨骼的顶点整体被父骨骼的全局姿态平移/旋转，
#   整副炸成认不出人形。必须改用全局 rest（= 沿父链累乘的全局变换）作 bind pose，
#   静止时 bone_matrix=单位矩阵，顶点原样输出。
# 注意：Godot 4.7 的 SurfaceTool 已移除 add_normal/add_uv/add_bones/add_weights，
# 必须改用 ArrayMesh.add_surface_from_arrays() 直接传数组。
# 用法：
#   var b := MMDModelBuilder.new()
#   var res := b.build(model, "res://models", light_dir_view, light_color)
#   get_parent().add_child(res["root"])

# 是否把 Z 取反（MMD 左 handed → Godot 右 handed 的常见修正）。
# 对齐 AfterglowWeb pmx-viewer.ts:743 —— 原版用 mat4.scaling(1,1,-1) 翻转 Z 轴（顶点+法线一起翻），
# 使法线朝外、手性光照正确。Godot 版必须开启，否则法线朝内 → toon 明暗按对内法线算 → 背光死黑/明暗反。
const FLIP_Z := true

# 是否把 PMX 的顶点 morph 注册成 Godot blend shape（表情）。
# 关闭可省约 27MB 显存（60 个 morph × 23024 顶点 × 20B），但表情（眨眼/口型）会全部失效。
const ENABLE_MORPHS := true


func build(model: Dictionary, model_dir: String, light_dir_view: Vector3 = Vector3(0, 0, 1), light_color: Vector3 = Vector3(1, 1, 1), assign_materials: bool = true) -> Dictionary:
	var root := Node3D.new()
	root.name = "MMDModel"

	var skel := Skeleton3D.new()
	root.add_child(skel)

	_build_skeleton(skel, model)

	# ★★★ 用 Godot 官方 create_skin_from_rest_transforms() 建 Skin ★★★
	# 已核对 4.7 源码：该函数先沿父链累乘出【全局rest】，再取逆 set_bind_pose(i, 全局rest^{-1})。
	# 蒙皮公式 = bone_global_pose × bind_pose（源码：skeleton_bone_set_transform = global_pose * skin.get_bind_pose(i)，无额外逆）。
	# 静止(pose=rest → bone_global_pose=全局rest)时：matrix = 全局rest × 全局rest^{-1} = I → 顶点原样，人形正确。
	# 之前手写"正向 global_rest"是错的：matrix 静止=全局rest×全局rest(=全局rest²)，每顶点沿骨链多平移一次 → 整副炸飞。
	var skin: Skin = skel.create_skin_from_rest_transforms()
	skel.register_skin(skin)
	print("[MMDBuilder] Skin 由 create_skin_from_rest_transforms 建 (bind=全局rest逆) 骨骼数=%d" % skel.get_bone_count())

	var mesh := ArrayMesh.new()
	var mi := MeshInstance3D.new()
	mi.name = "MMDMesh"
	mi.mesh = mesh
	mi.skin = skin
	# ★★★ 必须显式指向骨骼，否则蒙皮完全不生效 ★★★
	# Godot 4.6 起 MeshInstance3D.skeleton 的默认值由 NodePath("..")（自动认父骨骼）改成了空 NodePath("")。
	# 只设 skin 不设 skeleton 时 skin_ref 为 null → RS::instance_attach_skeleton 挂空 → 网格按【绑定姿态】渲染。
	# 阴险之处：PMX 顶点与骨骼 rest 同在模型空间，未蒙皮的画面与静止姿态一模一样，
	# 所以静态看起来完全正常，只有开始播放动画后才会暴露成“骨骼在动、模型不动”。
	# mi 是 skel 的子节点，故相对路径 ".." 即指向 Skeleton3D。
	mi.skeleton = ^".."
	# 视觉角色由自定义 ShaderMaterial 渲染；其阴影投射交由下方 MMDMeshShadow 副本负责，
	# 故这里关闭可见网格自身的投射（避免与副本重复/或自定义着色器深度通道不投的歧义）。
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	skel.add_child(mi)

	# 阴影投射体：同一网格 + 同一骨骼 + 内置材质 + SHADOWS_ONLY（不可见但投阴影）。
	# 关键：Godot 4 的自定义 ShaderMaterial 在【阴影深度通道】对蒙皮网格不稳（已知坑，vertex() 透传修复也不可靠），
	# 而内置材质（如红方块）投阴影是稳的。故用一份内置材质副本专职把角色投影投到地面，
	# 视觉角色仍由上方自定义着色器渲染。cast_shadow=3(SHADOWS_ONLY) 是 Godot 原生“隐形只投影”机制。
	var sc := MeshInstance3D.new()
	sc.name = "MMDMeshShadow"
	sc.mesh = mesh
	sc.skin = skin
	sc.skeleton = ^".."  # 同上，否则阴影会一直是静止姿态的“鬼影”，与动起来的角色错位
	sc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	var sc_mat := StandardMaterial3D.new()
	sc_mat.albedo_color = Color(1.0, 1.0, 1.0)
	# 关键：MMD 是单面薄几何（头发/裙摆），深度通道必须用【双面】渲染，否则背面不写深度 →
	# 阴影深度图缺失半边 → 自阴影噪点(acne)被当成“点状阴影”落到地面。与可见网格 cull_disabled 对应。
	sc_mat.cull_mode = StandardMaterial3D.CULL_DISABLED
	sc.material_override = sc_mat
	skel.add_child(sc)

	_build_surfaces(mesh, model, model_dir, light_dir_view, light_color, assign_materials)

	root.set_meta("mesh_instance", mi)
	return {"root": root, "skeleton": skel, "mesh_instance": mi, "mesh": mesh}


func _build_skeleton(skel: Skeleton3D, model: Dictionary) -> Array:
	var bones: Array = model["bones"]
	var n := bones.size()
	for b in bones:
		skel.add_bone(b["name"])

	for i in n:
		var p: int = bones[i]["parentIndex"]
		if p >= 0 and p < n:
			skel.set_bone_parent(i, p)

	# bone.position 为【模型空间绝对坐标】（MMD 约定：每根骨在静止姿态下的绝对位置）。
	# 全局 rest 直接 = T(pos)；局部 rest 由下方第二遍循环用 parent 全局逆求。
	#
	# ★ 致命坑（面条/脖子拉伸根因）：绝不能写成 global_rest[parent] * T(pos)。
	#   那会把“绝对坐标”误当成“父相对偏移”，沿骨链【双重累乘】。本模型 ~22 单位高，
	#   但错误写法把脚 IK 骨累乘到 y≈252、头累乘到 y≈102，而网格只有 ~22 单位 →
	#   整副炸成面条；右足ＩＫ 骨因此距 effector(右足首) 达 82 单位，IK 永远不收敛。
	#   修正后：脚 IK 骨世界坐标 = 其绝对 pos = 与 effector(右足首) 重合 → 静止 IK 距离 ≈ 0。
	var global_rest: Array = []
	global_rest.resize(n)
	for i in n:
		var pos: Vector3 = bones[i]["position"]
		# 关键（动画正确性）：顶点/法线已按 FLIP_Z 取反，骨骼 rest 必须同步取反。
		# 否则骨骼空间与顶点空间手性相反 —— 静止时看不出问题（bind 与 pose 互相抵消），
		# 但只要骨骼一转，肢体就朝 Z 的反方向弯（整套动作镜像）。
		# VMDPlayer 的 FLIP_Z 会把 VMD 的位移/旋转做同样的镜像共轭，两边保持一致。
		if FLIP_Z:
			pos = Vector3(pos.x, pos.y, -pos.z)
		# 绝对坐标 → 全局 rest 就是 T(pos) 本身，不再乘父链的全局 rest。
		var g: Transform3D = Transform3D(Basis.IDENTITY, pos)
		global_rest[i] = g

	for i in n:
		var p: int = bones[i]["parentIndex"]
		var pg: Transform3D = Transform3D.IDENTITY
		if p >= 0:
			pg = global_rest[p] as Transform3D
		var local: Transform3D = pg.affine_inverse() * (global_rest[i] as Transform3D)
		skel.set_bone_rest(i, local)
		# pose 设成 rest（不是 IDENTITY）：Godot 4.7 的 pose 是【绝对局部变换】，global_pose=沿父链累乘 pose。
		# pose=IDENTITY 时 global_pose=I，与 bind=全局rest逆 相乘 → 静止 matrix=全局rest^{-1} ≠ I → 变形。
		# pose=rest 时 global_pose=全局rest，matrix=I，静止即正确人形（与 VMDPlayer._set_rest_pose 一致）。
		skel.set_bone_pose(i, local)

	return global_rest


func _build_surfaces(mesh: ArrayMesh, model: Dictionary, model_dir: String, light_dir_view: Vector3, light_color: Vector3, assign_materials: bool = true) -> void:
	var vertices: PackedVector3Array = model["vertices"]
	var normals: PackedVector3Array = model["normals"]
	var uvs: PackedVector2Array = model["uvs"]
	var bone_indices: PackedInt32Array = model["boneIndices"]
	var bone_weights: PackedFloat32Array = model["boneWeights"]
	var indices: PackedInt32Array = model["indices"]
	var materials: Array = model["materials"]

	# ---- 顶点 morph → blend shape（表情）----
	# Godot 的 blend shape 计算着色器(skeleton.glsl)公式：
	#   RELATIVE 模式(ArrayMesh 默认 blend_shape_mode=1)：vertex += Σ shape_i * weight_i
	#   NORMALIZED 模式：vertex = (1-Σw)*vertex + Σ shape_i * weight_i
	# 即 RELATIVE 下数组里存的是【偏移量】—— 而 PMX 顶点 morph 本来就是偏移量，可直接喂入，零转换。
	# 法线：blend shape 必须提供与基础一致的通道，且法线是八面体编码(永远单位长度、无法表达"零偏移")。
	#   这里传【基础法线本身】，于是 normalize(base + w*base) == base，任意权重都不会改法线，
	#   等价于"表情只动位置不动法线"（MMD 顶点 morph 也确实不带法线数据）。
	var vmorphs: Array = []
	if ENABLE_MORPHS:
		for mo in model["morphs"]:
			if mo["type"] == 1 and mo["offsets"].size() > 0:
				vmorphs.append(mo)
		# add_blend_shape 必须在任何 add_surface_from_arrays 之前调用
		#（ArrayMesh 内部断言：Can't add a shape key count if surfaces are already created）
		for mo in vmorphs:
			mesh.add_blend_shape(mo["name"])
		mesh.blend_shape_mode = Mesh.BLEND_SHAPE_MODE_RELATIVE
		if vmorphs.size() > 0:
			print("BLENDSHAPES=%d (顶点morph) 预计显存 %.1fMB" % [
				vmorphs.size(), vmorphs.size() * vertices.size() * 20.0 / 1048576.0])

	var cursor := 0
	var surf_idx := 0
	for m in materials:
		var face_count: int = m["faceCount"]
		var tri_count: int = int(face_count / 3.0)

		# 收集本材质用到的全局顶点 → 局部索引映射
		var local_vert: Array = []
		var local_index: PackedInt32Array = []
		var local_map := {}
		for t in tri_count:
			for k in 3:
				var gi: int = indices[cursor]
				cursor += 1
				if not local_map.has(gi):
					local_map[gi] = local_vert.size()
					local_vert.append(gi)
				local_index.append(local_map[gi])

		var vcount: int = local_vert.size()
		var verts := PackedVector3Array()
		var norms := PackedVector3Array()
		var uvs2 := PackedVector2Array()
		var bones := PackedInt32Array()
		var weights := PackedFloat32Array()
		verts.resize(vcount)
		norms.resize(vcount)
		uvs2.resize(vcount)
		bones.resize(vcount * 4)
		weights.resize(vcount * 4)

		for li in vcount:
			var gi: int = local_vert[li]
			var vp: Vector3 = vertices[gi]
			var nrm: Vector3 = normals[gi]
			if FLIP_Z:
				vp = Vector3(vp.x, vp.y, -vp.z)
				nrm = Vector3(nrm.x, nrm.y, -nrm.z)
			verts[li] = vp
			norms[li] = nrm
			uvs2[li] = uvs[gi]
			var o: int = gi * 4
			bones[li * 4] = max(bone_indices[o], 0)
			bones[li * 4 + 1] = max(bone_indices[o + 1], 0)
			bones[li * 4 + 2] = max(bone_indices[o + 2], 0)
			bones[li * 4 + 3] = max(bone_indices[o + 3], 0)
			weights[li * 4] = bone_weights[o]
			weights[li * 4 + 1] = bone_weights[o + 1]
			weights[li * 4 + 2] = bone_weights[o + 2]
			weights[li * 4 + 3] = bone_weights[o + 3]

		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = norms
		arrays[Mesh.ARRAY_TEX_UV] = uvs2
		arrays[Mesh.ARRAY_BONES] = bones
		arrays[Mesh.ARRAY_WEIGHTS] = weights
		arrays[Mesh.ARRAY_INDEX] = local_index

		# ---- 本 surface 的 blend shape 数据 ----
		# Godot 强制“所有 surface 的 blend shape 数量必须一致”，所以即使某材质（如鞋子）
		# 完全不受任何表情影响，也要为全部 morph 交一份全零数组（resize 后默认即 0）。
		# 格式约束（rendering_server.cpp 校验）：
		#   bsformat 必须 == (主数组 format & ARRAY_FORMAT_BLEND_SHAPE_MASK)，即 VERTEX/NORMAL/TANGENT 三通道对齐。
		#   主数组给了 NORMAL 但没给 TANGENT 时，引擎会自动补上 TANGENT 位；blend shape 侧有完全相同的
		#   自动补位逻辑，故两边都只给 VERTEX+NORMAL 时掩码恰好相等 —— 不要多传 UV/BONES/WEIGHTS/INDEX，会校验失败。
		var bs_arrays: Array = []
		for mo in vmorphs:
			var bverts := PackedVector3Array()
			bverts.resize(vcount)
			for off in mo["offsets"]:
				var mgi: int = off["vertexIndex"]
				if local_map.has(mgi):
					var d: Vector3 = off["position"]
					if FLIP_Z:
						d = Vector3(d.x, d.y, -d.z)
					bverts[local_map[mgi]] = d
			var bsa := []
			bsa.resize(Mesh.ARRAY_MAX)
			bsa[Mesh.ARRAY_VERTEX] = bverts
			# 法线传【基础法线本身】：着色器算 normal = normalize(normal + Σ shape_normal*w)，
			# 代入即 normalize(base*(1+Σw)) == base，任意权重都不改法线 —— 等价于“表情只动位置不动法线”
			#（PMX 顶点 morph 本身也不含法线数据）。不能传零向量：法线是八面体编码，
			# 零向量会被解码成 (0,0,1) 而污染法线。
			bsa[Mesh.ARRAY_NORMAL] = norms
			bs_arrays.append(bsa)

		if bs_arrays.is_empty():
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		else:
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, bs_arrays)
		if assign_materials:
			mesh.surface_set_material(surf_idx, _build_material(m, model, model_dir, light_dir_view, light_color))
		surf_idx += 1


func _build_material(m: Dictionary, model: Dictionary, model_dir: String, light_dir_view: Vector3, light_color: Vector3) -> ShaderMaterial:
	var diffuse: Color = m["diffuse"]
	# 仅真正半透的材质(a<1)才用带 blend_mix 的变体；其余走不透明通道，避免“内表面透视”鬼影。
	var transparent: bool = diffuse.a < 0.999
	var mat := ShaderMaterial.new()
	mat.shader = load("res://mmd_material_transparent.gdshader" if transparent else "res://mmd_material.gdshader")
	mat.set_shader_parameter("light_dir", light_dir_view)
	mat.set_shader_parameter("light_color", light_color)
	# 图层栈默认值：mask=31(5 层全开) + 顺序 toon→spec→rim→emis→sphere。
	# 运行时由 mmd_layers.gd 每帧按 Inspector 面板覆盖。
	mat.set_shader_parameter("layer_mask", 31)
	mat.set_shader_parameter("layer_order", PackedInt32Array([0, 1, 2, 3, 4]))
	mat.set_shader_parameter("base_tint", diffuse)
	mat.set_shader_parameter("alpha", diffuse.a)
	mat.set_shader_parameter("ambient_color", m["ambient"])
	print("MATBUILD %s diffuse=%s ambient=%s" % [m["name"], diffuse, m["ambient"]])
	mat.set_shader_parameter("specular_color", m["specular"])
	mat.set_shader_parameter("shininess", m["specularPower"])

	# 边缘光(rim) / 自发光(emission)：MMD 格式无此数据，故对齐原版 pmx-preset.ts 的通用预设填默认值，
	# 让 LayerController 的 rim/emission 开关一开即有可见效果（之前 content=0 → 开关接了线但没内容）。
	# 原版按材质类别给 rim 0.1~0.4、rimColor 暖白、rimPower=3.0；这里取 body 通用值。
	mat.set_shader_parameter("rim_color", Vector3(1.0, 0.85, 0.7))
	mat.set_shader_parameter("rim_strength", 0.3)
	mat.set_shader_parameter("rim_power", 3.0)
	# 原版 emission 默认 0（仅眼睛材质 1.5）；给小值 0.12 让开关生效（代价：默认微发光）。
	mat.set_shader_parameter("emission_strength", 0.12)

	var tex_path: String = ""
	if m["textureIndex"] >= 0 and m["textureIndex"] < model["textures"].size():
		tex_path = model["textures"][m["textureIndex"]]
	var albedo: Texture2D = _resolve_texture(tex_path, model_dir)
	if albedo != null:
		mat.set_shader_parameter("albedo_tex", albedo)
		mat.set_shader_parameter("use_albedo", true)
	else:
		mat.set_shader_parameter("use_albedo", false)

	var toon: Texture2D = _resolve_toon(m, model, model_dir)
	mat.set_shader_parameter("toon_tex", toon)

	var sphere_mode: int = m["sphereMode"]
	if sphere_mode != 0 and m["sphereTextureIndex"] >= 0 and m["sphereTextureIndex"] < model["textures"].size():
		var sph: Texture2D = _resolve_texture(model["textures"][m["sphereTextureIndex"]], model_dir)
		if sph != null:
			mat.set_shader_parameter("sphere_tex", sph)
			mat.set_shader_parameter("use_sphere", true)
			mat.set_shader_parameter("sphere_mode", float(sphere_mode))
		else:
			mat.set_shader_parameter("use_sphere", false)
	else:
		mat.set_shader_parameter("use_sphere", false)

	# 注：ShaderMaterial 没有 .transparency 属性，半透明由着色器 render_mode blend_mix 统一开启，
	# 这里只保证 alpha uniform 已传入（上方 set_shader_parameter("alpha", diffuse.a) 已做）。
	# 描边（edge_size 直接用 PMX edgeScale；屏幕空间外扩逻辑在 mmd_outline.gdshader）。
	# 放宽 has_edge：只要 edgeScale>0 就画边。常见 MMD 导出里 edgeScale=1.0 即标准描边厚度，
	# 但许多模型未置 flag&0x10 位 → 若严格按 AfterglowWeb 的 flag&0x10 判定会导致整模型无描边、
	# LayerController 的 Outline 开关因 _outline_pairs 为空而“开/关没区别”。这里改为更宽松的
	# edgeScale>0，保证有可切的描边对象；edgeScale<=0 的材质仍不画边。
	var has_edge: bool = m["edgeScale"] > 0.0
	if has_edge:
		var outline := ShaderMaterial.new()
		outline.shader = load("res://mmd_outline.gdshader")
		outline.set_shader_parameter("edge_color", m["edgeColor"])
		outline.set_shader_parameter("edge_size", m["edgeScale"])
		# 对齐 AfterglowWeb outline-fs：用漫反射贴图 alpha 裁掉透明处的描边
		if albedo != null:
			outline.set_shader_parameter("edge_alpha_tex", albedo)
			outline.set_shader_parameter("use_edge_alpha", true)
		mat.next_pass = outline

	return mat


func _resolve_texture(raw_path: String, model_dir: String) -> Texture2D:
	if raw_path == null or raw_path == "":
		return null
	var base := raw_path.get_file()
	var candidates := [
		model_dir + "/textures/" + base,
		model_dir + "/" + base,
	]
	# 走 Godot 的 import 资源管线（export 安全，无 load_from_file 警告）。
	# res:// 下的 .png 已被 Godot 自动导入为 ImageTexture；直接用 load() 取即可，
	# 不必再走 Image.load_from_file（那条路径在导出后原始文件不存在，会触发警告且打包失效）。
	for c in candidates:
		if FileAccess.file_exists(c):
			var tex: Resource = load(c)
			if tex is Texture2D:
				return tex
	return null


func _resolve_toon(m: Dictionary, model: Dictionary, model_dir: String) -> Texture2D:
	if m["toonSharing"] == 1:
		return _fallback_toon()
	var idx: int = m["toonTextureIndex"]
	if idx >= 0 and idx < model["textures"].size():
		var t: Texture2D = _resolve_texture(model["textures"][idx], model_dir)
		if t != null:
			return t
	return _fallback_toon()


var _toon_cache: Texture2D = null

func _fallback_toon() -> Texture2D:
	if _toon_cache != null:
		return _toon_cache
	var img := Image.create(64, 4, false, Image.FORMAT_RGBA8)
	for x in 64:
		# 平滑渐变：左端 0.30（较暗阴影，仍可见）→ 右端 1.0（亮）。
		# 着色器再给 toonShade 保底 0.25，确保真实 toon 贴图暗端过黑时背光也不死黑。
		var t := float(x) / 63.0
		var v := 0.30 + 0.70 * t
		var c := Color(v, v, v, 1.0)
		for y in 4:
			img.set_pixel(x, y, c)
	_toon_cache = ImageTexture.create_from_image(img)
	return _toon_cache
