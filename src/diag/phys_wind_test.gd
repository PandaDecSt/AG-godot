extends SceneTree

# P3 verification: exercise the C++ MMDPhysics3D wind path directly
# (bypassing the MMDPhysicsGD GDScript wrapper). debugWindTest() builds a
# single free-falling body and runs one step with gravity-only vs gravity+wind,
# printing the resulting linear velocity so we can confirm wind injects an
# acceleration along the wind direction. No model required.

func _init():
	if not ClassDB.class_exists("MMDPhysics3D"):
		load("res://addons/mmd_phys_ext/mmd_phys_ext.gdextension")
	var phys = ClassDB.instantiate("MMDPhysics3D")
	phys.debug_wind()
	print("DEBUG_WIND_DONE")
	quit()
