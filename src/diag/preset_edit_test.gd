extends SceneTree
func _initialize() -> void:
	print("EDIT_TEST_START")
	var mp = (load("res://src/material_presets.gd") as Script).new()

	# 1) 基础参数读取
	var p0 = mp.get_role_params("ag", "hair")
	print("base hair mat_saturation = %s (期望 1.4)" % p0.get("mat_saturation"))
	print("base hair toon[0] = %s (期望 [0,0,0])" % str(p0.get("toon")[0]))

	# 2) 覆盖标量
	mp.set_role_override("ag", "hair", "mat_saturation", 2.5)
	var p1 = mp.get_role_params("ag", "hair")
	print("after override mat_saturation = %s (期望 2.5)" % p1.get("mat_saturation"))

	# 3) 覆盖 toon 颜色
	var custom = [[0.1,0.2,0.3],[0.4,0.5,0.6],[0.7,0.8,0.9]]
	mp.set_role_override("ag", "hair", "toon", custom)
	var p2 = mp.get_role_params("ag", "hair")
	print("after toon override toon[2] = %s (期望 [0.7,0.8,0.9])" % str(p2.get("toon")[2]))

	# 4) 应用到真实 ShaderMaterial
	var mat = ShaderMaterial.new()
	mat.shader = load("res://shaders/mmd_material.gdshader")
	mp.apply_role(mat, "ag", "hair")
	print("apply_role (with override): mat_saturation=%s toon_tex is Texture2D=%s" % [
		mat.get_shader_parameter("mat_saturation"), mat.get_shader_parameter("toon_tex") is Texture2D])

	# 5) 还原默认
	mp.clear_role_override("ag", "hair")
	var p3 = mp.get_role_params("ag", "hair")
	print("after clear mat_saturation = %s (期望 1.4)" % p3.get("mat_saturation"))
	mp.apply_role(mat, "ag", "hair")
	print("apply_role (after clear): mat_saturation=%s" % mat.get_shader_parameter("mat_saturation"))

	# 6) bake_ramp_from_colors 缓存
	var t1 = mp.bake_ramp_from_colors([[0.1,0.2,0.3],[0.4,0.5,0.6],[0.7,0.8,0.9]])
	var t2 = mp.bake_ramp_from_colors([[0.1,0.2,0.3],[0.4,0.5,0.6],[0.7,0.8,0.9]])
	var t3 = mp.bake_ramp_from_colors([[0.9,0.8,0.7],[0.6,0.5,0.4],[0.3,0.2,0.1]])
	print("bake cache: same-colors same-instance=%s, diff-colors diff-instance=%s" % [t1==t2, t1!=t3])

	# 7) 两个大脚本能否正常解析（parse error 会让 load 返回 null 并打印 SCRIPT ERROR）
	var imp = load("res://src/mmd_importer.gd")
	var bld = load("res://src/mmd_builder.gd")
	print("importer.gd parses OK = %s" % (imp != null))
	print("builder.gd parses OK = %s" % (bld != null))

	print("EDIT_TEST_END")
	quit()
