shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;
// 车灯贴图里只有红色尾灯/示宽灯发光，白色前灯与转向灯保持原样。
// 作为 StandardMaterial3D 的 next_pass 叠加，不替换原 PBR 材质。

uniform sampler2D light_tex : source_color, filter_linear_mipmap;
uniform float strength : hint_range(0.0, 2.0) = 0.85;

void fragment() {
	vec4 c = texture(light_tex, UV);
	float red_dominance = c.r - max(c.g, c.b);
	float mask = smoothstep(0.035, 0.24, red_dominance);
	ALBEDO = vec3(1.7, 0.10, 0.055) * mask * strength;
	ALPHA = 1.0;
}