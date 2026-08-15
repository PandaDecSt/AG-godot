class_name PMXLoader
extends RefCounted

# 纯 GDScript 实现的 PMX 2.0-2.2 二进制解析器。
# 严格镜像 AfterglowWeb/src/utils/pmx_loader.ts（WebGPU 版能正常加载 model.pmx 的权威解析器）。
# 用法：
#   var loader := PMXLoader.new()
#   var model := loader.parse("res://models/model.pmx")
# 返回的 Dictionary 字段见 parse() 末尾。

const PMX_BONE_BDEF1 := 0
const PMX_BONE_BDEF2 := 1
const PMX_BONE_BDEF4 := 2
const PMX_BONE_SDEF  := 3
const PMX_BONE_QDEF  := 4


func parse(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[PMXLoader] 无法打开文件: %s  error=%s" % [path, FileAccess.get_open_error()])
		return {}

	var magic := PackedByteArray()
	magic.append_array(f.get_buffer(4))
	var magic_str := String.chr(magic[0]) + String.chr(magic[1]) + String.chr(magic[2]) + String.chr(magic[3])
	if magic_str != "PMX ":
		push_error("[PMXLoader] 非法 magic: %s" % magic_str)
		f.close()
		return {}

	var version := f.get_float()
	if version < 2.0 or version > 2.2:
		push_error("[PMXLoader] 不支持的版本: %f" % version)
		f.close()
		return {}

	var globals_count := f.get_8()
	var globals := PackedByteArray()
	for i in globals_count:
		globals.append(f.get_8())
	var encoding: int = globals[0]
	var add_vec4: int = globals[1]
	var v_idx_sz: int = globals[2]
	var tex_idx_sz: int = globals[3]
	var mat_idx_sz: int = globals[4]
	var bone_idx_sz: int = globals[5]
	var morph_idx_sz: int = globals[6]
	var rb_idx_sz: int = globals[7]

	var name := _read_text(f, encoding)
	var _name_en := _read_text(f, encoding)
	var _comment := _read_text(f, encoding)
	var _comment_en := _read_text(f, encoding)

	# ---- 顶点 ----
	var vc := f.get_32()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var bone_indices := PackedInt32Array()
	var bone_weights := PackedFloat32Array()
	var edge_scales := PackedFloat32Array()
	vertices.resize(vc)
	normals.resize(vc)
	uvs.resize(vc)
	bone_indices.resize(vc * 4)
	bone_weights.resize(vc * 4)
	edge_scales.resize(vc)

	for i in vc:
		var px := f.get_float(); var py := f.get_float(); var pz := f.get_float()
		var nx := f.get_float(); var ny := f.get_float(); var nz := f.get_float()
		var u := f.get_float(); var v := f.get_float()
		for j in add_vec4:
			f.get_float(); f.get_float(); f.get_float(); f.get_float()
		var bt := f.get_8()
		var bi := [0, 0, 0, 0]
		var bw := [0.0, 0.0, 0.0, 0.0]
		match bt:
			PMX_BONE_BDEF1:
				bi[0] = _read_i(f, bone_idx_sz)
				bw[0] = 1.0
			PMX_BONE_BDEF2:
				var b0 := _read_i(f, bone_idx_sz); var b1 := _read_i(f, bone_idx_sz); var w0 := f.get_float()
				bi[0] = b0; bi[1] = b1; bw[0] = w0; bw[1] = 1.0 - w0
			PMX_BONE_SDEF:
				# SDEF 退化为 BDEF2（与 WebGPU 版一致性：本项目模型无 SDEF，仅是通用保护）
				var b0 := _read_i(f, bone_idx_sz); var b1 := _read_i(f, bone_idx_sz); var w0 := f.get_float()
				f.get_float(); f.get_float(); f.get_float()  # C
				f.get_float(); f.get_float(); f.get_float()  # R0
				f.get_float(); f.get_float(); f.get_float()  # R1
				bi[0] = b0; bi[1] = b1; bw[0] = w0; bw[1] = 1.0 - w0
			PMX_BONE_BDEF4, PMX_BONE_QDEF:
				var b0 := _read_i(f, bone_idx_sz); var b1 := _read_i(f, bone_idx_sz)
				var b2 := _read_i(f, bone_idx_sz); var b3 := _read_i(f, bone_idx_sz)
				var w0 := f.get_float(); var w1 := f.get_float(); var w2 := f.get_float(); var w3 := f.get_float()
				var sum := w0 + w1 + w2 + w3
				bi = [b0, b1, b2, b3]
				if sum > 0.0:
					bw = [w0 / sum, w1 / sum, w2 / sum, w3 / sum]
				else:
					bw = [1.0, 0.0, 0.0, 0.0]
			_:
				bi[0] = 0
				bw[0] = 1.0
		var es := f.get_float()
		vertices[i] = Vector3(px, py, pz)
		normals[i] = Vector3(nx, ny, nz)
		uvs[i] = Vector2(u, v)
		var o := i * 4
		bone_indices[o] = bi[0]; bone_indices[o + 1] = bi[1]; bone_indices[o + 2] = bi[2]; bone_indices[o + 3] = bi[3]
		bone_weights[o] = bw[0]; bone_weights[o + 1] = bw[1]; bone_weights[o + 2] = bw[2]; bone_weights[o + 3] = bw[3]
		edge_scales[i] = es

	# ---- 面索引 ----
	var fc := f.get_32()
	var indices := PackedInt32Array()
	indices.resize(fc)
	for i in fc:
		indices[i] = _read_u(f, v_idx_sz)

	# ---- 纹理 ----
	var tc := f.get_32()
	var textures := PackedStringArray()
	for i in tc:
		textures.append(_read_text(f, encoding))

	# ---- 材质 ----
	var mc := f.get_32()
	var materials := []
	var _cum := 0
	for i in mc:
		var matname := _read_text(f, encoding)
		var _matname_en := _read_text(f, encoding)
		var d0 := f.get_float(); var d1 := f.get_float(); var d2 := f.get_float(); var d3 := f.get_float()
		var s0 := f.get_float(); var s1 := f.get_float(); var s2 := f.get_float()
		var specular_power := f.get_float()
		var a0 := f.get_float(); var a1 := f.get_float(); var a2 := f.get_float()
		var flag := f.get_8()
		var e0 := f.get_float(); var e1 := f.get_float(); var e2 := f.get_float(); var e3 := f.get_float()
		var edge_scale := f.get_float()
		var texture_index := _read_i(f, tex_idx_sz)
		var sphere_texture_index := _read_i(f, tex_idx_sz)
		var sphere_mode := f.get_8()
		var toon_sharing := f.get_8()
		var toon_texture_index := 0
		if toon_sharing == 1:
			toon_texture_index = f.get_8()
		else:
			toon_texture_index = _read_i(f, tex_idx_sz)
		var _mat_comment := _read_text(f, encoding)
		var face_count := f.get_32()
		materials.append({
			"name": matname,
			"diffuse": Color(d0, d1, d2, d3),
			"specular": Color(s0, s1, s2, 1.0),
			"specularPower": specular_power,
			"ambient": Color(a0, a1, a2, 1.0),
			"flag": flag,
			"edgeColor": Color(e0, e1, e2, e3),
			"edgeScale": edge_scale,
			"textureIndex": texture_index,
			"sphereTextureIndex": sphere_texture_index,
			"sphereMode": sphere_mode,
			"toonSharing": toon_sharing,
			"toonTextureIndex": toon_texture_index,
			"faceCount": face_count,
		})
		_cum += face_count

	# ---- 骨骼 ----
	var bc := f.get_32()
	var bones := []
	for i in bc:
		var bname := _read_text(f, encoding)
		var _bname_en := _read_text(f, encoding)
		var pos := Vector3(f.get_float(), f.get_float(), f.get_float())
		var parent_index := _read_i(f, bone_idx_sz)
		var _transform_level := f.get_32()
		var bone_flag := f.get_16()
		if bone_flag & 0x0001:
			_read_i(f, bone_idx_sz)  # tail is bone index
		else:
			f.get_float(); f.get_float(); f.get_float()  # tail position
		var append_parent_index := -1
		var append_ratio := 0.0
		var append_rotate := false
		var append_move := false
		if bone_flag & 0x0100 or bone_flag & 0x0200:
			append_parent_index = _read_i(f, bone_idx_sz)
			append_ratio = f.get_float()
			append_rotate = (bone_flag & 0x0100) != 0
			append_move = (bone_flag & 0x0200) != 0
		if bone_flag & 0x0400:
			f.get_float(); f.get_float(); f.get_float()  # axis limit vec3
		if bone_flag & 0x0800:
			f.get_float(); f.get_float(); f.get_float()  # local x-axis
			f.get_float(); f.get_float(); f.get_float()  # local z-axis
		if bone_flag & 0x2000:
			f.get_32()  # external parent
		var ik_target_index := -1
		var ik_loop_count := 0
		var ik_unit_length := 0.0
		var ik_links := []
		if bone_flag & 0x0020:
			ik_target_index = _read_i(f, bone_idx_sz)
			ik_loop_count = f.get_32()
			ik_unit_length = f.get_float()
			var link_count := f.get_32()
			for j in link_count:
				var link_index := _read_i(f, bone_idx_sz)
				var has_limit := f.get_8() == 1
				var limit_min := Vector3.ZERO
				var limit_max := Vector3.ZERO
				if has_limit:
					limit_min = Vector3(f.get_float(), f.get_float(), f.get_float())
					limit_max = Vector3(f.get_float(), f.get_float(), f.get_float())
				ik_links.append({"linkIndex": link_index, "hasLimit": has_limit, "limitMin": limit_min, "limitMax": limit_max})
		bones.append({
			"name": bname,
			"parentIndex": parent_index,
			"position": pos,
			# 变形階層(deform layer)：MMD 按层排序做 付与親/IK，D 骨通常在 layer>=1。
			# VMDPlayer 用它决定付与親的处理顺序，不带上会导致 D 骨（足D/腕捩）不动。
			"deformLayer": _transform_level,
			"flag": bone_flag,
			"ikTargetIndex": ik_target_index,
			"ikLoopCount": ik_loop_count,
			"ikUnitLength": ik_unit_length,
			"ikLinks": ik_links,
			"appendParentIndex": append_parent_index,
			"appendRatio": append_ratio,
			"appendRotate": append_rotate,
			"appendMove": append_move,
		})

	# ---- Morph ----
	var mrc := f.get_32()
	var morphs := []
	for i in mrc:
		var mname := _read_text(f, encoding)
		var _mname_en := _read_text(f, encoding)
		var mpanel := f.get_8()
		var mtype := f.get_8()
		var oc := f.get_32()
		var offsets := []
		if mtype == 1:
			for j in oc:
				var vi := _read_u(f, v_idx_sz)
				var p := Vector3(f.get_float(), f.get_float(), f.get_float())
				offsets.append({"vertexIndex": vi, "position": p})
		elif mtype == 0:
			# 组 morph：引用其它 morph 并按 ratio 缩放。本模型 11 个组 morph 全部被 VMD 直接驱动
			# （まばたき/笑い/瞳小 等，结构均为「左+右」两个顶点 morph、ratio=1.0），
			# 若丢弃则眨眼、微笑等核心表情全部失效 —— 必须保留，交由 VMDPlayer 展开到子 morph。
			for j in oc:
				var sub_idx := _read_i(f, morph_idx_sz)
				var sub_ratio := f.get_float()
				offsets.append({"morphIndex": sub_idx, "ratio": sub_ratio})
		else:
			for j in oc:
				match mtype:
					2:
						_read_i(f, bone_idx_sz)
						f.get_float(); f.get_float(); f.get_float(); f.get_float(); f.get_float(); f.get_float()
					3, 4, 5, 6, 7:
						_read_u(f, v_idx_sz)
						f.get_float(); f.get_float(); f.get_float(); f.get_float()
					8:
						_read_i(f, mat_idx_sz); f.get_8()
						for k in 28:
							f.get_float()
					9:
						_read_i(f, morph_idx_sz); f.get_float()
					10:
						_read_i(f, rb_idx_sz); f.get_8()
						f.get_float(); f.get_float(); f.get_float(); f.get_float(); f.get_float(); f.get_float()
					_:
						pass
		morphs.append({"name": mname, "type": mtype, "panel": mpanel, "offsets": offsets})

	# ---- 显示帧（跳过）----
	if f.get_length() - f.get_position() > 4:
		var frame_count := f.get_32()
		for i in frame_count:
			_read_text(f, encoding); _read_text(f, encoding); f.get_8()
			var elem_count := f.get_32()
			for j in elem_count:
				var et := f.get_8()
				if et == 0:
					_read_i(f, bone_idx_sz)
				else:
					_read_i(f, morph_idx_sz)

	# ---- 刚体 ----
	var rigidbodies := []
	if f.get_length() - f.get_position() > 4:
		var rb_count := f.get_32()
		for i in rb_count:
			var rbname := _read_text(f, encoding)
			var _rbname_en := _read_text(f, encoding)
			var rb_bone_index := _read_i(f, bone_idx_sz)
			var rb_group := f.get_8()
			var rb_collision_mask := f.get_16()
			var rb_shape := f.get_8()
			var rb_size := Vector3(f.get_float(), f.get_float(), f.get_float())
			var rb_pos := Vector3(f.get_float(), f.get_float(), f.get_float())
			var rb_rot := Vector3(f.get_float(), f.get_float(), f.get_float())
			var rb_mass := f.get_float()
			var rb_lin_damp := f.get_float()
			var rb_ang_damp := f.get_float()
			var rb_rest := f.get_float()
			var rb_fric := f.get_float()
			var rb_type := f.get_8()
			rigidbodies.append({
				"name": rbname, "boneIndex": rb_bone_index, "group": rb_group,
				"collisionMask": rb_collision_mask, "shape": rb_shape, "size": rb_size,
				"position": rb_pos, "rotation": rb_rot, "mass": rb_mass,
				"linearDamping": rb_lin_damp, "angularDamping": rb_ang_damp,
				"restitution": rb_rest, "friction": rb_fric, "type": rb_type,
			})

	# ---- 关节 ----
	var joints := []
	if f.get_length() - f.get_position() > 4:
		var joint_count := f.get_32()
		for i in joint_count:
			var jname := _read_text(f, encoding)
			var _jname_en := _read_text(f, encoding)
			var jtype := f.get_8()
			var jrb_a := _read_i(f, rb_idx_sz)
			var jrb_b := _read_i(f, rb_idx_sz)
			var jpos := Vector3(f.get_float(), f.get_float(), f.get_float())
			var jrot := Vector3(f.get_float(), f.get_float(), f.get_float())
			var jpos_min := Vector3(f.get_float(), f.get_float(), f.get_float())
			var jpos_max := Vector3(f.get_float(), f.get_float(), f.get_float())
			var jrot_min := Vector3(f.get_float(), f.get_float(), f.get_float())
			var jrot_max := Vector3(f.get_float(), f.get_float(), f.get_float())
			var jsp_pos := Vector3(f.get_float(), f.get_float(), f.get_float())
			var jsp_rot := Vector3(f.get_float(), f.get_float(), f.get_float())
			joints.append({
				"name": jname, "type": jtype, "rigidbodyA": jrb_a, "rigidbodyB": jrb_b,
				"position": jpos, "rotation": jrot, "positionMin": jpos_min, "positionMax": jpos_max,
				"rotationMin": jrot_min, "rotationMax": jrot_max, "springPosition": jsp_pos, "springRotation": jsp_rot,
			})

	f.close()

	return {
		"name": name,
		"vertices": vertices,
		"normals": normals,
		"uvs": uvs,
		"boneIndices": bone_indices,
		"boneWeights": bone_weights,
		"edgeScales": edge_scales,
		"indices": indices,
		"textures": textures,
		"materials": materials,
		"bones": bones,
		"morphs": morphs,
		"rigidbodies": rigidbodies,
		"joints": joints,
	}


# ---- 内部工具 ----

func _read_text(f: FileAccess, encoding: int) -> String:
	var text_len := f.get_32()
	if text_len <= 0:
		return ""
	var bytes := f.get_buffer(text_len)
	if encoding == 0:
		return bytes.get_string_from_utf16()
	return bytes.get_string_from_utf8()


func _read_i(f: FileAccess, size: int) -> int:
	match size:
		1:
			var v := f.get_8()
			return v if v < 128 else v - 256
		2:
			var v := f.get_16()
			return v if v < 32768 else v - 65536
		4:
			return f.get_32()
		_:
			return f.get_8()


func _read_u(f: FileAccess, size: int) -> int:
	match size:
		1:
			return f.get_8()
		2:
			return f.get_16() & 0xFFFF
		4:
			return f.get_32()
		_:
			return f.get_8()
