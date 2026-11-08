shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// World-space box-projected building facade. The city GLB has no UVs, so walls
// are projected on the dominant horizontal axis; horizontal faces above the
// street use a roof texture. Alpha of the facade textures is the glazing mask
// (roughness/metallic), not transparency.

uniform vec4 base_color : source_color = vec4(0.8, 0.8, 0.8, 1.0);
uniform vec4 facade_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform sampler2D facade_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D storefront_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roof_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D pavement_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec2 facade_world_size = vec2(12.8, 12.8);
uniform vec2 facade_grid = vec2(4.0, 4.0);
uniform vec2 facade_offset = vec2(0.0, 0.0);
uniform vec2 storefront_offset = vec2(0.0, 0.0);
uniform vec2 roof_offset = vec2(0.0, 0.0);
uniform float window_metal = 0.18;
uniform float window_rough = 0.16;
uniform float wall_rough = 0.9;
uniform float storefront_h = 4.2;
uniform float roof_min_y = 4.0;
uniform float lit_chance = 0.12;
uniform float seed = 0.0;
uniform float pavement_world_size = 6.0;
// 0..1: procedural facade micro-detail (mullions, recessed windows, AC units,
// balconies, floor bands). Low quality sets 0 to keep the fill rate flat.
uniform float detail_amt = 1.0;
// 1.0 = only treat up-facing surfaces (roof decks, elevated plazas); walls
// keep their original flat color. Used for materials that are not buildings.
uniform float roof_only = 0.0;
uniform float storefront_strength = 1.0;

