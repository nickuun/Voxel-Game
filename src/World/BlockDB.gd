extends Node
class_name BlockDB

# ----- Atlas config -----
const ATLAS_PATH := "res://assets/blocks_atlas.png"
const TILE_SIZE := 16
const ATLAS_SIZE := Vector2i(256, 256)

# use int(...) instead of // to force integer division
const TILES_PER_ROW := int(ATLAS_SIZE.x / TILE_SIZE)

static var _cached_atlas := Vector2(ATLAS_SIZE.x, ATLAS_SIZE.y)
static var _cached_cols  := TILES_PER_ROW

static var ENTITY_SCENES := {
	BlockId.CHEST: preload("res://src/entities/chest/Chest.tscn"),
	# add more entity blocks here as you create them
}

static func configure_from_texture(tex: Texture2D) -> void:
	if tex:
		_cached_atlas = Vector2(tex.get_width(), tex.get_height())
		_cached_cols  = int(tex.get_width() / TILE_SIZE)
		
static var ENTITY_FACING_YAW_DEG := {
	BlockId.CHEST: 0.0,  # adjust per model if needed
}

static func entity_facing_yaw_deg(id: int) -> float:
	var v: float = 0.0
	if ENTITY_FACING_YAW_DEG.has(id):
		v = float(ENTITY_FACING_YAW_DEG[id])
	return v

# ----- Blocks -----
# ----- Blocks -----
enum BlockId {
	AIR=0, GRASS=1, DIRT=2, STONE=3, WOOD=4, LEAVES=5, BLACKSAND=6,
	LOG=8, SAPLING=9,
	GLASS=10,
	COBBLE=11,
	MOSSY_COBBLE=12,
	STONE_BRICKS=13,
	MOSSY_STONE_BRICKS=14,
	CLAY_BRICKS=15,
	ICE=18,
	CLAY_TILE=19,
	SNOW_DIRT=20,
	
	# oriented variants for logs (horizontal)
	LOG_X=16,  # axis along +/−X
	LOG_Z=17,  # axis along +/−Z
	
	# Birch
	LOG_BIRCH=21, LOG_BIRCH_X=22, LOG_BIRCH_Z=23, WOOD_BIRCH=24,
	# Spruce
	LOG_SPRUCE=25, LOG_SPRUCE_X=26, LOG_SPRUCE_Z=27, WOOD_SPRUCE=28,
	# Acacia
	LOG_ACACIA=29, LOG_ACACIA_X=30, LOG_ACACIA_Z=31, WOOD_ACACIA=32,
	# Jungle
	LOG_JUNGLE=33, LOG_JUNGLE_X=34, LOG_JUNGLE_Z=35, WOOD_JUNGLE=36,
	
	CHEST = 37,
}

# --- Micro-voxel / notch ids (one item-id per base block you want) ---
enum NotchId {
	NOTCH_GRASS = 1001,
	NOTCH_DIRT  = 1002,
	NOTCH_STONE = 1003,
	NOTCH_WOOD  = 1004,
	NOTCH_BLACKSAND  = 1005,
	NOTCH_GLASS = 1006,
	NOTCH_COBBLE = 1007,
	NOTCH_STONE_BRICKS = 1008,
	NOTCH_MOSSY_STONE_BRICKS = 1009,

	NOTCH_LEAVES = 1010,

	# one per log species so visuals don't get overwritten
	NOTCH_LOG_OAK    = 1011,
	NOTCH_LOG_BIRCH  = 1012,
	NOTCH_LOG_SPRUCE = 1013,
	NOTCH_LOG_ACACIA = 1014,
	NOTCH_LOG_JUNGLE = 1015,
}

static var NOTCH_TO_BASE := {
	NotchId.NOTCH_GRASS: BlockId.GRASS,
	NotchId.NOTCH_DIRT:  BlockId.DIRT,
	NotchId.NOTCH_STONE: BlockId.STONE,
	NotchId.NOTCH_WOOD:  BlockId.WOOD,
	NotchId.NOTCH_BLACKSAND:  BlockId.BLACKSAND,
	NotchId.NOTCH_GLASS: BlockId.GLASS,
	NotchId.NOTCH_COBBLE: BlockId.COBBLE,
	NotchId.NOTCH_STONE_BRICKS: BlockId.STONE_BRICKS,
	NotchId.NOTCH_MOSSY_STONE_BRICKS: BlockId.MOSSY_STONE_BRICKS,

	NotchId.NOTCH_LEAVES: BlockId.LEAVES,

	NotchId.NOTCH_LOG_OAK:    BlockId.LOG,
	NotchId.NOTCH_LOG_BIRCH:  BlockId.LOG_BIRCH,
	NotchId.NOTCH_LOG_SPRUCE: BlockId.LOG_SPRUCE,
	NotchId.NOTCH_LOG_ACACIA: BlockId.LOG_ACACIA,
	NotchId.NOTCH_LOG_JUNGLE: BlockId.LOG_JUNGLE,
}

