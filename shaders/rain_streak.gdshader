shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;
// 雨丝 billboard + 近相机淡出。追尾相机与雨体积重叠时，离镜头 <3m 的雨条
// 会完全透明，3~7m 渐入，避免一根雨丝糊满整屏。

uniform sampler2D rain_tex : source_color, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(0.66, 0.77, 0.92, 0.5);
uniform float near_fade_start = 1.5;
uniform float near_fade_end = 4.0;

varying float v_fade;

void vertex() {
	// Godot 4 粒子 billboard：保留每颗粒子的平移和缩放，朝向相机。
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0],
		INV_VIEW_MATRIX[1],
		INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));

	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 cam_pos = INV_VIEW_MATRIX[3].xyz;
	v_fade = smoothstep(near_fade_start, near_fade_end, distance(world_pos, cam_pos));
}

void fragment() {
	vec4 c = texture(rain_tex, UV);
	ALBEDO = tint.rgb;
	ALPHA = c.a * tint.a * v_fade;
}