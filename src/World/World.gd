extends Node3D
class_name World

const CX := Chunk.CX
const CY := Chunk.CY
const CZ := Chunk.CZ

# How many chunks in X/Z from origin (e.g. 4 -> 9×9 chunks is big; start small)
const RADIUS := 3   # results in (2*RADIUS+1)^2 chunks

var rng := RandomNumberGenerator.new()

var noise := FastNoiseLite.new()
var atlas: Texture2D
var chunks := {}  # Dictionary<Vector3i, Chunk>

var _tick_accum := 0.0
var micro_noise := FastNoiseLite.new()

const MICRO_TERRAIN_GATE := 0.15   # noise threshold for terrain smoothing (0..1-ish noise)
const MICRO_LEAF_GATE := 0.10      # noise threshold for canopy smoothing
const MICRO_Y_UPPER := 0           # we always use the upper half step

const TREE_NOTCH_GATE := 0.25   # per-tree gate (raise for fewer decorated trees)
const CROWN_SCAN_RADIUS := 3    # how far from trunk to soften canopy edges


func _ready():
	#rng.randomize()
	atlas = load(BlockDB.ATLAS_PATH)
	BlockDB.configure_from_texture(atlas)
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_octaves = 3
	noise.frequency = 0.01

	generate_initial_area()
	BlockDB.register_notch_blocks()
	
	micro_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	micro_noise.fractal_octaves = 2
	micro_noise.frequency = 0.08     # patch size; tweak to taste
	micro_noise.seed = 1337          # or rng.randi()
	
func _process(dt: float) -> void:
	_tick_accum += dt
	if _tick_accum >= 0.5:
		_world_tick()
		_tick_accum = 0.0
		
# Treat leaves as “let light through” so grass survives under trees
func _opaque_for_light(id:int) -> bool:
	return BlockDB.is_opaque(id) and id != BlockDB.BlockId.LEAVES
	
# snap a world position to cell + sub-index (2x2x2, each 0.5)
static func _world_to_cell_and_sub(wpos: Vector3) -> Dictionary:
	var cell := Vector3i(floori(wpos.x), floori(wpos.y), floori(wpos.z))
	var local := wpos - Vector3(cell)
	# robust clamp so 1.0 lies in upper half
	var ix := int(floor(clamp(local.x, 0.0, 0.999) * 2.0))
	var iy := int(floor(clamp(local.y, 0.0, 0.999) * 2.0))
	var iz := int(floor(clamp(local.z, 0.0, 0.999) * 2.0))
	return {"cell": cell, "ix": ix, "iy": iy, "iz": iz}

# Returns the ITEM ID to drop (prefer the notch item); -1 if nothing removed.
func break_notch_at_world(wpos: Vector3) -> int:
	var info := world_to_chunk_local(wpos)
	var cpos: Vector3i = info["chunk"]
	var lpos: Vector3i = info["local"]
	if lpos.y < 0 or lpos.y >= Chunk.CY: return -1
	if not chunks.has(cpos): return -1
	var c: Chunk = chunks[cpos]

	var sub := _world_to_cell_and_sub(wpos)
	var ix := int(sub["ix"]); var iy := int(sub["iy"]); var iz := int(sub["iz"])
	var s  := Chunk._sub_index(ix, iy, iz)

	var a := c.get_micro_cell(lpos)
	if a.size() != 8: return -1
	var base_id := int(a[s])
	if base_id <= 0: return -1

	# remove the micro voxel
	c.clear_micro_sub(lpos, s)
	c.dirty = true        # <- important so rebuild doesn't early-return
	c.rebuild_mesh()

	# prefer dropping the notch item for this base block, fallback to base block
	var notch_item := BlockDB.notch_item_for_base(base_id)
	return notch_item if notch_item != -1 else base_id