static var BASE_TO_NOTCH := {
	BlockId.GRASS: NotchId.NOTCH_GRASS,
	BlockId.DIRT:  NotchId.NOTCH_DIRT,
	BlockId.STONE: NotchId.NOTCH_STONE,
	BlockId.WOOD:  NotchId.NOTCH_WOOD,
	BlockId.BLACKSAND:  NotchId.NOTCH_BLACKSAND,
	BlockId.GLASS: NotchId.NOTCH_GLASS,
	BlockId.COBBLE: NotchId.NOTCH_COBBLE,
	BlockId.STONE_BRICKS: NotchId.NOTCH_STONE_BRICKS,
	BlockId.MOSSY_STONE_BRICKS: NotchId.NOTCH_MOSSY_STONE_BRICKS,
	BlockId.LEAVES: NotchId.NOTCH_LEAVES,

	# OAK (all orientations drop the same oak notch)
	BlockId.LOG:   NotchId.NOTCH_LOG_OAK,
	BlockId.LOG_X: NotchId.NOTCH_LOG_OAK,
	BlockId.LOG_Z: NotchId.NOTCH_LOG_OAK,

	# BIRCH
	BlockId.LOG_BIRCH:   NotchId.NOTCH_LOG_BIRCH,
	BlockId.LOG_BIRCH_X: NotchId.NOTCH_LOG_BIRCH,
	BlockId.LOG_BIRCH_Z: NotchId.NOTCH_LOG_BIRCH,

	# SPRUCE
	BlockId.LOG_SPRUCE:   NotchId.NOTCH_LOG_SPRUCE,
	BlockId.LOG_SPRUCE_X: NotchId.NOTCH_LOG_SPRUCE,
	BlockId.LOG_SPRUCE_Z: NotchId.NOTCH_LOG_SPRUCE,

	# ACACIA
	BlockId.LOG_ACACIA:   NotchId.NOTCH_LOG_ACACIA,
	BlockId.LOG_ACACIA_X: NotchId.NOTCH_LOG_ACACIA,
	BlockId.LOG_ACACIA_Z: NotchId.NOTCH_LOG_ACACIA,

	# JUNGLE
	BlockId.LOG_JUNGLE:   NotchId.NOTCH_LOG_JUNGLE,
	BlockId.LOG_JUNGLE_X: NotchId.NOTCH_LOG_JUNGLE,
	BlockId.LOG_JUNGLE_Z: NotchId.NOTCH_LOG_JUNGLE,
}


# base block id -> notch item id
static var _notch_from_base: Dictionary = {}

static func notch_item_for_base(base_id:int) -> int:
	return int(_notch_from_base.get(base_id, base_id))  # fallback: drop base block


static func is_notch(id:int) -> bool:
	return NOTCH_TO_BASE.has(id)

static func notch_base(id:int) -> int:
	return NOTCH_TO_BASE.get(id, -1)

static func notch_from_base(base_id:int) -> int:
	return BASE_TO_NOTCH.get(base_id, -1)

static func register_notch_blocks() -> void:
	_notch_from_base.clear()

	for base_id in BASE_TO_NOTCH.keys():
		var notch_id := int(BASE_TO_NOTCH[base_id])
		_notch_from_base[base_id] = notch_id

		# If this notch was already created (e.g. multiple orientations map to it), keep the first.
		if BLOCKS.has(notch_id):
			continue

		var b = BLOCKS.get(base_id, {})

		var entry := {
			"name": String(b.get("name", "Block")) + " (Notch)",
			"opaque": false,                                   # items/pickups shouldn't be lit as opaque
			"transparent": b.get("transparent", false),
		}

		# Copy all the face keys so visuals match the base exactly
		for k in ["tex_all", "tex_top", "tex_bottom", "tex_side", "tex_end", "orient"]:
			if b.has(k):
				entry[k] = b[k]

		# Provide a good icon tile for UI (optional but handy)
		if b.has("tex_top"):
			entry["icon_tile"] = b["tex_top"]                 # grass gets green
		elif b.has("tex_side"):
			entry["icon_tile"] = b["tex_side"]                # logs/leaves/etc.
		else:
			entry["icon_tile"] = b.get("tex_all", 0)

		BLOCKS[notch_id] = entry


