extends Node3D
class_name World

const CX := Chunk.CX
const CY := Chunk.CY
const CZ := Chunk.CZ

# ---- Player-centered streaming ----
const RENDER_RADIUS := 5        # in chunks (5 => 11x11)
const TICK_SECONDS := 0.5

const PRELOAD_RADIUS := RENDER_RADIUS + 1   # one ring ahead for prewarm
const BUILD_BUDGET_PER_FRAME := 2           # rebuild at most N chunks per frame

# ---- Micro smoothing thresholds ----
const MICRO_TERRAIN_GATE := 0.15
const MICRO_LEAF_GATE := 0.10
const MICRO_Y_UPPER := 0

const TREE_NOTCH_GATE := 0.25
const CROWN_SCAN_RADIUS := 3

# ---- Data ----
var atlas: Texture2D
var chunks := {}                              # Dictionary<Vector3i, Chunk]
var _tick_accum := 0.0
var _tick_phase := 0

const COLLISION_RADIUS: int = 2						# chunks near player that get colliders
const TICK_CHUNK_RADIUS: int = 3					# chunks near player that tick simulation
const SPAWN_BUDGET_PER_FRAME: int = 2				# spawn at most N new chunk nodes / frame
const GEN_BUDGET_PER_FRAME: int = 2					# generate block data for at most N chunks / frame
# BUILD_BUDGET_PER_FRAME already exists and caps mesh builds per frame (keep it)
const CHUNK_POOL_SIZE: int = 64						# simple pool upper bound


# ---- Noises (deterministic) ----
var height_noise := FastNoiseLite.new()       # terrain height
var tree_noise   := FastNoiseLite.new()       # tree presence/height
var leaf_noise   := FastNoiseLite.new()       # crown jitter
var micro_noise  := FastNoiseLite.new()       # micro smoothing (terrain & canopy)
var tick_noise   := FastNoiseLite.new()       # replaces RNG in world ticks

# ---- Player reference ----
@export var player_path: NodePath
var _player: Node3D

# [QUEUES]
var _rebuild_queue: Array = []   # Array<Chunk>

var _spawn_queue: Array[Vector3i] = []				# positions to spawn
var _gen_queue: Array[Chunk] = []					# chunks needing block generation

var _chunk_pool: Array[Chunk] = []					# recycled chunks


# =========================================================
# Lifecycle
# =========================================================
func _ready() -> void:
	atlas = load(BlockDB.ATLAS_PATH)
	BlockDB.configure_from_texture(atlas)

	# Terrain
	height_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	height_noise.fractal_octaves = 3
	height_noise.frequency = 0.01
	height_noise.seed = 1337

	# Trees
	tree_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	tree_noise.fractal_octaves = 3
	tree_noise.frequency = 0.03
	tree_noise.seed = 42

	# Leaves
	leaf_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	leaf_noise.fractal_octaves = 2
	leaf_noise.frequency = 0.15
	leaf_noise.seed = 777

	# Micro smoothing
	micro_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	micro_noise.fractal_octaves = 2
	micro_noise.frequency = 0.08
	micro_noise.seed = 1337

	# Tick “randomness”
	tick_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	tick_noise.fractal_octaves = 1
	tick_noise.frequency = 0.25
	tick_noise.seed = 9001

	# Player
	if player_path != NodePath():
		_player = get_node_or_null(player_path)
	if _player == null:
		_player = get_tree().get_root().find_child("Player", true, false) as Node3D

	# Initial area around player
	_update_chunks_around_player(true)
	BlockDB.register_notch_blocks()


func _process(dt: float) -> void:
	if _player == null:
		return

	_tick_accum += dt
	if _tick_accum >= TICK_SECONDS:
		_world_tick()
		_tick_accum = 0.0
		_tick_phase += 1

	_update_chunks_around_player()
	_drain_spawn_queue(SPAWN_BUDGET_PER_FRAME)
	_drain_gen_queue(GEN_BUDGET_PER_FRAME)
	_drain_rebuild_queue(BUILD_BUDGET_PER_FRAME)