func has_notch_at_world(wpos: Vector3) -> bool:
	var info := world_to_chunk_local(wpos)
	var cpos: Vector3i = info["chunk"]
	var lpos: Vector3i = info["local"]
	if lpos.y < 0 or lpos.y >= Chunk.CY: return false
	if not chunks.has(cpos): return false
	var c: Chunk = chunks[cpos]

	var sub := _world_to_cell_and_sub(wpos)
	var ix := int(sub["ix"]); var iy := int(sub["iy"]); var iz := int(sub["iz"])
	var s  := Chunk._sub_index(ix, iy, iz)

	var a := c.get_micro_cell(lpos)
	return a.size() == 8 and int(a[s]) > 0

# Returns true if the block cell at wpos contains at least one micro/notch.
func cell_has_any_notch_at_world(wpos: Vector3) -> bool:
	var info := world_to_chunk_local(wpos)
	var cpos: Vector3i = info["chunk"]
	var lpos: Vector3i = info["local"]
	if lpos.y < 0 or lpos.y >= Chunk.CY: return false
	if not chunks.has(cpos): return false
	var c: Chunk = chunks[cpos]

	var a := c.get_micro_cell(lpos)
	if a.size() != 8: 
		return false
	for v in a:
		if int(v) > 0:
			return true
	return false


func place_notch_at_world(wpos: Vector3, notch_id: int, face_normal: Vector3 = Vector3.ZERO) -> void:
	if not BlockDB.is_notch(notch_id): return
	var base_id := BlockDB.notch_base(notch_id)
	if base_id < 0: return

	var info := world_to_chunk_local(wpos)
	var cpos: Vector3i = info["chunk"]
	var lpos: Vector3i = info["local"]
	if lpos.y < 0 or lpos.y >= Chunk.CY: return
	if not chunks.has(cpos): return
	var c: Chunk = chunks[cpos]

	var sub := _world_to_cell_and_sub(wpos)
	var ix := int(sub["ix"])
	var iy := int(sub["iy"])
	var iz := int(sub["iz"])

	# force the half by the clicked face so it hugs the face
	if abs(face_normal.x) > 0.5:
		ix = 0 if face_normal.x > 0.0 else 1
	if abs(face_normal.y) > 0.5:
		iy = 0 if face_normal.y > 0.0 else 1
	if abs(face_normal.z) > 0.5:
		iz = 0 if face_normal.z > 0.0 else 1

	# only place into empty cells
	if c.get_block(lpos) != BlockDB.BlockId.AIR:
		return

	c.set_micro_sub(lpos, Chunk._sub_index(ix, iy, iz), base_id)
	c.dirty = true
	c.rebuild_mesh()


func _get_block_from_chunk(c:Chunk, p:Vector3i) -> int:
	# Local-only read; if out of bounds, pretend it's air (cheap & safe).
	# (Later we can cross-read neighbor chunks if you want perfect edge spread.)
	if Chunk.index_in_bounds(p.x, p.y, p.z):
		return c.get_block(p)
	return BlockDB.BlockId.AIR

# Any opaque block (except leaves) "covers" grass.
func _covers_grass(id:int) -> bool:
	return BlockDB.is_opaque(id) and id != BlockDB.BlockId.LEAVES

# Local read helper you already have (keep as-is)
# func _get_block_from_chunk(c:Chunk, p:Vector3i) -> int: ...

func _has_grass_neighbor(c:Chunk, p:Vector3i) -> bool:
	var dirs := [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,0,1), Vector3i(0,0,-1)]
	for d in dirs:
		if _get_block_from_chunk(c, p + d) == BlockDB.BlockId.GRASS:
			return true
	return false


func _light_hits(c:Chunk, p:Vector3i) -> bool:
	var above := p + Vector3i(0, 1, 0)
	var id_above := _get_block_from_chunk(c, above)
	return not _opaque_for_light(id_above)