# ⚠️ Set these tile indices to match your atlas (numbers below are placeholders).
# Keep the ones you already had the same.
static var BLOCKS := {
	BlockId.AIR:    {"name":"Air", "opaque":false},

	# existing
	BlockId.GRASS:  {"name":"Grass","opaque":true, "tex_top":32, "tex_side":31, "tex_bottom":32},
	BlockId.DIRT:   {"name":"Dirt", "opaque":true,  "tex_all":21},
	BlockId.STONE:  {"name":"Stone","opaque":true,  "tex_all":1},
	BlockId.WOOD:   {"name":"Wood Planks","opaque":true, "tex_all":6},
		BlockId.LEAVES: {
		"name":"Leaves",
		"opaque": true,                   # was true → this was forcing cull
		"transparent": false,
		"tex_all": 3,
	},
	#BlockId.LEAVES: {
		#"name":"Leaves",
		#"opaque": false,                   # was true → this was forcing cull
		#"transparent": true,
		#"tex_all": 83,
		#"cull_same_transparent": false,     # <— NEW: keep faces between touching leaves
		#"two_sided": true
	#},
	BlockId.BLACKSAND:   {"name":"Sand", "opaque":true,  "tex_all":2},
	BlockId.GLASS: {
		"name":"Glass",
		"opaque": false,
		"transparent": true,
		"tex_all": 28,
		"cull_same_transparent": true
	},
	BlockId.COBBLE:              {"name":"Cobblestone",        "opaque":true,  "tex_all":7},
	BlockId.MOSSY_COBBLE:        {"name":"Mossy Cobblestone",  "opaque":true,  "tex_all":10},
	BlockId.STONE_BRICKS:        {"name":"Stone Bricks",       "opaque":true,  "tex_all":8},
	BlockId.MOSSY_STONE_BRICKS:  {"name":"Mossy Stone Bricks", "opaque":true,  "tex_all":9},
	BlockId.CLAY_BRICKS:         {"name":"Clay Bricks",        "opaque":true,  "tex_all":69},

	# logs (LOG = vertical/Y; X/Z are oriented variants). tex_end = rings, tex_side = bark
	BlockId.LOG:   {"name":"Log (Y)","opaque":true, "tex_side":4, "tex_end":5, "orient":"y",
		"orient_variants": {"x": BlockId.LOG_X, "y": BlockId.LOG, "z": BlockId.LOG_Z}},
	BlockId.LOG_X: {"name":"Log (X)","opaque":true, "tex_side":4, "tex_end":5, "orient":"x",
		"orient_variants": {"x": BlockId.LOG_X, "y": BlockId.LOG, "z": BlockId.LOG_Z}},
	BlockId.LOG_Z: {"name":"Log (Z)","opaque":true, "tex_side":4, "tex_end":5, "orient":"z",
		"orient_variants": {"x": BlockId.LOG_X, "y": BlockId.LOG, "z": BlockId.LOG_Z}},

	# New simple blocks
	BlockId.CLAY_TILE: {"name":"Clay Tile", "opaque":true, "tex_all": 68},
	BlockId.ICE:       {"name":"Ice", "opaque":false, "transparent":true,
		"tex_top": 37, "tex_bottom": 37, "tex_side": 38},
	BlockId.SNOW_DIRT: {"name":"Snowy Dirt", "opaque":true,
		"tex_top": 76, "tex_side": 33, "tex_bottom": 21},
	
	# --- Birch ---
	BlockId.LOG_BIRCH:   {"name":"Birch Log (Y)","opaque":true, "tex_side": 58, "tex_end": 59, "orient":"y", # TODO
		"orient_variants": {"x": BlockId.LOG_BIRCH_X, "y": BlockId.LOG_BIRCH, "z": BlockId.LOG_BIRCH_Z}},
	BlockId.LOG_BIRCH_X: {"name":"Birch Log (X)","opaque":true, "tex_side": 58, "tex_end": 59, "orient":"x",
		"orient_variants": {"x": BlockId.LOG_BIRCH_X, "y": BlockId.LOG_BIRCH, "z": BlockId.LOG_BIRCH_Z}},
	BlockId.LOG_BIRCH_Z: {"name":"Birch Log (Z)","opaque":true, "tex_side": 58, "tex_end": 59, "orient":"z",
		"orient_variants": {"x": BlockId.LOG_BIRCH_X, "y": BlockId.LOG_BIRCH, "z": BlockId.LOG_BIRCH_Z}},
	BlockId.WOOD_BIRCH:  {"name":"Birch Planks","opaque":true, "tex_all": 60},                                   # TODO

	# --- Spruce ---
	BlockId.LOG_SPRUCE:   {"name":"Spruce Log (Y)","opaque":true, "tex_side": 42, "tex_end": 43, "orient":"y",  # TODO
		"orient_variants": {"x": BlockId.LOG_SPRUCE_X, "y": BlockId.LOG_SPRUCE, "z": BlockId.LOG_SPRUCE_Z}},
	BlockId.LOG_SPRUCE_X: {"name":"Spruce Log (X)","opaque":true, "tex_side": 42, "tex_end": 43, "orient":"x",
		"orient_variants": {"x": BlockId.LOG_SPRUCE_X, "y": BlockId.LOG_SPRUCE, "z": BlockId.LOG_SPRUCE_Z}},
	BlockId.LOG_SPRUCE_Z: {"name":"Spruce Log (Z)","opaque":true, "tex_side": 42, "tex_end": 43, "orient":"z",
		"orient_variants": {"x": BlockId.LOG_SPRUCE_X, "y": BlockId.LOG_SPRUCE, "z": BlockId.LOG_SPRUCE_Z}},
	BlockId.WOOD_SPRUCE:  {"name":"Spruce Planks","opaque":true, "tex_all": 44},                                  # TODO

	# --- Acacia ---
	BlockId.LOG_ACACIA:   {"name":"Acacia Log (Y)","opaque":true, "tex_side": 23, "tex_end": 24, "orient":"y",  # TODO
		"orient_variants": {"x": BlockId.LOG_ACACIA_X, "y": BlockId.LOG_ACACIA, "z": BlockId.LOG_ACACIA_Z}},
	BlockId.LOG_ACACIA_X: {"name":"Acacia Log (X)","opaque":true, "tex_side": 23, "tex_end": 24, "orient":"x",
		"orient_variants": {"x": BlockId.LOG_ACACIA_X, "y": BlockId.LOG_ACACIA, "z": BlockId.LOG_ACACIA_Z}},
	BlockId.LOG_ACACIA_Z: {"name":"Acacia Log (Z)","opaque":true, "tex_side": 23, "tex_end": 24, "orient":"z",
		"orient_variants": {"x": BlockId.LOG_ACACIA_X, "y": BlockId.LOG_ACACIA, "z": BlockId.LOG_ACACIA_Z}},
	BlockId.WOOD_ACACIA:  {"name":"Acacia Planks","opaque":true, "tex_all": 25},                                  # TODO

	# --- Jungle ---
	BlockId.LOG_JUNGLE:   {"name":"Jungle Log (Y)","opaque":true, "tex_side": 53, "tex_end": 54, "orient":"y",  # TODO
		"orient_variants": {"x": BlockId.LOG_JUNGLE_X, "y": BlockId.LOG_JUNGLE, "z": BlockId.LOG_JUNGLE_Z}},
	BlockId.LOG_JUNGLE_X: {"name":"Jungle Log (X)","opaque":true, "tex_side": 53, "tex_end": 54, "orient":"x",
		"orient_variants": {"x": BlockId.LOG_JUNGLE_X, "y": BlockId.LOG_JUNGLE, "z": BlockId.LOG_JUNGLE_Z}},
	BlockId.LOG_JUNGLE_Z: {"name":"Jungle Log (Z)","opaque":true, "tex_side": 53, "tex_end": 54, "orient":"z",
		"orient_variants": {"x": BlockId.LOG_JUNGLE_X, "y": BlockId.LOG_JUNGLE, "z": BlockId.LOG_JUNGLE_Z}},
	BlockId.WOOD_JUNGLE:  {"name":"Jungle Planks","opaque":true, "tex_all": 55},


	# sapling
	BlockId.SAPLING:{"name":"Sapling","opaque":false,"tex_all":120},
	
	BlockId.CHEST: {
		"name":"Chest", "opaque":false, "transparent":false,
		"entity":"Chest",                        # mark as entity (not meshed by chunks)
		"tex_top": 0, "tex_bottom": 37, "tex_side": 3    # TODO: your chest 16x16 icon in atlas
	},

}