# =========================================================
# Streaming chunks around player
# =========================================================
func _player_chunk() -> Vector3i:
	var p := _player.global_position
	return Vector3i(floori(p.x / CX), 0, floori(p.z / CZ))

func _update_chunks_around_player(force_full: bool=false) -> void:
	var center: Vector3i = _player_chunk()
	var wanted: Dictionary = {}

	# Collect desired set (render + one warm ring)
	for dz in range(-PRELOAD_RADIUS, PRELOAD_RADIUS + 1):
		for dx in range(-PRELOAD_RADIUS, PRELOAD_RADIUS + 1):
			var cpos: Vector3i = Vector3i(center.x + dx, 0, center.z + dz)
			wanted[cpos] = true
			if not chunks.has(cpos):
				# Queue spawn; heavy work will be budgeted later
				if not _spawn_queue.has(cpos):
					_spawn_queue.append(cpos)

	# Despawn those too far
	var to_remove: Array[Vector3i] = []
	for cpos_key in chunks.keys():
		var cpos_rm: Vector3i = cpos_key
		if not wanted.has(cpos_rm):
			to_remove.append(cpos_rm)
	for cpos_rm in to_remove:
		despawn_chunk(cpos_rm)

	# Maintain collision ring every update
	_set_collision_rings(center)

	# On warm start, prime rebuilds but via budgeted queues
	if force_full:
		for cpos_key in chunks.keys():
			var ch_full: Chunk = chunks[cpos_key]
			_queue_rebuild(ch_full)

func _set_collision_rings(center: Vector3i) -> void:
	for c in chunks.values():
		var dx: int = abs(c.chunk_pos.x - center.x)
		var dz: int = abs(c.chunk_pos.z - center.z)
		var near: bool = dx <= COLLISION_RADIUS and dz <= COLLISION_RADIUS
		c.wants_collision = near


func _drain_spawn_queue(max_count: int) -> void:
	if _spawn_queue.size() == 0:
		return
	# Nearest-first
	var p: Vector3 = _player.global_position
	_spawn_queue.sort_custom(func(a, b):
		var ap: Vector3 = Vector3(a.x * CX, 0.0, a.z * CZ)
		var bp: Vector3 = Vector3(b.x * CX, 0.0, b.z * CZ)
		return ap.distance_squared_to(p) < bp.distance_squared_to(p)
	)
	var n: int = min(max_count, _spawn_queue.size())
	for i in n:
		var cpos: Vector3i = _spawn_queue.pop_front()
		if chunks.has(cpos):
			continue
		# Spawn node only (cheap)
		var c: Chunk = _obtain_chunk()
		c.position = Vector3(cpos.x * CX, 0.0, cpos.z * CZ)
		c.reuse_setup(cpos, atlas)
		chunks[cpos] = c
		# Generation will be budgeted separately
		_gen_queue.append(c)

func _drain_gen_queue(max_count: int) -> void:
	if _gen_queue.size() == 0:
		return
	# Nearest-first
	var p: Vector3 = _player.global_position
	_gen_queue.sort_custom(func(a, b):
		var ap: Vector3 = a.position
		var bp: Vector3 = b.position
		return ap.distance_squared_to(p) < bp.distance_squared_to(p)
	)
	var n: int = min(max_count, _gen_queue.size())
	for i in n:
		var c: Chunk = _gen_queue.pop_front()
		if c == null:
			continue
		if not is_instance_valid(c):
			continue
		if c.pending_kill:
			continue
		# Do deterministic gen now; heavy mesh build will be queued
		generate_chunk_blocks(c)
		_seed_micro_slopes_terrain(c)
		# _seed_micro_slopes_leaves(c) # optional
		_queue_rebuild(c)

func spawn_chunk(cpos: Vector3i) -> void:
	# Kept for compatibility if you still call it anywhere
	if chunks.has(cpos):
		return
	if not _spawn_queue.has(cpos):
		_spawn_queue.append(cpos)