func _world_tick() -> void:
	for c in chunks.values():
		# sample N random cells per chunk each tick (tune N to taste)
		for _i in 20:
			var x := rng.randi() % Chunk.CX
			var y := rng.randi() % Chunk.CY
			var z := rng.randi() % Chunk.CZ
			var p := Vector3i(x, y, z)
			var id = c.get_block(p)

			# ---- grass spread (no light system) ----
			if id == BlockDB.BlockId.DIRT:
				# becomes GRASS if next to any grass (slow, organic)
				if _has_grass_neighbor(c, p):
					# ~20% chance this tick; increase/decrease for faster/slower spread
					if rng.randi() % 5 == 0:
						c.set_block(p, BlockDB.BlockId.GRASS)
						c.dirty = true

			# ---- covered grass dies back to dirt ----
			elif id == BlockDB.BlockId.GRASS:
				var above := p + Vector3i(0, 1, 0)
				var above_id := _get_block_from_chunk(c, above)
				if _covers_grass(above_id):
					# ~16% chance this tick; raise to speed up decay
					if rng.randi() % 6 == 0:
						c.set_block(p, BlockDB.BlockId.DIRT)
						c.dirty = true

			# ---- leaves decay / sapling growth (unchanged) ----
			elif id == BlockDB.BlockId.LEAVES:
				if _no_log_nearby(c, p, 4):
					if rng.randi() % 6 == 0:
						c.set_block(p, BlockDB.BlockId.SAPLING)
					else:
						c.set_block(p, BlockDB.BlockId.AIR)
					c.dirty = true

			elif id == BlockDB.BlockId.SAPLING:
				if rng.randi() % 18 == 0:
					c.set_block(p, BlockDB.BlockId.AIR)
					_place_tree(c, p)
					c.dirty = true

func _no_log_nearby(c:Chunk, p:Vector3i, r:int) -> bool:
	for dx in range(-r, r+1):
		for dy in range(-r, r+1):
			for dz in range(-r, r+1):
				var q := p + Vector3i(dx,dy,dz)
				if Chunk.index_in_bounds(q.x,q.y,q.z) and c.get_block(q) == BlockDB.BlockId.LOG:
					return false
	return true

	
func world_to_chunk_local(wpos:Vector3) -> Dictionary:
	var cx := floori(wpos.x / CX)
	var cz := floori(wpos.z / CZ)
	var lx := int(floor(wpos.x - cx*CX))
	var ly := int(floor(wpos.y))
	var lz := int(floor(wpos.z - cz*CZ))
	return {"chunk": Vector3i(cx,0,cz), "local": Vector3i(lx,ly,lz)}

func get_block_id_at_world(wpos: Vector3) -> int:
	var info := world_to_chunk_local(wpos)
	var cpos: Vector3i = info["chunk"]
	var lpos: Vector3i = info["local"]

	if lpos.y < 0 or lpos.y >= Chunk.CY:
		return BlockDB.BlockId.AIR
	if not chunks.has(cpos):
		return BlockDB.BlockId.AIR

	var chunk: Chunk = chunks[cpos]
	if not Chunk.index_in_bounds(lpos.x, lpos.y, lpos.z):
		return BlockDB.BlockId.AIR

	return chunk.get_block(lpos)

func edit_block_at_world(wpos:Vector3, id:int):
	var info := world_to_chunk_local(wpos)
	var cpos:Vector3i = info["chunk"]
	var lpos:Vector3i = info["local"]

	if lpos.y < 0 or lpos.y >= Chunk.CY:
		return

	if not chunks.has(cpos):
		# (Optional) spawn new chunk if placing outside existing area
		return

	var chunk:Chunk = chunks[cpos]
	if not Chunk.index_in_bounds(lpos.x,lpos.y,lpos.z):
		return

	chunk.set_block(lpos, id)
	_on_block_changed_immediate(chunk, lpos, id)
	chunk.rebuild_mesh()

	# If editing on a boundary, rebuild neighbor chunk too so shared faces update:
	var touched_neighbors := []
	if lpos.x == 0: touched_neighbors.append(Vector3i(cpos.x-1,0,cpos.z))
	if lpos.x == Chunk.CX-1: touched_neighbors.append(Vector3i(cpos.x+1,0,cpos.z))
	if lpos.z == 0: touched_neighbors.append(Vector3i(cpos.x,0,cpos.z-1))
	if lpos.z == Chunk.CZ-1: touched_neighbors.append(Vector3i(cpos.x,0,cpos.z+1))
	for npos in touched_neighbors:
		if chunks.has(npos):
			chunks[npos].rebuild_mesh()