static func entity_packed_scene(id:int) -> PackedScene:
	return ENTITY_SCENES.get(id, null)

static func is_opaque(id:int) -> bool:
	return BLOCKS.get(id, {}).get("opaque", false)

# ---- orientation helpers (shared, so other “orientable” blocks can opt-in later) ----
static func is_entity(id:int) -> bool:
	return BLOCKS.get(id, {}).has("entity")

#static func entity_scene_path(id:int) -> String:
	#return BLOCKS.get(id, {}).get("place_scene","")

static func is_transparent(id:int) -> bool:
	return BLOCKS.get(id, {}).get("transparent", false)

# if neighbor should hide this face
static func face_hidden_by_neighbor(this_id:int, neighbor_id:int) -> bool:
	# air never hides
	if neighbor_id == BlockId.AIR:
		return false

	# any opaque neighbor hides the face
	if is_opaque(neighbor_id):
		return true

	# identical transparent blocks: only hide if this block *wants* that behavior
	if this_id == neighbor_id and is_transparent(this_id):
		var cull_same = BLOCKS.get(this_id, {}).get("cull_same_transparent", true)
		return cull_same

	# different transparent neighbors: keep the face (nice for leaf/glass combos)
	return false


static func is_orientable(id:int) -> bool:
	return BLOCKS.get(id, {}).has("orient_variants")

