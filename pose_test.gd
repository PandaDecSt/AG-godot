extends SceneTree

# 决定性实验：Godot 4.7 的 bone pose 到底是「绝对局部(替换rest)」还是「叠加在rest上(rest*pose)」。
# 这是 mmd_builder.gd:127 与 vmd_player.gd:24 整个设计的命根子。
func _initialize():
	var skel := Skeleton3D.new()
	skel.add_bone("root")
	skel.add_bone("child")
	skel.set_bone_parent(1, 0)
	# rest: root 在原点；child 的【局部rest】= T(1,0,0)
	skel.set_bone_rest(0, Transform3D(Basis.IDENTITY, Vector3.ZERO))
	skel.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(1, 0, 0)))
	# 像 mmd_builder 那样把 pose 设成 rest（非 IDENTITY）
	skel.set_bone_pose(0, Transform3D(Basis.IDENTITY, Vector3.ZERO))
	skel.set_bone_pose(1, Transform3D(Basis.IDENTITY, Vector3(1, 0, 0)))

	var gp := skel.get_bone_global_pose(1)
	print("[POSE_TEST] global_pose(child, pose=rest) origin = %s" % str(gp.origin))
	print("[POSE_TEST]   若 (1,0,0) => pose 替换 rest(注释正确)；若 (2,0,0) => 引擎算 rest*pose(注释错)")

	# 复刻 mmd_builder 的 skin
	var skin: Skin = skel.create_skin_from_rest_transforms()
	var bp: Transform3D = skin.get_bind_pose(1)
	var gr: Transform3D = skel.get_bone_global_rest(1)
	print("[POSE_TEST] global_rest(child)   = %s" % str(gr.origin))
	print("[POSE_TEST] bind_pose(child)      = %s" % str(bp.origin))
	# Godot 蒙皮源码：skeleton_bone_set_transform = global_pose * bind_pose
	var m: Transform3D = gp * bp
	print("[POSE_TEST] skin matrix origin    = %s  (=(0,0,0) 静止才正确人形；否则=整副变形)" % str(m.origin))

	# 第二个对照：把 child pose 设成 IDENTITY，看是否落到 rest
	skel.set_bone_pose(1, Transform3D())
	var gp2 := skel.get_bone_global_pose(1)
	print("[POSE_TEST] global_pose(child, pose=IDENTITY) origin = %s (若(1,0,0)=identity回退到rest；若(0,0,0)=identity即原点)" % str(gp2.origin))
	quit()
