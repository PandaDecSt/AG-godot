shader_type spatial;
// MMD 外观着色器（镜像 AfterglowWeb/src/shader/pmx/main-fs.ts 的 NPR 路径）。
// Godot 4 在顶点阶段会自动按骨骼把 VERTEX / NORMAL 蒙皮好，自定义着色器直接消费已蒙皮属性。
// render_mode cull_disabled（双面渲染）：对齐原版 pmx-viewer.ts:602 主管线 cullMode:"none"。
// MMD 模型大量使用单面薄几何（头发/裙摆/布料），必须双面渲染才能从两侧都可见；
// 单面剔除(cull_back)会把背面那些面砍掉 → "某些面一侧看得到另一侧看不到"。
// 注：v1 未开 FLIP_Z 时 cull_disabled 会整模型消失（那时绕序/法线朝内）；
//     现在 FLIP_Z=true 绕序已正常，cull_disabled 安全（不会消失）。
// 本文件为【不透明】变体：不写 blend_mix，走不透明渲染通道 + 深度测试。
//   —— 关键：blend_mix 会把材质强制塞进“透明通道”，导致 22/23 个本应不透明的材质出现
//      “背后内表面透过前表面”的鬼影（看起来半透明、且把前表面贴图糊掉）。所以不透明材质绝不开启它。
//   —— 只有真正半透的材质才用 mmd_material_transparent.gdshader（带 blend_mix）。
// depth_draw_always：保证正确遮挡。
//
// ===== 阴影方案（关键）=====
// 不再用 unshaded（那样 Godot 内置光照被跳过、也拿不到方向光阴影）。改为自定义 light() 钩子：
//   - 用 Godot 内置 LIGHT（视图空间、指向光源）、LIGHT_COLOR（含 energy*PI）、ATTENUATION（阴影衰减 1=无阴影/0=全阴影）。
//   - 光照方向/阴影由场景 DirectionalLight3D 决定（SunLight 已 shadow_enabled=true），无需 CPU 每帧手传。
//   - toon 明暗按原版把阴影折进色阶：shadowedNL = min(NdotL, ATTENUATION*2-1)，阴影区落到 toon 最暗端。
//   - render_mode ambient_light_disabled：关掉 Godot 环境光（我们的 NPR 自己算 ambient_color），避免双重叠加。
//   - ALBEDO 固定 = 1，最终颜色 = light() 写入的 DIFFUSE_LIGHT（已是完整 NPR 颜色，含 filmic tonemap）。
//   - 注：Godot 4 禁止 fragment/light 间共享可变全局变量，故全部颜色计算都放在 light() 里（light 可采样纹理、
//     读所有 uniform 与内置 LIGHT/LIGHT_COLOR/ATTENUATION/FRONT_FACING）；fragment() 只算 alpha/discard。
// 注：light_dir/light_color 两个 uniform 仍保留声明（importer 每帧还在 set，避免报错），但光照已改用内置 LIGHT/LIGHT_COLOR。
//
// ===== 图层栈（用户可控）=====
// 5 个效果层按 layer_order[5] 的顺序合成；layer_mask 的 5 个比特决定每层开关：
//   位 0(=1) = TOON 色阶（乘） | 位 1(=2) = 镜面高光（加） | 位 2(=4) = 边缘光（加）
//   位 3(=8) = 自发光（加）    | 位 4(=16)= SPHERE 高光（按 sphere_mode：1=乘 2=加）
// 默认 layer_mask=31（全开）、layer_order=[0,1,2,3,4]。由 Inspector 面板(mmd_layers.gd)每帧写入。
render_mode ambient_light_disabled, cull_disabled, depth_draw_always;

uniform sampler2D albedo_tex : source_color, filter_linear, repeat_enable;
uniform sampler2D toon_tex : source_color, filter_linear;
uniform sampler2D sphere_tex : source_color, filter_linear;

uniform bool use_albedo = true;
uniform bool use_sphere = false;
uniform float sphere_mode = 1.0;          // 1 = matcap(乘), 2 = add(按UV)
uniform vec3 base_tint = vec3(1.0);
uniform float alpha = 1.0;                 // 材质不透明度（来自 PMX diffuse.a），不透明面的权威来源
uniform vec3 specular_color = vec3(0.0);
uniform float shininess = 16.0;
uniform vec3 ambient_color = vec3(0.5);
uniform vec3 rim_color = vec3(0.0);
uniform float rim_power = 2.0;
uniform float rim_strength = 0.0;
uniform float emission_strength = 0.0;