static func _axis_from_normal(n:Vector3) -> String:
	var ax = abs(n.x); var ay = abs(n.y); var az = abs(n.z)
	if ax >= ay and ax >= az: return "x"
	if ay >= ax and ay >= az: return "y"
	return "z"

# Choose the oriented variant to place, based on the face normal you clicked.
static func orient_block_for_normal(base_id:int, face_normal:Vector3) -> int:
	var b = BLOCKS.get(base_id, null)
	if b == null: return base_id
	if b.has("orient_variants"):
		var axis := _axis_from_normal(face_normal)  # "x" | "y" | "z"
		var ov = b["orient_variants"]
		if typeof(ov) == TYPE_DICTIONARY and ov.has(axis):
			return ov[axis]
	return base_id

# face: 0=+X,1=-X,2=+Y,3=-Y,4=+Z,5=-Z
static func get_face_tile(id:int, face:int) -> int:
	var b = BLOCKS.get(id, null)
	if b == null: return 0

	# Logs: choose end vs side by axis in the block definition
	if b.has("orient") and b.has("tex_side") and b.has("tex_end"):
		var axis := String(b["orient"])
		var is_end := (
			(axis == "x" and face in [0,1]) or
			(axis == "y" and face in [2,3]) or
			(axis == "z" and face in [4,5])
		)
		return b["tex_end"] if is_end else b["tex_side"]

	# Generic: top/bottom/side handling + fallback to tex_all
	if face == 2 and b.has("tex_top"):    return b["tex_top"]
	if face == 3 and b.has("tex_bottom"): return b["tex_bottom"]
	if b.has("tex_side") and face in [0,1,4,5]: return b["tex_side"]
	return b.get("tex_all", 0)


# UVs with half-pixel padding to prevent bleeding
static func tile_uvs(tile_index:int) -> PackedVector2Array:
	var cols := _cached_cols
	var tx := tile_index % cols
	var ty := int(tile_index / cols)      # ← force integer
	var pad_px := 0.5
	var aw := _cached_atlas.x
	var ah := _cached_atlas.y
	var u0 := (tx * TILE_SIZE + pad_px) / aw
	var v0 := (ty * TILE_SIZE + pad_px) / ah
	var u1 := ((tx + 1) * TILE_SIZE - pad_px) / aw
	var v1 := ((ty + 1) * TILE_SIZE - pad_px) / ah
	return PackedVector2Array([Vector2(u0,v0), Vector2(u1,v0), Vector2(u1,v1), Vector2(u0,v1)])

# for hotbar icons
static func tile_region_rect(tile_index:int) -> Rect2:
	var tx := tile_index % _cached_cols
	var ty := int(tile_index / _cached_cols)   # ← force integer
	return Rect2(tx * TILE_SIZE, ty * TILE_SIZE, TILE_SIZE, TILE_SIZE)