func _on_block_changed_immediate(c: Chunk, lp: Vector3i, new_id: int) -> void:
	# If we placed a covering block, the block directly below turns to DIRT immediately.
	if _covers_grass(new_id):
		var below := lp + Vector3i(0, -1, 0)
		if Chunk.index_in_bounds(below.x, below.y, below.z):
			if c.get_block(below) == BlockDB.BlockId.GRASS:
				c.set_block(below, BlockDB.BlockId.DIRT)
				c.dirty = true
	# If we removed a cap, do nothing here (let the background spread handle greening).

func generate_initial_area():
	for cz in range(-RADIUS, RADIUS+1):
		for cx in range(-RADIUS, RADIUS+1):
			var cpos := Vector3i(cx, 0, cz)
			spawn_chunk(cpos)
			var ch:Chunk = chunks[cpos]
			generate_chunk_blocks(ch)        # terrain
			_seed_micro_slopes_terrain(ch)   # ground smoothing
			#_seed_micro_slopes_leaves(ch)    # canopy smoothing
			ch.rebuild_mesh()

const MICRO_EDGE_PROB := 0.75   # 0..1; raise for more frequent steps
const MICRO_SIZE_UPPER := 1     # we always use the upper half for the step

# Put a half-height step along edges where neighboring terrain columns differ by exactly 1.
# Put a half-height step along edges where neighboring terrain columns differ by exactly 1.
# Put a half-height step along edges where neighboring terrain columns differ by exactly 1.
func _seed_micro_slopes_terrain(c:Chunk) -> void:
	var base_x:int = c.chunk_pos.x * CX
	var base_z:int = c.chunk_pos.z * CZ

	for x in range(0, CX):
		for z in range(0, CZ):
			var y0:int = _top_terrain_y(c, x, z)   # top FULL block (e.g., GRASS)
			if y0 < 0:
				continue

			var id0:int = c.get_block(Vector3i(x, y0, z))
			if not _is_terrain(id0):
				continue

			# Gate so it appears in patches; set to 0.0 temporarily if you want to verify everywhere.
			var gate_val:float = micro_noise.get_noise_2d(base_x + x, base_z + z)
			if gate_val < MICRO_TERRAIN_GATE:
				continue

			# We place micros in the AIR cell above the top block.
			var lp_above := Vector3i(x, y0 + 1, z)
			if lp_above.y >= CY: 
				continue
			if c.get_block(lp_above) != BlockDB.BlockId.AIR:
				continue

			var placed := false
			# +X higher → right edge in lower half of air cell
			if x + 1 < CX:
				var yx := _top_terrain_y(c, x + 1, z)
				if yx >= 0 and (yx - y0) == 1:
					c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 0), id0)
					c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 1), id0)
					placed = true

			# -X higher → left edge
			if x - 1 >= 0:
				var yxm1 := _top_terrain_y(c, x - 1, z)
				if yxm1 >= 0 and (yxm1 - y0) == 1:
					c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 0), id0)
					c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 1), id0)
					placed = true

			# +Z higher → front edge
			if z + 1 < CZ:
				var yz := _top_terrain_y(c, x, z + 1)
				if yz >= 0 and (yz - y0) == 1:
					c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 1), id0)
					c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 1), id0)
					placed = true

			# -Z higher → back edge
			if z - 1 >= 0:
				var yzm1 := _top_terrain_y(c, x, z - 1)
				if yzm1 >= 0 and (yzm1 - y0) == 1:
					c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 0), id0)
					c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 0), id0)
					placed = true

			if placed:
				c.dirty = true

