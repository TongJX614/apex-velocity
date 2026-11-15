shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float blur_lod : hint_range(0.0, 5.0) = 2.6;
uniform vec4 tint : source_color = vec4(0.035, 0.05, 0.075, 0.30);
uniform vec2 rect_size = vec2(1000.0, 180.0);
uniform float corner_radius = 11.0;

float rounded_box_sdf(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

void fragment() {
	vec2 p = (UV - 0.5) * rect_size;
	float d = rounded_box_sdf(p, rect_size * 0.5, corner_radius);
	float mask = 1.0 - smoothstep(-1.0, 1.0, d);
	vec3 blurred = textureLod(screen_tex, SCREEN_UV, blur_lod).rgb;
	COLOR = vec4(mix(blurred, tint.rgb, tint.a), mask);
}