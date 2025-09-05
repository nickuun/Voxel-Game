shader_type spatial;
render_mode cull_back, depth_draw_opaque; // keep lighting settings you need

uniform sampler2D atlas : source_color;
uniform int atlas_cols = 16;   // <- set to your atlas grid
uniform int atlas_rows = 16;
uniform float pad_px = 1.0;    // padding in pixels inside each tile to avoid bleeding

// We feed UV in "tile space": 1.0 = one tile.
// We feed tile id in UV2.x (same at all 3 verts of a tri).
vec2 tile_uv(int id, vec2 tile_uv01, vec2 tex_size_px) {
	int tx = id % atlas_cols;
	int ty = id / atlas_cols;

	vec2 tile_size = vec2(1.0 / float(atlas_cols), 1.0 / float(atlas_rows));
	// Convert pixel padding to normalized per-tile padding
	vec2 tile_size_px = tile_size * tex_size_px;
	vec2 pad = vec2(pad_px) / max(vec2(1.0), tile_size_px); // normalized padding inside tile

	vec2 minuv = vec2(float(tx), float(ty)) * tile_size + pad * tile_size;
	vec2 maxuv = minuv + tile_size - 2.0 * pad * tile_size;

	vec2 st = fract(tile_uv01);                  // repeat each 1.0
	return mix(minuv, maxuv, st);                // map 0..1 to tile rect
}

void fragment() {
	// UV2.x must be constant across the tri (we ensure that)
	int tile_id = int(round(UV2.x));
	// Godot gives texture size in pixels via textureSize() only in Vulkan; emulate via hint:
	vec2 tex_size_px = vec2(textureSize(atlas, 0));
	vec2 uv = tile_uv(tile_id, UV, tex_size_px);
	ALBEDO = texture(atlas, uv).rgb;
	ALPHA = 1.0;
}
