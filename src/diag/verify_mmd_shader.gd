extends SceneTree
func _initialize():
	var path = "res://shaders/mmd_material.gdshader"
	var res = ResourceLoader.load(path, "Shader", ResourceLoader.CACHE_MODE_IGNORE)
	if res == null:
		print("SHADER_LOAD_FAIL")
	else:
		print("SHADER_LOAD_OK")
	quit()