// 保留声明（importer 每帧仍 set，但光照已改用内置 LIGHT/LIGHT_COLOR/ATTENUATION 以接收阴影）
uniform vec3 light_dir = vec3(0.0, 0.0, 1.0);
uniform vec3 light_color = vec3(1.0);

// 图层栈控制
uniform int layer_mask = 31;               // 每层开关（位掩码，见上）
uniform int layer_order[5];                // 合成顺序（0..4 的排列），未初始化时由 GDScript 写入

// 调试开关：0=正常；1=纯贴图(排查光照)；2=UV 网格(排查 UV)；3=法线(排查法线)
uniform int debug_mode = 0;

// 曝光 + 着色器内 Filmic Tonemap：精确对齐 AfterglowWeb src/passes/pmx-tonemapper.ts 的 Hable/Uncharted2 filmic 曲线。
// 参数 A=0.22 B=0.30 C=0.10 D=0.20 E=0.01 F=0.30，白点=11.2 归一化（见 buildFilmicLUT）。
// 原版 pmx-viewer.ts:375 用的就是 "filmic"（不是 ACES）。之前用 ACES 近似把迎光面(~2.0)只压到 0.92 → 仍过曝；
// 原版 filmic 压到 ~0.67，亮部才有层次。Godot 视口自动做 sRGB 编码，故这里不再做 gamma（原版在 grade 后才 pow(1/2.2)）。
uniform float exposure = 1.0;
// 色彩分级（对齐原版 pmx-tonemapper.ts:63 gradeColor）：饱和度 + 对比度。
// 原版后期在 filmic 之后必经此步；我们之前漏了 → 颜色偏灰偏平、缺乏动漫透亮感。
// 默认略 boost（saturation 1.15 / contrast 1.08），可在 Inspector 逐材质微调。
uniform float saturation = 1.15;
uniform float contrast = 1.08;
uniform float toon_edge_aa = 1.0;       // toon 终止线抗闪：1=开(屏空间超采样平滑明暗交界、消火花噪点)，0=关(原始线性采样)

// ===== reze 预设系统接入（per-material 角色预设 + look pack + grade）=====
// toon_tex 现在是【彩色三段色阶】贴图（对齐 reze ramp_linear_3 / ramp_cardinal）：
//   阴影端色调 → 中间调 → 受光端白。乘到 baseColor 上，忠实还原 reze 每角色的独立明暗色。
// 旧版只取 .r 灰度；新版取 .rgb 全彩。未套预设时回退为中性灰度色阶（视觉不变）。
uniform float mat_saturation = 1.0;     // per-material 饱和度（reze hue_sat.saturation）
uniform float mat_value = 1.0;         // per-material 明度倍率（reze hue_sat.value）
uniform float sphere_strength = 1.0;   // SPHERE 强度倍率（reze sphere_map.strength）
uniform vec3 world_color = vec3(1.0);  // 全局世界色（reze look pack world）：乘到环境光，染遍所有表面
uniform int tonemap_mode = 1;          // 0=standard(直出，对齐 WuWa) 1=filmic(对齐 AG，Hable 曲线)
// grade 分色调（split-tone，对齐 reze grades.json 的 shadows/highlights 色轮）：
//   暗部染 grade_shadow_tint，亮部染 grade_highlight_tint，中间按亮度插值。
uniform vec3 grade_shadow_tint = vec3(0.0);
uniform vec3 grade_highlight_tint = vec3(0.0);
// 注意：Godot GLSL 内置常量 PI/TAU/E 不可重定义，故原版 Hable 参数 A B C D E F 全部小写化（a,b,c,d,e,f）。
vec3 filmicTonemap(vec3 x) {
	float a = 0.22; float b = 0.30; float c = 0.10; float d = 0.20; float e = 0.01; float f = 0.30;
	float W = 11.2;
	float wp = ((W * (a * W + c * b) + d * e) / (W * (a * W + b) + d * f)) - e / f;
	vec3 res = ((x * (a * x + c * b) + d * e) / (x * (a * x + b) + d * f)) - e / f;
	return max(res, vec3(0.0)) / wp;
}

// 色彩分级：精确对齐原版 pmx-tonemapper.ts:63 gradeColor。
// 原版 slope=grade3(高光)、offset=grade(阴影)、power=grade2(中间调) 取默认中性(1,0,1)，
// 仅 saturation(grade2.w)、contrast(toneUBO) 为可调项。这里同样保留中性 slope/offset/power，
// 只把用户可调的 saturation/contrast 接进来（Godot 视口自动做 sRGB 编码，故不用再 pow(1/gamma)）。
vec3 gradeColor(vec3 c) {
	vec3 slope = vec3(1.0);
	vec3 offset = vec3(0.0);
	vec3 power = vec3(1.0);
	vec3 x = pow(max(c * slope + offset, vec3(0.0)), power);
	x = (x - vec3(0.5)) * contrast + vec3(0.5);
	float luma = dot(x, vec3(0.2126, 0.7152, 0.0722));
	return max(mix(vec3(luma), x, saturation), vec3(0.0));
}