func despawn_chunk(cpos: Vector3i) -> void:
	if not chunks.has(cpos):
		return
	var c: Chunk = chunks[cpos]
	chunks.erase(cpos)

	if c != null and is_instance_valid(c):
		c.pending_kill = true
		_remove_from_queues_by_chunk(c)
		_return_chunk_to_pool(c)

func _obtain_chunk() -> Chunk:
	var c: Chunk
	if _chunk_pool.size() > 0:
		c = _chunk_pool.pop_back()
		if c != null and is_instance_valid(c):
			c.pending_kill = false
			c.set_active(true)
			return c
	c = Chunk.new()
	add_child(c)
	return c

func _return_chunk_to_pool(c: Chunk) -> void:
	if c == null:
		return
	if not is_instance_valid(c):
		return
	c.prepare_for_pool()
	c.set_active(false)
	if _chunk_pool.size() < CHUNK_POOL_SIZE:
		_chunk_pool.append(c)
	else:
		c.queue_free()

func _remove_from_queues_by_chunk(c: Chunk) -> void:
	# Remove any references to a chunk that is being despawned
	var new_rebuild: Array = []
	for i in _rebuild_queue.size():
		var r: Chunk = _rebuild_queue[i]
		if r != c:
			new_rebuild.append(r)
	_rebuild_queue = new_rebuild

	var new_gen: Array[Chunk] = []
	for g in _gen_queue:
		if g != c:
			new_gen.append(g)
	_gen_queue = new_gen


# =========================================================
# Deterministic helpers / noise utils
# =========================================================
func _queue_rebuild(c: Chunk) -> void:
	if c == null: return
	if not is_instance_valid(c): return
	if not _rebuild_queue.has(c):
		_rebuild_queue.append(c)

func _drain_rebuild_queue(max_count: int) -> void:
	if _rebuild_queue.size() == 0:
		return
	var p: Vector3 = _player.global_position
	_rebuild_queue.sort_custom(func(a, b):
		var ap: Vector3 = a.position
		var bp: Vector3 = b.position
		return ap.distance_squared_to(p) < bp.distance_squared_to(p)
	)
	var n: int = min(max_count, _rebuild_queue.size())
	for i in n:
		var c: Chunk = _rebuild_queue.pop_front()
		if c == null:
			continue
		if not is_instance_valid(c):
			continue
		if c.pending_kill:
			continue
		if c.dirty:
			c.rebuild_mesh()

static func _n01(x: float) -> float:
	return 0.5 * (x + 1.0)

func _n2d01(noise: FastNoiseLite, wx: int, wz: int, salt: Vector2i = Vector2i(0, 0)) -> float:
	return _n01(noise.get_noise_2d(wx + salt.x, wz + salt.y))

func _tick_chance01(wx:int, y:int, wz:int, phase:int, salt:int=0) -> float:
	const PX := 1610612741
	const PY := 805306457
	const PZ := 402653189
	return _n01(tick_noise.get_noise_3d(
		float(wx + phase * PX),
		float(y  + salt  * PY),
		float(wz + phase * PZ)
	))


# =========================================================
# World queries & coordinate helpers
# =========================================================
func world_to_chunk_local(wpos: Vector3) -> Dictionary:
	var cx := floori(wpos.x / CX)
	var cz := floori(wpos.z / CZ)
	var lx := int(floor(wpos.x - cx * CX))
	var ly := int(floor(wpos.y))
	var lz := int(floor(wpos.z - cz * CZ))
	return {"chunk": Vector3i(cx, 0, cz), "local": Vector3i(lx, ly, lz)}

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

