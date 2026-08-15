extends SceneTree

func _initialize() -> void:
	var mp = (load("res://src/material_presets.gd") as Script).new()

	# 模拟一个被自动归类为 cloth_smooth 的布料部件
	var mat = ShaderMaterial.new()
	mat.set_meta("mp_name", "cloth_part_A")
	mat.set_meta("mp_role", "cloth_smooth")

	# 1) 基础：按角色套用
	mp.apply_material(mat, "ag", "cloth_part_A", "cloth_smooth")
	var base_rim = mat.get_shader_parameter("rim_strength")
	print("REASSIGN base cloth_smooth rim_strength = %s (期望 0.25)" % base_rim)

	# 2) 改指派成 silk
	mp.set_material_preset("cloth_part_A", "silk")
	mp.apply_material(mat, "ag", "cloth_part_A", "cloth_smooth")
	var silk_rim = mat.get_shader_parameter("rim_strength")
	print("REASSIGN after silk rim_strength = %s (期望 0.55)" % silk_rim)
	var silk_sat = mat.get_shader_parameter("mat_saturation")
	print("REASSIGN after silk mat_saturation = %s (期望 1.15)" % silk_sat)
	var eff = mp.get_material_preset("cloth_part_A", "cloth_smooth")
	print("REASSIGN get_material_preset = %s (期望 silk)" % eff)

	# 3) 目录应含 silk / leather
	var pn = mp.preset_names()
	print("REASSIGN preset_names has silk=%s leather=%s default=%s" % [pn.has("silk"), pn.has("leather"), pn.has("default")])

	# 4) 还原 → 回 cloth_smooth
	mp.clear_material_preset("cloth_part_A")
	mp.apply_material(mat, "ag", "cloth_part_A", "cloth_smooth")
	var back_rim = mat.get_shader_parameter("rim_strength")
	print("REASSIGN after clear rim_strength = %s (期望回 0.25)" % back_rim)

	# 5) 切 pack 后指派仍生效（silk 与 pack 无关）
	mp.set_material_preset("cloth_part_A", "silk")
	mp.apply_material(mat, "wuwa", "cloth_part_A", "cloth_smooth")
	var wuwa_silk = mat.get_shader_parameter("rim_strength")
	print("REASSIGN wuwa+silk rim_strength = %s (期望仍 0.55)" % wuwa_silk)

	# 6) 主脚本仍能解析
	var imp = (load("res://src/mmd_importer.gd") as Script)
	var bld = (load("res://src/mmd_builder.gd") as Script)
	print("REASSIGN importer parses OK = %s" % (imp != null))
	print("REASSIGN builder parses OK = %s" % (bld != null))

	quit()
