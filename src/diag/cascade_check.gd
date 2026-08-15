extends SceneTree

func _initialize() -> void:
	var loader := PMXLoader.new()
	var model := loader.parse("res://models/model.pmx")
	var skel := Skeleton3D.new()
	get_root().add_child(skel)
	var builder := MMDModelBuilder.new()
	builder._build_skeleton(skel, model)
	skel.force_update_all_bone_transforms()

	var db := 135
	var parent := 25

	print("BEFORE: pose25=%s g25=%s g135=%s" % [
		str(skel.get_bone_pose(parent).origin),
		str(skel.get_bone_global_pose(parent).origin),
		str(skel.get_bone_global_pose(db).origin)])

	var pp := skel.get_bone_pose(parent)
	pp.origin += Vector3(0, 3, 0)
	skel.set_bone_pose(parent, pp)
	print("after set_bone_pose(25): get_bone_pose(25)=%s" % str(skel.get_bone_pose(parent).origin))

	skel.force_update_all_bone_transforms()
	print("after force_update: g25=%s g135=%s" % [
		str(skel.get_bone_global_pose(parent).origin),
		str(skel.get_bone_global_pose(db).origin)])

	# 试试直接设全局位姿
	var gp := skel.get_bone_global_pose(parent)
	gp.origin += Vector3(0, 0, 5)
	skel.set_bone_global_pose(parent, gp)
	skel.force_update_all_bone_transforms()
	print("after set_bone_global_pose(25): g25=%s g135=%s" % [
		str(skel.get_bone_global_pose(parent).origin),
		str(skel.get_bone_global_pose(db).origin)])
	quit()
