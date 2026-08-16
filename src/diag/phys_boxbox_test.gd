extends SceneTree

# P1 verification: exercise the C++ MMDPhysics3D box-box multi-point manifold
# directly (bypassing the MMDPhysicsGD GDScript wrapper). Builds two
# overlapping boxes inside the extension and prints the generated manifold.

func _init():
	if not ClassDB.class_exists("MMDPhysics3D"):
		load("res://addons/mmd_phys_ext/mmd_phys_ext.gdextension")
	var phys = ClassDB.instantiate("MMDPhysics3D")
	phys.debug_boxbox()
	print("DEBUG_BOXBOX_DONE")
	quit()