# Smooth leaf canopy edges; write into the AIR cell above the lower leaf column.
func _seed_micro_slopes_leaves(c:Chunk) -> void:
	var base_x:int = c.chunk_pos.x * CX
	var base_z:int = c.chunk_pos.z * CZ

	for x in range(0, CX):
		for z in range(0, CZ):
			var y0 := _top_leaves_y(c, x, z)
			if y0 < 0: continue

			# separate noise field so canopy pattern differs
			var gate_val := micro_noise.get_noise_2d(base_x + x + 1000, base_z + z + 1000)
			if gate_val < MICRO_LEAF_GATE: continue

			var lp_above := Vector3i(x, y0 + 1, z)
			if lp_above.y >= CY or c.get_block(lp_above) != BlockDB.BlockId.AIR:
				continue

			# +X higher
			if x + 1 < CX:
				var yx := _top_leaves_y(c, x + 1, z)
				if yx >= 0 and (yx - y0) == 1:
					c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 0), BlockDB.BlockId.LEAVES)
					c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 1), BlockDB.BlockId.LEAVES)
					c.dirty = true

			# -X higher
			if x - 1 >= 0:
				var yxm1 := _top_leaves_y(c, x - 1, z)
				if yxm1 >= 0 and (yxm1 - y0) == 1:
					c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 0), BlockDB.BlockId.LEAVES)
					c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 1), BlockDB.BlockId.LEAVES)
					c.dirty = true

			# +Z higher
			if z + 1 < CZ:
				var yz := _top_leaves_y(c, x, z + 1)
				if yz >= 0 and (yz - y0) == 1:
					c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 1), BlockDB.BlockId.LEAVES)
					c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 1), BlockDB.BlockId.LEAVES)
					c.dirty = true

			# -Z higher
			if z - 1 >= 0:
				var yzm1 := _top_leaves_y(c, x, z - 1)
				if yzm1 >= 0 and (yzm1 - y0) == 1:
					c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 0), BlockDB.BlockId.LEAVES)
					c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 0), BlockDB.BlockId.LEAVES)
					c.dirty = true


func spawn_chunk(cpos:Vector3i):
	if chunks.has(cpos): return
	var c := Chunk.new()
	add_child(c)
	c.position = Vector3(cpos.x*CX, 0, cpos.z*CZ)
	c.setup(cpos, atlas)
	chunks[cpos] = c

func generate_chunk_blocks(c: Chunk) -> void:
	var base_x: int = c.chunk_pos.x * CX
	var base_z: int = c.chunk_pos.z * CZ

	for x in CX:
		for z in CZ:
			var wx: int = base_x + x
			var wz: int = base_z + z

			# ----- main column -----
			var h: int = int(remap(noise.get_noise_2d(wx, wz), -1.0, 1.0, 20.0, 40.0))
			h = clamp(h, 1, Chunk.CY - 1)

			for y in range(0, h):
				var id: int = BlockDB.BlockId.DIRT
				if y == h - 1:
					id = BlockDB.BlockId.GRASS
				elif y < h - 5:
					id = BlockDB.BlockId.STONE
				c.set_block(Vector3i(x, y, z), id)

			# trees (unchanged)
			if rng.randi() % 32 == 0:
				_place_tree(c, Vector3i(x, h, z))


