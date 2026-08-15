extends Node

# Headless scene test for the mmd_phys_ext GDExtension.
# Run as a scene (not --script) so GDExtensions are loaded by the normal
# project boot:
#   "<godot_console.exe>" --headless --path "D:\MySpace\workshop\GodotPros\AfterGlowGodot" "res://src/diag/phys_test.tscn"

func _ready():
	print("=== mmd_phys_ext scene test ===")

	# In some headless runs auto-discovery is skipped; force-load the extension.
	var ext_path = "res://addons/mmd_phys_ext/mmd_phys_ext.gdextension"
	if ResourceLoader.exists(ext_path):
		var ext = load(ext_path)
		print("loaded .gdextension resource: ", ext != null)
	else:
		print("WARN: .gdextension file not found at ", ext_path)

	if not ClassDB.class_exists("MMDPhysics3D"):
		print("FATAL: MMDPhysics3D not registered (extension failed to load)")
		get_tree().quit(1)
		return

	var phys = ClassDB.instantiate("MMDPhysics3D")
	if phys == null:
		print("FATAL: instantiate returned null")
		get_tree().quit(1)
		return

	# 1 dynamic sphere body pinned to bone 0, 0 joints
	var rb_bone    = PackedInt32Array([0])
	var rb_group   = PackedInt32Array([0])
	var rb_mask    = PackedInt32Array([0])
	var rb_shape   = PackedInt32Array([0])
	var rb_size    = PackedFloat32Array([1.0, 1.0, 1.0])
	var rb_pos     = PackedFloat32Array([0.0, 5.0, 0.0])
	var rb_rot     = PackedFloat32Array([0.0, 0.0, 0.0])
	var rb_params  = PackedFloat32Array([1.0, 0.5, 0.5, 0.0, 0.5])
	var rb_type    = PackedInt32Array([1])
	var rb_aligned = PackedInt32Array([1])
	var ei = PackedInt32Array()
	var ef = PackedFloat32Array()

	phys.setup(rb_bone, rb_group, rb_mask, rb_shape, rb_size, rb_pos, rb_rot,
		rb_params, rb_type, rb_aligned,
		ei, ei, ef, ef, ef, ef, ef, ef, ef, ef)
	print("setup() ok")

	phys.set_gravity(0.0, -9.8, 0.0)
	var g = phys.get_gravity()
	print("get_gravity -> ", g)

	var nb = 2
	var bone_world = PackedFloat32Array()
	var bone_invbind = PackedFloat32Array()
	for b in range(nb):
		for i in range(16):
			if i % 5 == 0:
				bone_world.append(1.0); bone_invbind.append(1.0)
			else:
				bone_world.append(0.0); bone_invbind.append(0.0)

	var out = phys.step(1.0 / 60.0, bone_world, bone_invbind)
	print("step() out size = ", out.size(), " (expected ", nb * 16, ")")
	if out.size() != nb * 16:
		print("FATAL: unexpected output length")
		get_tree().quit(1)
		return

	print("bone0 world origin after step = ", out[12], out[13], out[14])
	print("=== SCENE TEST PASSED ===")
	get_tree().quit(0)
