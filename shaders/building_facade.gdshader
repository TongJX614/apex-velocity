shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Procedural skyscraper facade: window grid, floor bands, ground-floor
// storefronts, night-time lit windows, grime and roof treatment.
// MultiMesh custom data carries the building's real-world size in meters
// (INSTANCE_CUSTOM.xyz) plus a per-instance seed (INSTANCE_CUSTOM.w), so one
// material gives every building correct window proportions.

uniform vec3 wall_tint : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 window_light_warm : source_color = vec3(1.0, 0.86, 0.62);
uniform vec3 window_light_cool : source_color = vec3(0.62, 0.78, 0.98);
uniform float night : hint_range(0.0, 1.0) = 0.0;
uniform vec2 room_size = vec2(2.7, 3.6);
uniform float storefront_height = 4.6;
uniform float glass_roughness : hint_range(0.0, 1.0) = 0.06;
uniform float facade_metalness : hint_range(0.0, 1.0) = 0.45;

varying vec3 v_local;
varying vec3 v_norm;
varying vec3 v_color;
varying vec3 v_size;
varying float v_seed;

float hash21(vec2 p) {
	p = fract(p * vec2(127.1, 311.7));
	p += dot(p, p + 41.73);
	return fract(p.x * p.y);
}

void vertex() {
	v_local = VERTEX;
	v_norm = NORMAL;
	v_color = COLOR.rgb;
	v_size = INSTANCE_CUSTOM.xyz * 100.0;
	v_seed = INSTANCE_CUSTOM.w;
}

void fragment() {
	vec3 size = v_size;
	float seed = v_seed * 97.0;
	vec3 n = normalize(v_norm);
	vec3 p = v_local * size;

	// roof / underside: plain weathered concrete
	if (n.y > 0.5) {
		float g = hash21(floor(p.xz * 1.8) + seed);
		ALBEDO = (v_color * wall_tint) * (0.28 + 0.22 * g);
		ROUGHNESS = 0.92;
		METALLIC = 0.0;
		NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	} else {
	vec2 uv;
	float face_id;
	if (abs(n.x) > 0.6) {
		uv = vec2(p.z, p.y);
		face_id = 1.0 + step(0.0, n.x);
	} else if (abs(n.z) > 0.6) {
		uv = vec2(p.x, p.y);
		face_id = 3.0 + step(0.0, n.z);
	} else {
		uv = vec2(p.x, p.z);
		face_id = 5.0;
	}

	vec3 wall = v_color * wall_tint;

	// floor + room grid
	vec2 cell_uv = uv / room_size;
	vec2 cell = fract(cell_uv);
	vec2 cell_id = floor(cell_uv);
	float window_mask = smoothstep(0.16, 0.24, cell.x) * (1.0 - smoothstep(0.74, 0.82, cell.x))
		* smoothstep(0.2, 0.28, cell.y) * (1.0 - smoothstep(0.72, 0.8, cell.y));

	// floor slab bands
	float slab = (1.0 - smoothstep(0.0, 0.06, cell.y)) + smoothstep(0.94, 1.0, cell.y);
	vec3 albedo = mix(wall, wall * 0.72, clamp(slab, 0.0, 1.0) * 0.7);
	albedo = mix(albedo, wall * 0.82, (1.0 - smoothstep(0.0, 0.03, abs(cell.x - 0.5))) * 0.12);

	// ground floor: storefront glass band
	float ground = 1.0 - smoothstep(storefront_height - 1.0, storefront_height, uv.y);
	float storefront = ground * (1.0 - smoothstep(0.06, 0.12, min(cell.y, 1.0 - cell.y)) * 0.0);
	storefront = ground * step(0.08, cell.x) * step(cell.x, 0.92);
	window_mask = max(window_mask * (1.0 - ground), storefront);

	// window glass
	float shade = hash21(cell_id + vec2(face_id, seed));
	float occupancy = hash21(cell_id * 1.7 + vec2(seed, face_id * 3.1));
	float lit = step(0.6, occupancy) * night;
	vec3 glass = mix(vec3(0.045, 0.06, 0.08), vec3(0.13, 0.17, 0.22), shade);
	glass = mix(glass, vec3(0.35, 0.42, 0.5), step(0.97, shade) * (1.0 - night)); // rare reflections
	vec3 lit_color = mix(window_light_warm, window_light_cool,
		step(0.55, hash21(cell_id + seed * 2.3)));
	lit_color *= 0.55 + 0.45 * hash21(cell_id * 0.37 + seed);
	// ground-floor shops glow a bit more, and spill near the door line
	float spill = storefront * (0.35 + 0.65 * hash21(vec2(face_id, seed)));

	// grime / ambient occlusion near the street
	float ao = mix(0.55, 1.0, smoothstep(0.0, 22.0, uv.y));
	// subtle vertical streaks
	float streak = 0.92 + 0.08 * hash21(vec2(floor(uv.x * 0.7), seed)) * smoothstep(0.0, 0.5, uv.y);
	albedo = mix(albedo, glass, window_mask);
	albedo *= ao * streak;

	float roughness = mix(0.88, glass_roughness, window_mask);
	float metallic = mix(0.0, facade_metalness, window_mask);
	ALBEDO = albedo;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	EMISSION = lit_color * lit * window_mask * 1.05 + lit_color * spill * night * 0.3;
	}
}