func _smooth_with_notches(c: Chunk) -> void:
	var base_x := c.chunk_pos.x * CX
	var base_z := c.chunk_pos.z * CZ
	for x in CX:
		for z in CZ:
			# find top height here and in +X / +Z
			var h := -1
			for y in range(Chunk.CY-1, -1, -1):
				if c.get_block(Vector3i(x,y,z)) != BlockDB.BlockId.AIR:
					h = y; break
			if h < 0: continue

			# compare to +X
			if x+1 < CX:
				var hx := -1
				for y in range(Chunk.CY-1, -1, -1):
					if c.get_block(Vector3i(x+1,y,z)) != BlockDB.BlockId.AIR:
						hx = y; break
				if hx == h+1:
					# place a 0.5 step in this (lower) cell on the +X edge at top
					var lp := Vector3i(x, h, z)
					# two micro cubes covering the +X edge, upper half layer
					c.set_micro_sub(lp, Chunk._sub_index(1,1,0), BlockDB.BlockId.DIRT)
					c.set_micro_sub(lp, Chunk._sub_index(1,1,1), BlockDB.BlockId.DIRT)

			# compare to +Z
			if z+1 < CZ:
				var hz := -1
				for y in range(Chunk.CY-1, -1, -1):
					if c.get_block(Vector3i(x,y,z+1)) != BlockDB.BlockId.AIR:
						hz = y; break
				if hz == h+1:
					var lp := Vector3i(x, h, z)
					# two micro cubes covering the +Z edge, upper half layer
					c.set_micro_sub(lp, Chunk._sub_index(0,1,1), BlockDB.BlockId.DIRT)
					c.set_micro_sub(lp, Chunk._sub_index(1,1,1), BlockDB.BlockId.DIRT)

	c.rebuild_mesh()


# --- classify blocks for smoothing ---
const LOG_IDS: Array[int] = [
	BlockDB.BlockId.LOG, BlockDB.BlockId.LOG_X, BlockDB.BlockId.LOG_Z,
	BlockDB.BlockId.LOG_BIRCH,  BlockDB.BlockId.LOG_BIRCH_X,  BlockDB.BlockId.LOG_BIRCH_Z,
	BlockDB.BlockId.LOG_SPRUCE, BlockDB.BlockId.LOG_SPRUCE_X, BlockDB.BlockId.LOG_SPRUCE_Z,
	BlockDB.BlockId.LOG_ACACIA, BlockDB.BlockId.LOG_ACACIA_X, BlockDB.BlockId.LOG_ACACIA_Z,
	BlockDB.BlockId.LOG_JUNGLE, BlockDB.BlockId.LOG_JUNGLE_X, BlockDB.BlockId.LOG_JUNGLE_Z
]

func _is_treeish(id:int) -> bool:
	if id == BlockDB.BlockId.LEAVES: return true
	if id == BlockDB.BlockId.SAPLING: return true
	return id in LOG_IDS

func _is_terrain(id:int) -> bool:
	if id == BlockDB.BlockId.GRASS: return true
	if id == BlockDB.BlockId.DIRT: return true
	if id == BlockDB.BlockId.STONE: return true
	if id == BlockDB.BlockId.SAND: return true
	if id == BlockDB.BlockId.CLAY_TILE: return true
	if id == BlockDB.BlockId.COBBLE: return true
	if id == BlockDB.BlockId.STONE_BRICKS: return true
	if id == BlockDB.BlockId.MOSSY_STONE_BRICKS: return true
	return false

# Highest y that is "terrain" (skips air + all treeish). -1 if none.
func _top_terrain_y(c:Chunk, x:int, z:int) -> int:
	for y in range(Chunk.CY - 1, -1, -1):
		var id:int = c.get_block(Vector3i(x, y, z))
		if id == BlockDB.BlockId.AIR: continue
		if _is_treeish(id): continue
		if _is_terrain(id): return y
	return -1

# Highest y that is a LEAVES block. -1 if none.
func _top_leaves_y(c:Chunk, x:int, z:int) -> int:
	for y in range(Chunk.CY - 1, -1, -1):
		var id:int = c.get_block(Vector3i(x, y, z))
		if id == BlockDB.BlockId.LEAVES:
			return y
	return -1


func _place_tree(c:Chunk, at:Vector3i) -> void:
	# Require GRASS beneath
	if at.y <= 0 or c.get_block(at - Vector3i(0,1,0)) != BlockDB.BlockId.GRASS:
		return

	var height := 4 + int(rng.randi() % 3)  # 4..6

	# Trunk
	for i in height:
		var p := at + Vector3i(0, i, 0)
		if p.y >= Chunk.CY: break
		if Chunk.index_in_bounds(p.x,p.y,p.z):
			c.set_block(p, BlockDB.BlockId.LOG)

	# Leaf blob (simple rounded cube near top)
	var top := at + Vector3i(0, height, 0)
	for dx in range(-2, 3):
		for dy in range(-2, 2):
			for dz in range(-2, 3):
				var off := Vector3i(dx, dy, dz)
				var dist := Vector3(abs(dx), abs(dy)*1.3, abs(dz)).length()
				if dist <= 2.6 and rng.randi() % 6 != 0:
					var p := top + off
					if Chunk.index_in_bounds(p.x,p.y,p.z) and c.get_block(p) == BlockDB.BlockId.AIR:
						c.set_block(p, BlockDB.BlockId.LEAVES)

	c.dirty = true
	_decorate_tree_with_notches(c, at, height)