func edit_block_at_world(wpos: Vector3, id: int) -> void:
	var info: Dictionary = world_to_chunk_local(wpos)
	var cpos: Vector3i = info["chunk"]
	var lpos: Vector3i = info["local"]

	if lpos.y < 0 or lpos.y >= Chunk.CY:
		return
	if not chunks.has(cpos):
		return

	var chunk: Chunk = chunks[cpos]
	if chunk == null:
		return
	if not is_instance_valid(chunk):
		return
	if chunk.pending_kill:
		return

	if not Chunk.index_in_bounds(lpos.x, lpos.y, lpos.z):
		return

	chunk.set_block(lpos, id)
	_on_block_changed_immediate(chunk, lpos, id)
	chunk.mark_section_dirty_for_local_y(lpos.y)
	chunk.update_heightmap_column(lpos.x, lpos.z)

	_queue_rebuild(chunk)

	# Rebuild neighbors at borders (budgeted)
	var touched_neighbors: Array[Vector3i] = []
	if lpos.x == 0: touched_neighbors.append(Vector3i(cpos.x - 1, 0, cpos.z))
	if lpos.x == Chunk.CX - 1: touched_neighbors.append(Vector3i(cpos.x + 1, 0, cpos.z))
	if lpos.z == 0: touched_neighbors.append(Vector3i(cpos.x, 0, cpos.z - 1))
	if lpos.z == Chunk.CZ - 1: touched_neighbors.append(Vector3i(cpos.x, 0, cpos.z + 1))
	for npos in touched_neighbors:
		if chunks.has(npos):
			var n: Chunk = chunks[npos]
			if n != null and is_instance_valid(n) and not n.pending_kill:
				_queue_rebuild(n)

# Treat leaves as “let light through” so grass survives under trees
func _opaque_for_light(id:int) -> bool:
	return BlockDB.is_opaque(id) and id != BlockDB.BlockId.LEAVES

func _get_block_from_chunk(c:Chunk, p:Vector3i) -> int:
	if Chunk.index_in_bounds(p.x, p.y, p.z):
		return c.get_block(p)
	return BlockDB.BlockId.AIR

func _covers_grass(id:int) -> bool:
	return BlockDB.is_opaque(id) and id != BlockDB.BlockId.LEAVES

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


# =========================================================
# Deterministic generation
# =========================================================
func generate_chunk_blocks(c: Chunk) -> void:
	var base_x: int = c.chunk_pos.x * CX
	var base_z: int = c.chunk_pos.z * CZ

	for x in CX:
		for z in CZ:
			var wx: int = base_x + x
			var wz: int = base_z + z

			var h_f: float = remap(height_noise.get_noise_2d(wx, wz), -1.0, 1.0, 20.0, 40.0)
			var h: int = clamp(int(round(h_f)), 1, Chunk.CY - 2)

			for y in range(0, h):
				var id: int = BlockDB.BlockId.DIRT
				if y == h - 1:
					id = BlockDB.BlockId.GRASS
				elif y < h - 5:
					id = BlockDB.BlockId.STONE
				c.set_block(Vector3i(x, y, z), id)

			# Trees...
			var place_val: float = _n2d01(tree_noise, wx, wz)
			if place_val > 0.80:
				var hval: float = _n2d01(tree_noise, wx + 12345, wz - 54321)
				var t_height: int = 4 + int(round(hval * 2.0))
				_place_tree_deterministic(c, Vector3i(x, h, z), t_height, wx, wz)

			# Update cached top solid per (x,z)
			#c.heightmap_set_top(x, z, h - 1)



func _place_tree(c:Chunk, at:Vector3i) -> void:
	var world_x := c.chunk_pos.x * CX + at.x
	var world_z := c.chunk_pos.z * CZ + at.z
	var hval := _n2d01(tree_noise, world_x + 12345, world_z - 54321)
	var height := 4 + int(round(hval * 2.0))  # 4..6
	_place_tree_deterministic(c, at, height, world_x, world_z)

