extends SceneTree

func _initialize() -> void:
	var paths = [
		"res://src/mmd_importer.gd",
		"res://src/mmd_layers.gd",
	]
	var all_ok = true
	for p in paths:
		var res = ResourceLoader.load(p)
		if res == null:
			all_ok = false
			print("SYNTAX_FAIL: ", p)
		else:
			print("SYNTAX_OK:   ", p)
	print("IMPORT_SYNTAX ", "ALL_OK" if all_ok else "HAS_FAIL")
	quit()