# Put two 0.5-high micros in the neighbor cell that touches 'toward_trunk'.
# iy = 0 (lower half). Chooses the two halves along the axis perpendicular to the edge.
func _place_edge_half_pair(c:Chunk, cell:Vector3i, toward_trunk:Vector3i, base_id:int) -> void:
	if not Chunk.index_in_bounds(cell.x, cell.y, cell.z): return
	if c.get_block(cell) != BlockDB.BlockId.AIR: return

	if toward_trunk.x == 1:               # trunk is to -X of this cell
		c.set_micro_sub(cell, Chunk._sub_index(0, 0, 0), base_id)
		c.set_micro_sub(cell, Chunk._sub_index(0, 0, 1), base_id)
	elif toward_trunk.x == -1:            # trunk is to +X
		c.set_micro_sub(cell, Chunk._sub_index(1, 0, 0), base_id)
		c.set_micro_sub(cell, Chunk._sub_index(1, 0, 1), base_id)
	elif toward_trunk.z == 1:             # trunk is to -Z
		c.set_micro_sub(cell, Chunk._sub_index(0, 0, 0), base_id)
		c.set_micro_sub(cell, Chunk._sub_index(1, 0, 0), base_id)
	elif toward_trunk.z == -1:            # trunk is to +Z
		c.set_micro_sub(cell, Chunk._sub_index(0, 0, 1), base_id)
		c.set_micro_sub(cell, Chunk._sub_index(1, 0, 1), base_id)

# A tiny ring of micros around the trunk, in neighbor AIR cells at y, using base_id.
func _ring_around_trunk(c:Chunk, trunk_xy:Vector3i, y:int, base_id:int) -> bool:
	var placed := false
	var dirs := [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,0,1), Vector3i(0,0,-1)]
	for d in dirs:
		var ncell := Vector3i(trunk_xy.x + d.x, y, trunk_xy.z + d.z)
		if Chunk.index_in_bounds(ncell.x, ncell.y, ncell.z) and c.get_block(ncell) == BlockDB.BlockId.AIR:
			_place_edge_half_pair(c, ncell, d, base_id)
			placed = true
	return placed

# Soften canopy edges near the tree: for each LEAVES cell, if the neighbor at the same y is AIR,
# lay a 0.5-high LEAVES “skirt” into that neighbor cell (lower half).
func _soften_canopy_near_trunk(c:Chunk, trunk:Vector3i, y_top:int, radius:int) -> bool:
	var placed := false
	for dx in range(-radius, radius+1):
		for dz in range(-radius, radius+1):
			for dy in range(0, 3):  # just a few layers near the crown
				var p := Vector3i(trunk.x + dx, y_top + dy, trunk.z + dz)
				if not Chunk.index_in_bounds(p.x, p.y, p.z): continue
				if c.get_block(p) != BlockDB.BlockId.LEAVES: continue

				# check 4 horizontal neighbors at the same level
				var dirs := [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,0,1), Vector3i(0,0,-1)]
				for d in dirs:
					var n = p + d
					if not Chunk.index_in_bounds(n.x, n.y, n.z): continue
					# only if the outside neighbor is AIR and the *next* cell further out isn't another leaf
					if c.get_block(n) == BlockDB.BlockId.AIR:
						var n2 = n + d
						if not Chunk.index_in_bounds(n2.x, n2.y, n2.z) or c.get_block(n2) != BlockDB.BlockId.LEAVES:
							_place_edge_half_pair(c, n, d, BlockDB.BlockId.LEAVES)
							placed = true
	return placed

