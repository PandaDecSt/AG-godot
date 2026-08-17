extends SceneTree

func _initialize() -> void:
	var res := ResourceLoader.load("res://src/material_presets.gd")
	if res != null and res is Script:
		print("MATPRESET_LOAD_OK")
	else:
		print("MATPRESET_LOAD_FAIL")
	quit()