// ===== 顶点阶段（关键：修复蒙皮网格不投射方向光阴影）=====
// Godot 4 对蒙皮网格会在顶点阶段自动注入骨骼变换（USE_SKELETON），
// VERTEX / NORMAL 进入本函数时已是骨皮后的本地坐标。
// 必须声明 vertex() 函数：Godot 才会为【阴影深度通道】生成带骨骼蒙皮的变体；
// 若 ShaderMaterial 完全不写 vertex()，阴影 depth pass 走不含骨骼的退化路径 → 蒙皮网格不投射方向光阴影
// （这就是红方块（内置材质，自带 depth 变体）能投影、角色（自定义着色器）不投影的根因）。
// 这里纯透传 VERTEX，默认顶点变换(WORLD_MATRIX)自动把骨皮后位置送往裁剪空间，
// 主渲染与阴影共用同一骨皮结果，外观与之前完全一致。
void vertex() {
	vec3 skinned_pos = VERTEX;   // 骨皮后本地坐标（Godot 自动注入）
	VERTEX = skinned_pos;       // 透传；确保函数体非空，避免被优化成“无 vertex()”
}

void fragment() {
	// 双面修正：背面(FRONT_FACING=false)法线朝内，翻过来写回 NORMAL，light() 据此两面都朝外受光。
	vec3 N = normalize(NORMAL);
	if (!FRONT_FACING) {
		N = -N;
	}
	NORMAL = N;

	// 只算不透明度：对齐原版 main-fs.ts:102 —— alpha = diffuse.a * tex.a（无条件乘贴图 alpha），
	// <0.001 直接 discard（薄纱/透肉处 tex.a≈0 → 透掉，看到后面的皮肤）。
	vec4 tex = use_albedo ? texture(albedo_tex, UV) : vec4(1.0);
	float a = alpha * tex.a;
	if (a < 0.001) discard;
	// ALBEDO 固定 1；最终颜色由 light() 写入 DIFFUSE_LIGHT（含 filmic tonemap）。
	ALBEDO = vec3(1.0);
	ALPHA = a;
}

