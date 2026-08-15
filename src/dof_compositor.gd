@tool
extends CompositorEffect
class_name DOFEffect

# 景深 DOF（bokeh 散景）——Godot 4.7 自定义后处理（CompositorEffect，RD 级）。
# 替代被移除的 Environment.dof_blur_far_*：在 POST_TRANSPARENT 阶段读「颜色缓冲 + 深度缓冲」，
# 按"离对焦面越远越虚"做金色角螺旋盘散景（对齐 reze 的 bokeh 虚化），写回颜色缓冲。
#
# 用法：把本 effect 实例加入活动 Camera3D.compositor.compositor_effects（Godot 4.7 属性名，见 mmd_layers.gd 的 _ensure_dof）；
#       mmd_layers.gd 每帧把面板参数写进下面的导出变量。dof_enabled=false 时引擎直接跳过本 effect。

const SHADER_CODE := """#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	float focus_distance;
	float aperture;
	float max_blur;
	float cam_near;
	float cam_far;
	float dof_on;
	float reserved;
} params;

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);
	if (uv.x >= size.x || uv.y >= size.y) { return; }

	vec4 center = imageLoad(color_image, uv);
	if (params.dof_on < 0.5) {
		imageStore(color_image, uv, center);
		return;
	}

	vec2 uv_f = (vec2(uv) + 0.5) / params.raster_size;
	float depth = texture(depth_tex, uv_f).r;
	// 把 Godot 非线性深度 [0,1]（0=近裁面, 1=远裁面）还原成视图空间距离（正数，越大越远）。
	float ld = (params.cam_near * params.cam_far) / (params.cam_far - depth * (params.cam_far - params.cam_near));
	// 弥散圆(CoC)：离对焦面越远 → 越虚；限制到 max_blur 像素。
	float coc = clamp(abs(ld - params.focus_distance) / max(params.focus_distance, 0.001) * params.aperture * params.max_blur, 0.0, params.max_blur);
	if (coc < 0.75) {
		imageStore(color_image, uv, center);   // 基本在对焦面上，原样输出（省一次盘采样）
		return;
	}

	// 金色角螺旋盘采样（均匀覆盖圆盘、散景形态自然）。
	const int N = 28;
	const float golden = 2.39996323;
	vec3 acc = vec3(0.0);
	for (int i = 0; i < N; i++) {
		float t = (float(i) + 0.5) / float(N);
		float ang = float(i) * golden;
		vec2 off = vec2(cos(ang), sin(ang)) * sqrt(t) * coc;
		ivec2 suv = ivec2(clamp(vec2(uv) + off, vec2(0.0), params.raster_size - vec2(1.0)));
		acc += imageLoad(color_image, suv).rgb;
	}
	acc /= float(N);
	imageStore(color_image, uv, vec4(acc, center.a));
}
"""

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var nearest_sampler: RID
var shader_dirty: bool = true

# 由 mmd_layers.gd 每帧写入的参数。
var dof_on: float = 0.0
var focus_distance: float = 8.0
var aperture: float = 0.6
var max_blur: float = 20.0
var cam_near: float = 0.1
var cam_far: float = 100.0

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	enabled = true
	rd = RenderingServer.get_rendering_device()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if rd != null:
			if shader.is_valid():
				rd.free_rid(shader)
			if pipeline.is_valid():
				rd.free_rid(pipeline)
			if nearest_sampler.is_valid():
				rd.free_rid(nearest_sampler)

func _ensure_shader() -> bool:
	if pipeline.is_valid():
		return true
	if not rd:
		return false
	if not nearest_sampler.is_valid():
		var ss := RDSamplerState.new()
		ss.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		ss.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		ss.min_lod = 0.0
		ss.max_lod = 0.0
		# Godot 4.7：RDSamplerState 无 repeat_filter；repeat_u/v/w 类型是 RenderingDevice.SamplerRepeatMode 枚举（不是 bool）。
		# clamp-to-edge 即屏幕空间采色/深度缓冲要的行为。
		ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		ss.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		nearest_sampler = rd.sampler_create(ss)
		if not nearest_sampler.is_valid():
			return false
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = SHADER_CODE
	# Godot 4.7 已无 shader_create_from_source：须先编译 SPIR-V 再创建（两步）。
	var spirv := rd.shader_compile_spirv_from_source(src, true)
	shader = rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		push_error("DOFEffect: compute shader 编译失败")
		return false
	pipeline = rd.compute_pipeline_create(shader)
	return pipeline.is_valid()

func _render_callback(_cb_type: int, render_data: RenderData) -> void:
	if not rd or not _ensure_shader():
		return
	var render_scene_buffers = render_data.get_render_scene_buffers()
	if render_scene_buffers == null:
		return
	var size: Vector2i = render_scene_buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	# Godot 4.7：颜色/深度纹理都从 RenderSceneBuffersRD 取，RenderDataRD 无 get_framebuffer_color_texture。
	var color_tex: RID = render_scene_buffers.get_color_texture()
	var depth_tex: RID = render_scene_buffers.get_depth_texture()
	if not color_tex.is_valid() or not depth_tex.is_valid():
		return

	# binding 0: 颜色缓冲（可读写 image）
	var u_color := RDUniform.new()
	u_color.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_color.binding = 0
	u_color.add_id(color_tex)

	# binding 1: 深度纹理（sampler + texture）
	var u_depth := RDUniform.new()
	u_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_depth.binding = 1
	u_depth.add_id(nearest_sampler)
	u_depth.add_id(depth_tex)

	var uniform_set := UniformSetCacheRD.get_cache(shader, 0, [u_color, u_depth])

	# push constant（std430：vec2 + 7 float）
	var pc := PackedFloat32Array()
	pc.append(size.x)
	pc.append(size.y)
	pc.append(focus_distance)
	pc.append(aperture)
	pc.append(max_blur)
	pc.append(cam_near)
	pc.append(cam_far)
	pc.append(dof_on)
	pc.append(0.0)

	var pc_bytes: PackedByteArray = pc.to_byte_array()
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_set_push_constant(cl, pc_bytes, pc_bytes.size())
	rd.compute_list_dispatch(cl, int(ceil(size.x / 8.0)), int(ceil(size.y / 8.0)), 1)
	rd.compute_list_end()