func _place_tree_deterministic(c:Chunk, at:Vector3i, height:int, wx:int, wz:int) -> void:
	# Require GRASS beneath
	if at.y <= 0 or c.get_block(at - Vector3i(0,1,0)) != BlockDB.BlockId.GRASS:
		return

	# Trunk
	for i in height:
		var p := at + Vector3i(0, i, 0)
		if p.y >= Chunk.CY: break
		if Chunk.index_in_bounds(p.x, p.y, p.z):
			c.set_block(p, BlockDB.BlockId.LOG)

	# Leaf blob (deterministic jitter)
	var top := at + Vector3i(0, height, 0)
	for dx in range(-2, 3):
		for dy in range(-2, 2):
			for dz in range(-2, 3):
				var off := Vector3i(dx, dy, dz)
				var dist := Vector3(abs(dx), abs(dy) * 1.3, abs(dz)).length()
				if dist <= 2.6:
					var keep_val := _n01(leaf_noise.get_noise_3d(
						float(wx + dx * 97), float(top.y + dy * 57), float(wz + dz * 131)))
					if keep_val > 0.15:
						var p := top + off
						if Chunk.index_in_bounds(p.x, p.y, p.z) and c.get_block(p) == BlockDB.BlockId.AIR:
							c.set_block(p, BlockDB.BlockId.LEAVES)

	c.dirty = true
	_decorate_tree_with_notches(c, at, height)


# =========================================================
# Micro smoothing (terrain/canopy) — unchanged logic, deterministic gates
# =========================================================
func _seed_micro_slopes_terrain(c:Chunk) -> void:
	var base_x:int = c.chunk_pos.x * CX
	var base_z:int = c.chunk_pos.z * CZ

	for x in CX:
		for z in CZ:
			var y0:int = _top_terrain_y(c, x, z)
			if y0 < 0: continue

			var id0:int = c.get_block(Vector3i(x, y0, z))
			if not _is_terrain(id0): continue

			var gate_val:float = micro_noise.get_noise_2d(base_x + x, base_z + z)
			if gate_val < MICRO_TERRAIN_GATE: continue

			var lp_above := Vector3i(x, y0 + 1, z)
			if lp_above.y >= CY: continue
			if c.get_block(lp_above) != BlockDB.BlockId.AIR: continue

			var placed := false
			# +X higher
			if x + 1 < CX:
				var yx := _top_terrain_y(c, x + 1, z)
				if yx >= 0 and (yx - y0) == 1:
					c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 0), id0)
					c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 1), id0)
					placed = true
			# -X higher
			if x - 1 >= 0:
				var yxm1 := _top_terrain_y(c, x - 1, z)
				if yxm1 >= 0 and (yxm1 - y0) == 1:
					c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 0), id0)
					c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 1), id0)
					placed = true
			# +Z higher
			if z + 1 < CZ:
				var yz := _top_terrain_y(c, x, z + 1)
				if yz >= 0 and (yz - y0) == 1:
					c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 1), id0)
					c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 1), id0)
					placed = true
			# -Z higher
			if z - 1 >= 0:
				var yzm1 := _top_terrain_y(c, x, z - 1)
				if yzm1 >= 0 and (yzm1 - y0) == 1:
					c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 0), id0)
					c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 0), id0)
					placed = true

			if placed: c.dirty = true


func _seed_micro_slopes_leaves(c:Chunk) -> void:
	var base_x:int = c.chunk_pos.x * CX
	var base_z:int = c.chunk_pos.z * CZ

	for x in CX:
		for z in CZ:
			var y0 := _top_leaves_y(c, x, z)
			if y0 < 0: continue

			var gate_val := micro_noise.get_noise_2d(base_x + x + 1000, base_z + z + 1000)
			if gate_val < MICRO_LEAF_GATE: continue

			var lp_above := Vector3i(x, y0 + 1, z)
			if lp_above.y >= CY or c.get_block(lp_above) != BlockDB.BlockId.AIR: continue

			if x + 1 < CX:
				var yx := _top_leaves_y(c, x + 1, z)
				if yx >= 0 and (yx - y0) == 1:
					c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 0), BlockDB.BlockId.LEAVES)
					c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 1), BlockDB.BlockId.LEAVES)
					c.dirty = true
			if x - 1 >= 0:
				var yxm1 := _top_leaves_y(c, x - 1, z)
				if yxm1 >= 0 and (yxm1 - y0) == 1:
					c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 0), BlockDB.BlockId.LEAVES)
					c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 1), BlockDB.BlockId.LEAVES)
					c.dirty = true
			if z + 1 < CZ:
				var yz := _top_leaves_y(c, x, z + 1)
				if yz >= 0 and (yz - y0) == 1:
					c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 1), BlockDB.BlockId.LEAVES)
					c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 1), BlockDB.BlockId.LEAVES)
					c.dirty = true
			if z - 1 >= 0:
				var yzm1 := _top_leaves_y(c, x, z - 1)
				if yzm1 >= 0 and (yzm1 - y0) == 1:
					c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 0), BlockDB.BlockId.LEAVES)
					c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 0), BlockDB.BlockId.LEAVES)
					c.dirty = true


