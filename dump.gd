extends SceneTree

const FLIP_Z := true

func _initialize():
	print("[dump] start")
	var loader := PMXLoader.new()
	var model := loader.parse("res://models/model.pmx")
	var bones: Array = model["bones"]
	var n: int = bones.size()
	print("[dump] pmx bones=%d" % n)

	var skel := Skeleton3D.new()
	for b in bones:
		skel.add_bone(b["name"])
	for i in n:
		var p: int = bones[i]["parentIndex"]
		if p >= 0 and p < n:
			skel.set_bone_parent(i, p)
	for i in n:
		var pos: Vector3 = bones[i]["position"]
		if FLIP_Z:
			pos = Vector3(pos.x, pos.y, -pos.z)
		# PMX bone.position 是【模型空间绝对坐标】，全局 rest 直接 = T(pos)。
		# （曾误写成 get_bone_global_rest(parent) * T(pos) 导致双重累乘、面条；已修正）
		var global_rest: Transform3D = Transform3D(Basis.IDENTITY, pos)
		var gp: int = bones[i]["parentIndex"]
		var local: Transform3D = (skel.get_bone_global_rest(gp).affine_inverse() * global_rest) if (gp >= 0) else global_rest
		skel.set_bone_rest(i, local)

	var out := []
	for i in n:
		var rl: Transform3D = skel.get_bone_rest(i)
		var gr: Transform3D = skel.get_bone_global_rest(i)
		var b: Dictionary = bones[i]
		var ikLinks := []
		for lk in b["ikLinks"]:
			ikLinks.append({"linkIndex": lk["linkIndex"], "hasLimit": lk["hasLimit"],
				"limitMin": [lk["limitMin"].x, lk["limitMin"].y, lk["limitMin"].z],
				"limitMax": [lk["limitMax"].x, lk["limitMax"].y, lk["limitMax"].z]})
		var rp: Vector3 = b["position"]
		out.append({
			"name": b["name"],
			"parent": b["parentIndex"],
			"pos_raw": [rp.x, rp.y, rp.z],
			"rest_origin": [rl.origin.x, rl.origin.y, rl.origin.z],
			"rest_basis": [rl.basis.x.x, rl.basis.x.y, rl.basis.x.z,
				rl.basis.y.x, rl.basis.y.y, rl.basis.y.z,
				rl.basis.z.x, rl.basis.z.y, rl.basis.z.z],
			"global_rest_origin": [gr.origin.x, gr.origin.y, gr.origin.z],
			"flag": b["flag"],
			"ikTarget": b["ikTargetIndex"],
			"ikLoopCount": b["ikLoopCount"],
			"ikUnitLength": b["ikUnitLength"],
			"ikLinks": ikLinks,
			"appendParent": b["appendParentIndex"],
			"appendRatio": b["appendRatio"],
			"appendRotate": b["appendRotate"],
			"appendMove": b["appendMove"],
		})

	var vl := VMDLoader.new()
	var vmd := vl.parse("res://models/motions.vmd")
	var tracks := {}
	for nm in vmd["bone_tracks"].keys():
		var arr: Array = vmd["bone_tracks"][nm]
		var lst := []
		for rec in arr:
			lst.append({"frame": rec["frame"], "pos": [rec["pos"].x, rec["pos"].y, rec["pos"].z],
				"rot": [rec["rot"].x, rec["rot"].y, rec["rot"].z, rec["rot"].w]})
		tracks[nm] = lst

	var payload := {"bones": out, "bone_tracks": tracks, "fps": vmd["fps"]}
	var f := FileAccess.open("C:/ag_vmdtest/dump.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	print("[dump] wrote C:/ag_vmdtest/dump.json bones=%d tracks=%d fps=%s" % [n, tracks.size(), vmd["fps"]])
	quit()
