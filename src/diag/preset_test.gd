extends SceneTree
func _initialize() -> void:
	print("PRESET_TEST_START")
	var mp = (load("res://src/material_presets.gd") as Script).new()
	var shader = load("res://shaders/mmd_material.gdshader")
	var mat = ShaderMaterial.new()
	mat.shader = shader

	# --- apply_role (ag, hair) ---
	mp.apply_role(mat, "ag", "hair")
	var toon = mat.get_shader_parameter("toon_tex")
	print("apply_role hair: toon_tex is Texture2D = %s, mat_saturation = %s, rim_strength = %s" % [
		toon is Texture2D, mat.get_shader_parameter("mat_saturation"), mat.get_shader_parameter("rim_strength")])

	# --- apply_role default (should not touch toon_tex, only neutral uniforms) ---
	mp.apply_role(mat, "ag", "default")
	print("apply_role default: mat_value = %s, sphere_strength = %s" % [
		mat.get_shader_parameter("mat_value"), mat.get_shader_parameter("sphere_strength")])

	# --- apply_look (wuwa + Bloody grade) ---
	mp.apply_look([mat], "wuwa", "Bloody")
	print("apply_look wuwa/Bloody: exposure = %s, tonemap_mode = %s, world_color = %s, saturation = %s, contrast = %s" % [
		mat.get_shader_parameter("exposure"),
		mat.get_shader_parameter("tonemap_mode"),
		mat.get_shader_parameter("world_color"),
		mat.get_shader_parameter("saturation"),
		mat.get_shader_parameter("contrast")])
	var sh = mat.get_shader_parameter("grade_shadow_tint")
	var hi = mat.get_shader_parameter("grade_highlight_tint")
	print("apply_look wuwa/Bloody: grade_shadow_tint = %s, grade_highlight_tint = %s" % [sh, hi])

	# --- bake_ramp cache check ---
	var r1 = mp.bake_ramp("ag", "body")
	var r2 = mp.bake_ramp("ag", "body")
	print("bake_ramp cache: same instance = %s, is Texture2D = %s" % [r1 == r2, r1 is Texture2D])

	# --- look_list / grade_list / role_list sanity ---
	print("look_list=", mp.look_list())
	print("grade_list=", mp.grade_list())
	print("default_pack=", mp.default_pack())
	print("PRESET_TEST_END")
	quit()