# =========================================================
# “Ticks” — now noise-driven (deterministic)
# =========================================================
func _world_tick() -> void:
	var center: Vector3i = _player_chunk()
	for c in chunks.values():
		# Skip far chunks entirely (no sim)
		var dx: int = abs(c.chunk_pos.x - center.x)
		var dz: int = abs(c.chunk_pos.z - center.z)
		if dx > TICK_CHUNK_RADIUS or dz > TICK_CHUNK_RADIUS:
			continue

		var base_x: int = c.chunk_pos.x * CX
		var base_z: int = c.chunk_pos.z * CZ
		var samples: int = 20

		for i in samples:
			var x: int = int((i * 7 + _tick_phase * 13) % Chunk.CX)
			var y: int = int((i * 11 + _tick_phase * 5) % Chunk.CY)
			var z: int = int((i * 3 + _tick_phase * 17) % Chunk.CZ)
			var p: Vector3i = Vector3i(x, y, z)
			var id: int = c.get_block(p)

			var wx: int = base_x + p.x
			var wz: int = base_z + p.z

			# Grass spread (~20%)
			if id == BlockDB.BlockId.DIRT:
				if _has_grass_neighbor(c, p):
					var chance := _tick_chance01(wx, p.y, wz, _tick_phase, 101)
					if chance > 0.80:
						c.set_block(p, BlockDB.BlockId.GRASS)
						c.dirty = true

			# Covered grass decays (~16%)
			elif id == BlockDB.BlockId.GRASS:
				var above := p + Vector3i(0, 1, 0)
				var above_id := _get_block_from_chunk(c, above)
				if _covers_grass(above_id):
					var chance := _tick_chance01(wx, p.y, wz, _tick_phase, 202)
					if chance > 0.84:
						c.set_block(p, BlockDB.BlockId.DIRT)
						c.dirty = true

			# Leaves decay / sapling
			elif id == BlockDB.BlockId.LEAVES:
				if _no_log_nearby(c, p, 4):
					var chance := _tick_chance01(wx, p.y, wz, _tick_phase, 303)
					if chance > 0.83:
						c.set_block(p, BlockDB.BlockId.SAPLING)
					else:
						c.set_block(p, BlockDB.BlockId.AIR)
					c.dirty = true

			# Sapling -> tree (~6%)
			elif id == BlockDB.BlockId.SAPLING:
				var chance := _tick_chance01(wx, p.y, wz, _tick_phase, 404)
				if chance > 0.94:
					c.set_block(p, BlockDB.BlockId.AIR)
					var hval := _n2d01(tree_noise, wx + 12345, wz - 54321)
					var t_height := 4 + int(round(hval * 2.0))
					_place_tree_deterministic(c, p, t_height, wx, wz)
					c.dirty = true


# =========================================================
# Tree helpers & classifiers (unchanged from your logic)
# =========================================================
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

func _top_terrain_y(c:Chunk, x:int, z:int) -> int:
	for y in range(Chunk.CY - 1, -1, -1):
		var id:int = c.get_block(Vector3i(x, y, z))
		if id == BlockDB.BlockId.AIR: continue
		if _is_treeish(id): continue
		if _is_terrain(id): return y
	return -1