# Main per-tree decorator (noise-gated)
func _decorate_tree_with_notches(c:Chunk, at:Vector3i, height:int) -> void:
	# Per-tree gate so only some trees get rounded
	var wx := c.chunk_pos.x * CX + at.x
	var wz := c.chunk_pos.z * CZ + at.z
	var gate := micro_noise.get_noise_2d(wx, wz)
	if gate < TREE_NOTCH_GATE:
		return

	var changed := false
	var trunk_xy := Vector3i(at.x, 0, at.z)

	# 1) Root flare: ring of LOG micros just above ground around the trunk
	changed = _ring_around_trunk(c, trunk_xy, at.y, BlockDB.BlockId.LOG) or changed

	# 2) Crown collar: ring of LEAVES micros where the trunk meets the leaves
	var y_top := at.y + height
	changed = _ring_around_trunk(c, trunk_xy, y_top, BlockDB.BlockId.LEAVES) or changed

	# 3) Canopy skirt: soften local canopy edges near the trunk
	changed = _soften_canopy_near_trunk(c, at, y_top, CROWN_SCAN_RADIUS) or changed

	if changed:
		c.dirty = true


func place_entity_at_world(wpos: Vector3, id: int) -> void:
	var ps: PackedScene = BlockDB.entity_packed_scene(id)
	if ps == null:
		push_warning("place_entity_at_world: no PackedScene for id %d" % id)
		return

	var node: Node3D = ps.instantiate() as Node3D
	add_child(node)

	# snap to cell center
	var gx: float = float(floori(wpos.x)) + 0.5
	var gy: float = float(floori(wpos.y)) + 0.0
	var gz: float = float(floori(wpos.z)) + 0.5
	node.global_position = Vector3(gx, gy, gz)


# Add this new function (do not remove your existing place_entity_at_world if others use it).

func place_entity_at_world_oriented(
		wpos: Vector3,
		id: int,
		face_normal: Vector3,
		player_world_pos: Vector3,
		player_forward: Vector3
	) -> void:
	var ps: PackedScene = BlockDB.entity_packed_scene(id)
	if ps == null:
		push_warning("place_entity_at_world_oriented: no PackedScene for id %d" % id)
		return

	var node: Node3D = ps.instantiate() as Node3D
	add_child(node)

	# snap to cell center (upright)
	var gx: float = float(floori(wpos.x)) + 0.5
	var gy: float = float(floori(wpos.y)) + 0.0
	var gz: float = float(floori(wpos.z)) + 0.5
	node.global_position = Vector3(gx, gy, gz)
	node.rotation = Vector3(0.0, 0.0, 0.0)  # ensure upright

	# Decide the desired forward on XZ
	var n: Vector3 = face_normal
	var f: Vector3 = Vector3.ZERO

	# Wall: face outward from the wall (along the clicked face normal)
	if abs(n.y) < 0.5:
		f = Vector3(n.x, 0.0, n.z).normalized()
	else:
		# Floor / ceiling: face the player
		f = player_world_pos - node.global_position
		f.y = 0.0
		if f.length() < 0.001:
			# Fallback: use player's forward projected to XZ
			f = Vector3(player_forward.x, 0.0, player_forward.z)

	if f.length() < 0.001:
		return  # nothing to do

	# Convert forward vector to yaw. Godot's "front" is -Z, so rotate -Z to 'f'.
	var yaw: float = atan2(f.x, f.z) + PI  # aligns -Z with 'f'

	# Snap to 90-degree steps (NESW)
	var step: float = PI * 0.5
	yaw = round(yaw / step) * step

	# Optional per-entity adjustment if model front isn't -Z
	var extra_deg: float = BlockDB.entity_facing_yaw_deg(id)
	yaw += deg_to_rad(extra_deg)

	node.rotation = Vector3(0.0, yaw, 0.0)