void light() {
	// 双面法线已在 fragment() 里翻转并写回 NORMAL，这里直接用（light pass 读到的是改后的）。
	vec3 N = normalize(NORMAL);
	vec3 V = normalize(VIEW);
	vec3 L = normalize(LIGHT);             // 内置：视图空间、指向光源
	vec3 lc = LIGHT_COLOR / PI;            // 对齐原版 lightColor（energy*color，去掉内置 π）

	vec4 tex = use_albedo ? texture(albedo_tex, UV) : vec4(1.0);
	vec3 baseColor = tex.rgb * base_tint * mat_value;
	// per-material 饱和度（reze hue_sat.saturation）：在乘色阶前先按亮度去饱和/加饱和。
	{
		float l = dot(baseColor, vec3(0.299, 0.587, 0.114));
		baseColor = mix(vec3(l), baseColor, clamp(mat_saturation, 0.0, 3.0));
	}

	// ---- 调试模式：直接输出固定颜色，不走光照合成 ----
	if (debug_mode == 1) {
		DIFFUSE_LIGHT = baseColor;
		SPECULAR_LIGHT = vec3(0.0);
	} else if (debug_mode == 2) {
		DIFFUSE_LIGHT = vec3(fract(UV * 8.0), 0.5);
		SPECULAR_LIGHT = vec3(0.0);
	} else if (debug_mode == 3) {
		DIFFUSE_LIGHT = N * 0.5 + 0.5;
		SPECULAR_LIGHT = vec3(0.0);
	} else if (debug_mode == 4) {
		DIFFUSE_LIGHT = vec3(ATTENUATION);   // 阴影衰减可视化：1=无阴影(白) 0=全阴影(黑)
		SPECULAR_LIGHT = vec3(0.0);
	} else {
		// --- 视图空间 toon+阴影（点积旋转不变，等价于原版世界空间）---
		float ndl = dot(N, L);
	// 阴影：ATTENUATION 是方向光阴影衰减(1=无阴影, 0=全阴影)。消硬缝对齐原版 shadow.ts：
	//   背光面 ndl<0 时 smoothstep(0,0.35,ndl)→0，强制全阴影，避免背光面因 shadow map 边缘漏出亮缝。
	float vis = ATTENUATION;
	vis = min(vis, smoothstep(0.0, 0.35, ndl));
	// toon 折 shadow：对齐 AfterglowWeb main-fs.ts，阴影区 shadowedNL→负 → toonT=0 → 取 toon 最暗端。
	float shadowedNL = min(ndl, vis * 2.0 - 1.0);
	float toonT = clamp(shadowedNL * 0.5 + 0.5, 0.0, 1.0);
	// 真实 toon 贴图暗端可能近 0，背光面只剩 ambient，保底 0.25 避免死黑。
	// toon 终止线抗闪（对齐 reze ramp_constant_edge_aa）：对 toon 坐标做屏空间超采样，
	// 用 fwidth(toonT) 估出 1 像素的 toon 坐标跨度，在终止线两侧各取半步取平均 → 平滑闪烁的明暗交界。
	vec3 toonShade;
	if (toon_edge_aa > 0.5) {
		float aaw = max(fwidth(toonT), 1e-4) * 1.5;
		vec3 s0 = texture(toon_tex, vec2(toonT - aaw * 0.5, 0.5)).rgb;
		vec3 s1 = texture(toon_tex, vec2(toonT + aaw * 0.5, 0.5)).rgb;
		toonShade = max(mix(s0, s1, 0.5), vec3(0.25));
	} else {
		toonShade = max(texture(toon_tex, vec2(toonT, 0.5)).rgb, vec3(0.25));
	}

	vec3 nprDiffuse = baseColor * toonShade;                                // TOON：baseColor * toonShade
	vec3 H = normalize(V + L);
	vec3 specContrib = pow(max(dot(N, H), 0.0), max(shininess, 1.0)) * specular_color; // 高光
	vec3 rimContrib  = rim_color * pow(1.0 - max(dot(N, V), 0.0), rim_power) * rim_strength; // 边缘光

	// SPHERE（matcap 用视图空间法线 N.xy 即球谐 UV）
	vec3 sphereAdd = vec3(0.0);
	if (use_sphere) {
		vec2 suv = (sphere_mode > 1.5) ? UV : (N.xy * 0.5 + 0.5);
		sphereAdd = texture(sphere_tex, suv).rgb * baseColor * sphere_strength;
	}
	vec3 emis = baseColor * emission_strength;

	// ---- 图层栈：按 layer_order 顺序逐层加性合成（对齐原版 main-fs:172）----
	vec3 color = baseColor * ambient_color * world_color;          // 基础色（环境光 × 世界色）
	// 保底：所有图层被关闭(layer_mask==0)时，至少显示 baseColor 本身，避免整面纯黑无法调试。
	if (layer_mask == 0) {
		color += baseColor * 0.5;
	}
	for (int i = 0; i < 5; i++) {
		int id = layer_order[i];
		int bit = (1 << id);
		if ((layer_mask & bit) == 0) {
			continue;
		}
		if (id == 0) {
			color += nprDiffuse * lc;                  // TOON（加）：nprDiffuse * lightColor
		} else if (id == 1) {
			color += specContrib * lc;                 // 镜面高光（加）
		} else if (id == 2) {
			color += rimContrib;                       // 边缘光（加）
		} else if (id == 3) {
			color += emis;                             // 自发光（加）
		} else if (id == 4) {
			color += sphereAdd;                        // SPHERE（加）
		}
	}

		color *= mix(0.55, 1.0, vis);   // 阴影区整体再压暗，强化自阴影对比（无阴影区不变）
		vec3 hdr = color * exposure;
		// 色调映射：filmic(Hable 曲线，对齐 AG) 或 standard(直出，对齐 WuWa)。
		vec3 ldr = (tonemap_mode == 1) ? filmicTonemap(hdr) : clamp(hdr, vec3(0.0), vec3(1.0));
		vec3 graded = gradeColor(ldr);   // 色彩分级（饱和度/对比度）→ 动漫透亮感
		// grade 分色调：暗部→grade_shadow_tint，亮部→grade_highlight_tint（对齐 reze grades.json）。
		float gl = dot(graded, vec3(0.2126, 0.7152, 0.0722));
		graded += mix(grade_shadow_tint, grade_highlight_tint, smoothstep(0.2, 0.85, gl));
		DIFFUSE_LIGHT = max(graded, vec3(0.0));
		SPECULAR_LIGHT = vec3(0.0);
	}
}