func _top_leaves_y(c:Chunk, x:int, z:int) -> int:
	for y in range(Chunk.CY - 1, -1, -1):
		var id:int = c.get_block(Vector3i(x, y, z))
		if id == BlockDB.BlockId.LEAVES:
			return y
	return -1


# =========================================================
# Tree decoration with notches (your existing helpers)
# =========================================================
func _place_edge_half_pair(c:Chunk, cell:Vector3i, toward_trunk:Vector3i, base_id:int) -> void:
	if not Chunk.index_in_bounds(cell.x, cell.y, cell.z): return
	if c.get_block(cell) != BlockDB.BlockId.AIR: return

	if toward_trunk.x == 1:
		c.set_micro_sub(cell, Chunk._sub_index(0, 0, 0), base_id)
		c.set_micro_sub(cell, Chunk._sub_index(0, 0, 1), base_id)
	elif toward_trunk.x == -1:
		c.set_micro_sub(cell, Chunk._sub_index(1, 0, 0), base_id)
		c.set_micro_sub(cell, Chunk._sub_index(1, 0, 1), base_id)
	elif toward_trunk.z == 1:
		c.set_micro_sub(cell, Chunk._sub_index(0, 0, 0), base_id)
		c.set_micro_sub(cell, Chunk._sub_index(1, 0, 0), base_id)
	elif toward_trunk.z == -1:
		c.set_micro_sub(cell, Chunk._sub_index(0, 0, 1), base_id)
		c.set_micro_sub(cell, Chunk._sub_index(1, 0, 1), base_id)

func _ring_around_trunk(c:Chunk, trunk_xy:Vector3i, y:int, base_id:int) -> bool:
	var placed := false
	var dirs := [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,0,1), Vector3i(0,0,-1)]
	for d in dirs:
		var ncell := Vector3i(trunk_xy.x + d.x, y, trunk_xy.z + d.z)
		if Chunk.index_in_bounds(ncell.x, ncell.y, ncell.z) and c.get_block(ncell) == BlockDB.BlockId.AIR:
			_place_edge_half_pair(c, ncell, d, base_id)
			placed = true
	return placed

func _soften_canopy_near_trunk(c:Chunk, trunk:Vector3i, y_top:int, radius:int) -> bool:
	var placed := false
	for dx in range(-radius, radius+1):
		for dz in range(-radius, radius+1):
			for dy in range(0, 3):
				var p := Vector3i(trunk.x + dx, y_top + dy, trunk.z + dz)
				if not Chunk.index_in_bounds(p.x, p.y, p.z): continue
				if c.get_block(p) != BlockDB.BlockId.LEAVES: continue

				var dirs := [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,0,1), Vector3i(0,0,-1)]
				for d in dirs:
					var n = p + d
					if not Chunk.index_in_bounds(n.x, n.y, n.z): continue
					if c.get_block(n) == BlockDB.BlockId.AIR:
						var n2 = n + d
						if not Chunk.index_in_bounds(n2.x, n2.y, n2.z) or c.get_block(n2) != BlockDB.BlockId.LEAVES:
							_place_edge_half_pair(c, n, d, BlockDB.BlockId.LEAVES)
							placed = true
	return placed

func _decorate_tree_with_notches(c:Chunk, at:Vector3i, height:int) -> void:
	var wx := c.chunk_pos.x * CX + at.x
	var wz := c.chunk_pos.z * CZ + at.z
	var gate := micro_noise.get_noise_2d(wx, wz)
	if gate < TREE_NOTCH_GATE:
		return

	var changed := false
	var trunk_xy := Vector3i(at.x, 0, at.z)
	changed = _ring_around_trunk(c, trunk_xy, at.y, BlockDB.BlockId.LOG) or changed

	var y_top := at.y + height
	changed = _ring_around_trunk(c, trunk_xy, y_top, BlockDB.BlockId.LEAVES) or changed
	changed = _soften_canopy_near_trunk(c, at, y_top, CROWN_SCAN_RADIUS) or changed

	if changed:
		c.dirty = true


