extends SceneTree

func _initialize() -> void:
	var paths := [
		"res://src/mmd_physics.gd",
		"res://src/vmd_player.gd",
		"res://src/mmd_importer.gd",
		"res://src/pmx_loader.gd",
		"res://src/mmd_builder.gd",
	]
	for p in paths:
		var s = load(p)
		if s == null:
			print("PARSE_FAILED: %s" % p)
		else:
			print("OK: %s" % p)
	quit()