varying vec3 world_pos;
varying vec3 world_normal;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 n = normalize(world_normal);
	// 坡屋顶（30°~45°）的 |n.y| 在 0.7~0.87，旧范围会在墙/顶之间留一条
	// 空档，整块屋面退回 base_color 变成纯白石膏。窗口收窄到覆盖陡坡。
	float wall_mask = 1.0 - smoothstep(0.30, 0.60, abs(n.y));
	float roof_mask = smoothstep(0.45, 0.72, abs(n.y));
	if (roof_only > 0.5) {
		// 这些材质还兼作真楼的外墙（米色/浅灰），全关会把整栋楼涂成纯色石膏。
		// 只把近地的路缘、挡墙压平，抬高的墙体照常走立面。
		wall_mask *= smoothstep(1.2, 2.6, world_pos.y);
	}

	vec3 albedo = base_color.rgb;
	float rough = wall_rough;
	float metal = 0.0;
	vec3 emission = vec3(0.0);

	// ---- facades ----------------------------------------------------------
	if (wall_mask > 0.001) {
		vec2 fuv;
		if (abs(n.x) >= abs(n.z)) {
			fuv = vec2(world_pos.z, world_pos.y);
		} else {
			fuv = vec2(world_pos.x, world_pos.y);
		}
		vec2 fcoord = fuv / facade_world_size + facade_offset;
		vec4 ft = texture(facade_tex, fcoord);

		vec2 cell = floor(fcoord * facade_grid);
		float h1 = hash12(cell + vec2(seed * 17.0, seed * 31.0));
		float h2 = hash12(cell * 1.37 + vec2(seed * 7.0, seed * 13.0));

		vec3 texcol = ft.rgb;
		// break the repeating tile: per-window tint + occasional interior lights
		texcol = mix(texcol, texcol * vec3(0.88, 0.97, 1.09), (h2 - 0.5) * 0.5 * ft.a);
		float lit = step(1.0 - lit_chance, h1) * ft.a;
		texcol = mix(texcol, vec3(1.0, 0.80, 0.52) * (0.7 + 0.4 * h2), lit * 0.65);

		// ---- procedural facade micro-detail --------------------------------
		vec2 tile = fract(fcoord * facade_grid);
		vec2 edge2 = min(tile, 1.0 - tile);
		float edge_d = min(edge2.x, edge2.y);
		float glass = ft.a * wall_mask * detail_amt;
		// aluminium frame around every window + dark recess just inside it
		float frame = 1.0 - smoothstep(0.012, 0.055, edge_d);
		float inner = smoothstep(0.0, 0.16, edge_d);
		texcol = mix(texcol, texcol * 0.52, frame * glass * 0.85);
		texcol *= 1.0 - (1.0 - inner) * glass * 0.24;
		float sill = (1.0 - smoothstep(0.0, 0.10, edge2.y)) * (1.0 - frame);
		texcol = mix(texcol, texcol * 1.28 + vec3(0.05), sill * (1.0 - ft.a) * detail_amt * 0.35);
		// faint horizontal floor slab line between window rows
		float slab = 1.0 - smoothstep(0.0, 0.045, edge2.y);
		texcol *= 1.0 - slab * (1.0 - ft.a) * detail_amt * 0.12;
		// window-mounted AC boxes / balcony slabs on a subset of cells
		float ac_roll = hash12(cell * 2.13 + vec2(seed * 5.0, seed * 23.0));
		float acs = step(0.90, ac_roll) * detail_amt;
		vec2 ac_uv = (tile - vec2(0.5, 0.06)) * vec2(4.2, 7.5);
		float ac_box = step(max(abs(ac_uv.x), abs(ac_uv.y)), 1.0) * acs;
		float balcony = step(0.955, ac_roll) * detail_amt;
		float bal = step(0.02, tile.y) * step(tile.y, 0.09)
			* step(0.18, tile.x) * step(tile.x, 0.82) * balcony;
		vec3 metal_col = vec3(0.66, 0.68, 0.70) * (0.85 + 0.3 * h2);
		texcol = mix(texcol, metal_col, ac_box * (1.0 - ft.a) * 0.8);
		texcol = mix(texcol, vec3(0.30, 0.32, 0.34), bal * (1.0 - ft.a) * 0.55);

		// recessed windows: tilt the normal at the frame so edges catch light
		if (detail_amt > 0.01) {
			vec3 tang = (abs(n.x) >= abs(n.z)) ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
			vec2 wdir = sign(tile - 0.5);
			float bevel = frame * ft.a * detail_amt;
			vec3 wn = normalize(n + (tang * wdir.x * 0.34 + vec3(0.0, 1.0, 0.0) * wdir.y * 0.24) * bevel);
			NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
		}

		vec3 facade_col = texcol * facade_tint.rgb;
		float mottle = 0.95 + 0.10 * (0.5 + 0.5 * sin(world_pos.x * 0.21 + seed * 6.28)
			* sin(world_pos.z * 0.17 + seed * 4.71));
		facade_col *= mottle;

		float window_mix = wall_mask * smoothstep(0.0, 0.25, world_pos.y);
		albedo = mix(albedo, facade_col, window_mix);
		rough = mix(rough, mix(wall_rough, window_rough, ft.a), window_mix);
		metal = mix(metal, window_metal * ft.a, window_mix);
		emission += vec3(1.0, 0.72, 0.38) * lit * wall_mask * 0.14;
	}

	// ---- street level: shop fronts, signs, doors -------------------------
	float band = smoothstep(0.02, 0.35, world_pos.y)
		* (1.0 - smoothstep(storefront_h - 0.55, storefront_h, world_pos.y))
		* storefront_strength;
	if (wall_mask > 0.001 && band > 0.001) {
		float su = (abs(n.x) >= abs(n.z)) ? world_pos.z : world_pos.x;
		vec4 st = texture(storefront_tex, vec2(su * 0.0625 + storefront_offset.x, 1.0 - world_pos.y / storefront_h));
		albedo = mix(albedo, st.rgb, band * wall_mask * 0.95);
		rough = mix(rough, mix(0.72, 0.07, st.a), band * wall_mask);
		metal = mix(metal, st.a * 0.42, band * wall_mask);
		emission += vec3(1.0, 0.82, 0.55) * st.a * band * 0.035;
	}

	// ---- rooftops ---------------------------------------------------------
	// roof_min_y 只用来区分「屋顶 / 地面铺装」（roof_only 材质），建筑材质
	// 不能按世界高度过滤：郊区环上的低矮小屋屋顶总高可能不到 4m，会被
	// 完全抹回 base_color，从高处看就是一片白石膏。
	float roof_fade = (roof_only > 0.5)
		? smoothstep(roof_min_y, roof_min_y + 0.6, world_pos.y)
		: 1.0;
	if (roof_mask > 0.001 && roof_fade > 0.001) {
		vec4 rt = texture(roof_tex, world_pos.xz / 16.0 + roof_offset);
		// roof-only materials keep a hint of their original color (brown decks,
		// light plazas), while building materials use the neutral gravel look
		vec3 roof_tint = mix(vec3(0.92, 0.93, 0.95),
			clamp(base_color.rgb, vec3(0.25), vec3(1.0)), roof_only * 0.45);
		albedo = mix(albedo, rt.rgb * roof_tint, roof_mask * roof_fade);
		rough = mix(rough, 0.94, roof_mask * roof_fade);
		metal = mix(metal, 0.0, roof_mask * roof_fade);
	}

	// ---- ground level of roof-only materials: sidewalk / plaza paving -----
	if (roof_only > 0.5 && roof_mask > 0.001 && world_pos.y <= roof_min_y) {
		vec4 pt = texture(pavement_tex, world_pos.xz / pavement_world_size + roof_offset);
		vec3 paving = pt.rgb * clamp(base_color.rgb * 2.0, vec3(0.0), vec3(1.0));
		albedo = mix(albedo, paving, roof_mask);
		rough = mix(rough, 0.86, roof_mask);
		metal = mix(metal, 0.0, roof_mask);
	}

	ALBEDO = albedo;
	ROUGHNESS = clamp(rough, 0.04, 1.0);
	METALLIC = clamp(metal, 0.0, 1.0);
	SPECULAR = 0.5;
	EMISSION = emission;
}