# =========================================================
# Break/place notch API — unchanged (works with streamed chunks)
# =========================================================
static func _world_to_cell_and_sub(wpos: Vector3) -> Dictionary:
	var cell := Vector3i(floori(wpos.x), floori(wpos.y), floori(wpos.z))
	var local := wpos - Vector3(cell)
	var ix := int(floor(clamp(local.x, 0.0, 0.999) * 2.0))
	var iy := int(floor(clamp(local.y, 0.0, 0.999) * 2.0))
	var iz := int(floor(clamp(local.z, 0.0, 0.999) * 2.0))
	return {"cell": cell, "ix": ix, "iy": iy, "iz": iz}

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

	c.clear_micro_sub(lpos, s)
	c.dirty = true
	c.rebuild_mesh()

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
	var s  := Chunk._sub_index(ix, iy, iz)

	if face_normal != Vector3.ZERO and BlockDB.is_orientable(base_id):
		base_id = BlockDB.orient_block_for_normal(base_id, face_normal)

	# Only place into empty cells (don’t bury notches inside full blocks)
	if c.get_block(lpos) != BlockDB.BlockId.AIR:
		return

	c.set_micro_sub(lpos, s, base_id)
	c.rebuild_mesh()


# =========================================================
# Edit-side immediate side-effects
# =========================================================
func _on_block_changed_immediate(c: Chunk, lp: Vector3i, new_id: int) -> void:
	if _covers_grass(new_id):
		var below := lp + Vector3i(0, -1, 0)
		if Chunk.index_in_bounds(below.x, below.y, below.z):
			if c.get_block(below) == BlockDB.BlockId.GRASS:
				c.set_block(below, BlockDB.BlockId.DIRT)
				c.dirty = true


# =========================================================
# Entity placement (kept from your version)
# =========================================================
func place_entity_at_world(wpos: Vector3, id: int) -> void:
	var ps: PackedScene = BlockDB.entity_packed_scene(id)
	if ps == null:
		push_warning("place_entity_at_world: no PackedScene for id %d" % id)
		return

	var node: Node3D = ps.instantiate() as Node3D
	add_child(node)

	var gx: float = float(floori(wpos.x)) + 0.5
	var gy: float = float(floori(wpos.y)) + 0.0
	var gz: float = float(floori(wpos.z)) + 0.5
	node.global_position = Vector3(gx, gy, gz)

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

	var gx: float = float(floori(wpos.x)) + 0.5
	var gy: float = float(floori(wpos.y)) + 0.0
	var gz: float = float(floori(wpos.z)) + 0.5
	node.global_position = Vector3(gx, gy, gz)
	node.rotation = Vector3(0.0, 0.0, 0.0)

	var n: Vector3 = face_normal
	var f: Vector3 = Vector3.ZERO

	if abs(n.y) < 0.5:
		f = Vector3(n.x, 0.0, n.z).normalized()
	else:
		f = player_world_pos - node.global_position
		f.y = 0.0
		if f.length() < 0.001:
			f = Vector3(player_forward.x, 0.0, player_forward.z)

	if f.length() < 0.001:
		return

	var yaw: float = atan2(f.x, f.z) + PI  # align -Z to f
	var step: float = PI * 0.5
	yaw = round(yaw / step) * step

	var extra_deg: float = BlockDB.entity_facing_yaw_deg(id)
	yaw += deg_to_rad(extra_deg)

	node.rotation = Vector3(0.0, yaw, 0.0)


# =========================================================
# Neighborhood scans used by ticks
# =========================================================
func _no_log_nearby(c:Chunk, p:Vector3i, r:int) -> bool:
	for dx in range(-r, r+1):
		for dy in range(-r, r+1):
			for dz in range(-r, r+1):
				var q := p + Vector3i(dx,dy,dz)
				if Chunk.index_in_bounds(q.x,q.y,q.z) and c.get_block(q) == BlockDB.BlockId.LOG:
					return false
	return true
