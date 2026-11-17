shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

// 车头段遮罩：只点亮模型坐标 +Z（车头）的灯面，保留原厂大灯灯罩形状；
// 车尾段（-Z）mask=0，不影响尾灯那层红光。
uniform float strength : hint_range(0.0, 4.0) = 0.0;
uniform float front_z : hint_range(0.0, 3.0) = 1.0;
uniform vec3 head_color : source_color = vec3(1.6, 1.5, 1.25);

void fragment() {
	vec4 world = INV_VIEW_MATRIX * vec4(VERTEX, 1.0);
	vec3 local = (inverse(MODEL_MATRIX) * world).xyz;
	float mask = smoothstep(front_z - 0.35, front_z + 0.35, local.z);
	ALBEDO = head_color * mask * strength;
	ALPHA = 1.0;
}