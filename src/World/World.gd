extends Node3D
class_name World

const CX := Chunk.CX
const CY := Chunk.CY
const CZ := Chunk.CZ

# ---- Player-centered streaming ----
const RENDER_RADIUS := 5        # in chunks (5 => 11x11)
const TICK_SECONDS := 0.5

const PRELOAD_RADIUS := RENDER_RADIUS + 2   # one ring ahead for prewarm
const BUILD_BUDGET_PER_FRAME := 1           # rebuild at most N chunks per frame

# ---- Micro smoothing thresholds ----
const MICRO_TERRAIN_GATE := 0.15
const MICRO_LEAF_GATE := 0.10
const MICRO_Y_UPPER := 0

# --- Vertical world scale (new) ---
const SURFACE_MIN := 56    # min surface Y in blocks
const SURFACE_MAX := 112   # max surface Y in blocks
const TREE_NOTCH_GATE := 0.25
const CROWN_SCAN_RADIUS := 3

# ---- Data ----
var atlas: Texture2D
var chunks := {}                              # Dictionary<Vector3i, Chunk]
var _tick_accum := 0.0
var _tick_phase := 0

const COLLISION_RADIUS: int = 1						# chunks near player that get colliders
const TICK_CHUNK_RADIUS: int = 0					# chunks near player that tick simulation
const SPAWN_BUDGET_PER_FRAME: int = 1				# spawn at most N new chunk nodes / frame
const GEN_BUDGET_PER_FRAME: int = 3					# generate block data for at most N chunks / frame
# BUILD_BUDGET_PER_FRAME already exists and caps mesh builds per frame (keep it)
const CHUNK_POOL_SIZE: int = 64						# simple pool upper bound
const GEN_TASK_CONCURRENCY := 10 # optional cap

# ---- Noises (deterministic) ----
var height_noise := FastNoiseLite.new()       # terrain height
var tree_noise   := FastNoiseLite.new()       # tree presence/height
var leaf_noise   := FastNoiseLite.new()       # crown jitter
var micro_noise  := FastNoiseLite.new()       # micro smoothing (terrain & canopy)
var tick_noise   := FastNoiseLite.new()       # replaces RNG in world ticks

# ---- Mesh cache for instant revisits ----
const MESH_CACHE_STORE_MESH: bool = true
const MESH_CACHE_STORE_SHAPE: bool = false
const MESH_CACHE_LIMIT := 48
var _mesh_cache := {}                 # Dictionary<Vector3i, Dictionary]
var _mesh_lru: Array[Vector3i] = []

# ---- Meshing workers ----
var _mesh_tasks := {}              # cpos -> true (avoid dup)
var _mesh_results: Array = []      # worker → main
var _mesh_mutex := Mutex.new()
const MESH_APPLY_BUDGET_PER_FRAME := 1

# ---- Player reference ----
@export var player_path: NodePath
var _player: Node3D

# [QUEUES]
var _rebuild_queue: Array = []   # Array<Chunk>

var _spawn_queue: Array[Vector3i] = []				# positions to spawn
var _gen_queue: Array[Chunk] = []					# chunks needing block generation

var _chunk_pool: Array[Chunk] = []					# recycled chunks

# ---- Threaded generation & caching ----
const CACHE_LIMIT := 256                          # how many chunk datas to keep
const APPLY_GEN_BUDGET_PER_FRAME := 2             # apply N generated results / frame

var _chunk_cache := {}                            # Dictionary<Vector3i, Dictionary snapshot]
var _cache_lru: Array[Vector3i] = []              # most-recent-first positions

# Worker thread plumbing for generation
var _gen_tasks := {}                               # cpos -> true (to avoid duplicates)
var _gen_results: Array = []                       # results arriving from workers
var _gen_mutex := Mutex.new()

# --- Streaming hysteresis ---
const DESPAWN_RADIUS := PRELOAD_RADIUS + 1    # keep chunks 1 ring beyond preload
const COLLISION_ON_RADIUS := COLLISION_RADIUS # turn ON at this distance
const COLLISION_OFF_RADIUS := COLLISION_RADIUS + 1  # turn OFF only when 1 ring farther

# --- Priorities / budgets ---
const MESH_APPLY_BUDGET_NEAR := 1            # apply more results when near chunks are pending
const BEAUTIFY_BUDGET_PER_FRAME := 1         # low background polish pass

var _beautify_queue: Array[Chunk] = []

const USE_GREEDY_TOPS := true   # opaque-only greedy +Y faces in worker

const GREEDY_TOPS_MODE := 1
const GREEDY_BOTTOMS := true         # merge -Y opaque faces
const GREEDY_SIDES   := true         # merge ±X and ±Z opaque faces


var MAT_OPAQUE: StandardMaterial3D
var MAT_TRANS: StandardMaterial3D

const HIDE_DIM := 256  # adjust if your block IDs exceed 255
var HIDE_LUT := PackedByteArray()

const MESH_TASK_CONCURRENCY := 4  # 0 = unlimited
const COLLIDER_BUILD_BUDGET_PER_FRAME: int = 1

var _collider_queue: Array[Chunk] = []
var _collider_enqueued := {}   # Dictionary<Chunk, bool>

const URGENT_RADIUS:int = RENDER_RADIUS          # chunks that must never be missing
const URGENT_SPAWN:int = 3
const URGENT_GEN:int = 3
const URGENT_MESH_APPLY:int = 2

var _last_seen_frame := {}  # Dictionary<Vector3i,int]

func _nudge_stalled_near() -> void:
	var frame:int = Engine.get_frames_drawn()
	var center: Vector3i = _player_chunk()
	for cpos in chunks.keys():
		var cp: Vector3i = cpos
		var dx:int = abs(cp.x - center.x)
		var dz:int = abs(cp.z - center.z)
		if dx > URGENT_RADIUS or dz > URGENT_RADIUS:
			continue
		var c: Chunk = chunks[cp]
		if c == null or not is_instance_valid(c) or c.pending_kill:
			continue

		var ready_mesh:bool = c.mesh_instance.mesh != null and c.mesh_instance.mesh.get_surface_count() > 0
		if not ready_mesh:
			var last:int = int(_last_seen_frame.get(cp, 0))
			if frame - last > 120:       # ~2 seconds @60fps
				# poke both queues
				if not _gen_tasks.has(cp):
					_gen_queue.push_front(c)
				if not _mesh_tasks.has(cp):
					_rebuild_queue.push_front(c)
				_last_seen_frame[cp] = frame
			else:
				_last_seen_frame[cp] = frame


func _ensure_near_ring_filled() -> void:
	var center: Vector3i = _player_chunk()
	var missing_count:int = 0

	for dz in range(-URGENT_RADIUS, URGENT_RADIUS + 1):
		for dx in range(-URGENT_RADIUS, URGENT_RADIUS + 1):
			var cpos: Vector3i = Vector3i(center.x + dx, 0, center.z + dz)

			# 1) hard-spawn if absent
			if not chunks.has(cpos):
				var c: Chunk = _obtain_chunk()
				c.position = Vector3(cpos.x * CX, 0.0, cpos.z * CZ)
				c.reuse_setup(cpos, atlas)
				chunks[cpos] = c
				# put gen at the very front
				_gen_queue.push_front(c)
				missing_count += 1
				continue

			# 2) if spawned but has no block data yet → make sure gen is queued
			var ch: Chunk = chunks[cpos]
			if ch == null or not is_instance_valid(ch) or ch.pending_kill:
				continue

			# empty blocks = never generated
			var needs_gen: bool = ch.blocks.size() == 0 or (ch.blocks[0] as Array).size() == 0
			if needs_gen and not _gen_tasks.has(cpos):
				_gen_queue.push_front(ch)
				missing_count += 1

			# 3) has blocks but no mesh yet → ensure rebuild is at front
			if ch.blocks.size() > 0:
				var mesh_null: bool = ch.mesh_instance.mesh == null or ch.mesh_instance.mesh.get_surface_count() == 0
				if mesh_null and not _mesh_tasks.has(cpos):
					_rebuild_queue.push_front(ch)
					missing_count += 1

	# temporarily boost budgets if anything urgent is missing
	if missing_count > 0:
		_drain_spawn_queue(URGENT_SPAWN)
		_drain_gen_queue(URGENT_GEN)
		_drain_mesh_results(URGENT_MESH_APPLY)


# =========================================================
# Lifecycle
# =========================================================
func _ready() -> void:
	atlas = load(BlockDB.ATLAS_PATH)
	BlockDB.configure_from_texture(atlas)
	_build_hide_lut()

	MAT_OPAQUE = StandardMaterial3D.new()
	MAT_OPAQUE.albedo_texture = atlas
	MAT_OPAQUE.roughness = 1.0
	MAT_OPAQUE.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	MAT_TRANS = MAT_OPAQUE.duplicate()
	MAT_TRANS.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

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

func _queue_collider_build(c: Chunk) -> void:
	if c == null or not is_instance_valid(c) or c.pending_kill:
		return
	if _collider_enqueued.get(c, false):
		return
	_collider_enqueued[c] = true
	_collider_queue.append(c)

func _drain_collider_queue(max_count: int) -> void:
	var built := 0
	while built < max_count and _collider_queue.size() > 0:
		var c: Chunk = _collider_queue.pop_front()
		_collider_enqueued.erase(c)
		if c == null or not is_instance_valid(c) or c.pending_kill:
			continue
		if c.mesh_instance.mesh == null or c.mesh_instance.mesh.get_surface_count() == 0:
			continue
		# the only heavy bit happens here, and now it's strictly budgeted:
		c._set_collision_after_mesh(c.mesh_instance.mesh)
		built += 1

func _drain_beautify_queue(max_count:int) -> void:
	if _beautify_queue.size() == 0:
		return
	var applied := 0
	# nearest-first inside beautify too
	_beautify_queue.sort_custom(func(a, b):
		return a.position.distance_squared_to(_player.global_position) < b.position.distance_squared_to(_player.global_position)
	)
	while applied < max_count and _beautify_queue.size() > 0:
		var c: Chunk = _beautify_queue.pop_front()
		if c == null or not is_instance_valid(c) or c.pending_kill:
			continue
		# Apply beautify on main thread, then rebuild off-thread (old mesh stays visible)
		_seed_micro_slopes_terrain(c)
		#_decorate_tree_with_notches(c)
		# _seed_micro_slopes_leaves(c)  # optional
		# Re-decorate canopies if you like (safe; idempotent-ish)
		# NOTE: if you want exact same notches as gen-worker found, pass the saved tree list.
		# For simplicity we'll skip re-decoration here:
		c.dirty = true
		_queue_rebuild(c)
		applied += 1

func _ensure_near_colliders() -> void:
	var center := _player_chunk()
	for dz in range(-COLLISION_ON_RADIUS, COLLISION_ON_RADIUS + 1):
		for dx in range(-COLLISION_ON_RADIUS, COLLISION_ON_RADIUS + 1):
			var cpos := Vector3i(center.x + dx, 0, center.z + dz)
			if not chunks.has(cpos): continue
			var c: Chunk = chunks[cpos]
			if c == null or not is_instance_valid(c) or c.pending_kill: continue
			if c.collision_shape.shape == null:
				var m := c.mesh_instance.mesh
				if m != null and m.get_surface_count() > 0:
					_queue_collider_build(c)


func _process(dt: float) -> void:
	if _player == null:
		return

	_tick_accum += dt
	if _tick_accum >= TICK_SECONDS:
		_world_tick()
		_tick_accum = 0.0
		_tick_phase += 1

	_update_chunks_around_player()
	
	#_ensure_near_ring_filled() 
	#_nudge_stalled_near() these tank fps, only needed if chunks were not saved/ generated correctly. Symptom treatment, i.e. sub optimal.
	
	_drain_spawn_queue(SPAWN_BUDGET_PER_FRAME)
	_drain_gen_queue(GEN_BUDGET_PER_FRAME)
	_drain_rebuild_queue(BUILD_BUDGET_PER_FRAME)
	_drain_gen_results(APPLY_GEN_BUDGET_PER_FRAME)
	_drain_mesh_results(MESH_APPLY_BUDGET_PER_FRAME)
	_drain_collider_queue(COLLIDER_BUILD_BUDGET_PER_FRAME)
	_drain_beautify_queue(BEAUTIFY_BUDGET_PER_FRAME)
	_ensure_near_colliders()

func _build_hide_lut() -> void:
	var N := HIDE_DIM * HIDE_DIM
	HIDE_LUT.resize((N + 7) / 8)
	# Compute once (on main thread) using your current rules
	for a in HIDE_DIM:
		for b in HIDE_DIM:
			if BlockDB.face_hidden_by_neighbor(a, b):
				var idx := a * HIDE_DIM + b
				HIDE_LUT[idx >> 3] |= (1 << (idx & 7))

func _face_hidden_fast(a:int, b:int) -> bool:
	if b == BlockDB.BlockId.AIR:
		return false
	var idx := a * HIDE_DIM + b
	return ((HIDE_LUT[idx >> 3] >> (idx & 7)) & 1) == 1

# =========================================================
# Streaming chunks around player
# =========================================================
func _push_tri(dst: Dictionary, v0: Vector3, v1: Vector3, v2: Vector3, n: Vector3, uv0: Vector2, uv1: Vector2, uv2: Vector2) -> void:
	dst["v"].append(v0); dst["v"].append(v1); dst["v"].append(v2)
	dst["n"].append(n);  dst["n"].append(n);  dst["n"].append(n)
	dst["uv"].append(uv0); dst["uv"].append(uv1); dst["uv"].append(uv2)

func _push_quad(dst: Dictionary, q: Array, n: Vector3, uv0: Vector2, uv1: Vector2, uv2: Vector2, uv3: Vector2) -> void:
	# q: [v0,v1,v2,v3] in your same winding
	_push_tri(dst, q[0], q[2], q[1], n, uv0, uv2, uv1)
	_push_tri(dst, q[0], q[3], q[2], n, uv0, uv3, uv2)

func _drain_mesh_results(max_count:int) -> void:
	# Pull everything currently available (atomic)
	var pulled: Array = []
	_mesh_mutex.lock()
	if _mesh_results.size() > 0:
		pulled = _mesh_results.duplicate()
		_mesh_results.clear()
	_mesh_mutex.unlock()
	if pulled.size() == 0:
		return

	# Sort by distance to player (nearest first)
	pulled.sort_custom(func(a, b):
		return _dist2_chunk_to_player(a["cpos"]) < _dist2_chunk_to_player(b["cpos"])
	)

	# Boost budget if any result is within the collision ring
	var budget := max_count
	var center := _player_chunk()
	for r in pulled:
		var cpos: Vector3i = r["cpos"]
		var dx = abs(cpos.x - center.x)
		var dz = abs(cpos.z - center.z)
		if dx <= COLLISION_ON_RADIUS and dz <= COLLISION_ON_RADIUS:
			budget = MESH_APPLY_BUDGET_NEAR
			break

	var applied := 0
	var i := 0
	var t0 := Time.get_ticks_usec()
	const SLICE_US := 8000  # try 4000–6000 if 3000 is too tight

	while i < pulled.size() and applied < budget:
		var r = pulled[i]
		var cpos: Vector3i = r["cpos"]
		_mesh_tasks.erase(cpos)

		if chunks.has(cpos):
			var c: Chunk = chunks[cpos]
			if c != null and is_instance_valid(c) and not c.pending_kill:
				# NEW: detect edits after snapshot
				var changed_after_snapshot := c.dirty

				var mesh := c.mesh_instance.mesh
				if mesh == null:
					mesh = ArrayMesh.new()
					c.mesh_instance.mesh = mesh
				else:
					mesh.clear_surfaces()

				# ---------- build two buckets (opaque/trans) ----------
				var o_v := PackedVector3Array(); var o_n := PackedVector3Array(); var o_uv := PackedVector2Array()
				var t_v := PackedVector3Array(); var t_n := PackedVector3Array(); var t_uv := PackedVector2Array()

				for s in r["sections"].size():
					var so = r["sections"][s]["opaque"]
					if so["v"].size() > 0:
						o_v.append_array(so["v"]); o_n.append_array(so["n"]); o_uv.append_array(so["uv"])
					var st = r["sections"][s]["trans"]
					if st["v"].size() > 0:
						t_v.append_array(st["v"]); t_n.append_array(st["n"]); t_uv.append_array(st["uv"])

				if o_v.size() > 0:
					var arr := []; arr.resize(Mesh.ARRAY_MAX)
					arr[Mesh.ARRAY_VERTEX] = o_v
					arr[Mesh.ARRAY_NORMAL] = o_n
					arr[Mesh.ARRAY_TEX_UV] = o_uv
					var idx := mesh.get_surface_count()
					mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
					mesh.surface_set_material(idx, MAT_OPAQUE)  # shared

				if t_v.size() > 0:
					var arr2 := []; arr2.resize(Mesh.ARRAY_MAX)
					arr2[Mesh.ARRAY_VERTEX] = t_v
					arr2[Mesh.ARRAY_NORMAL] = t_n
					arr2[Mesh.ARRAY_TEX_UV] = t_uv
					var idx2 := mesh.get_surface_count()
					mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr2)
					mesh.surface_set_material(idx2, MAT_TRANS)  # shared

				# collider policy (avoid building collider for stale mesh)
				var dx2 = abs(c.chunk_pos.x - center.x)
				var dz2 = abs(c.chunk_pos.z - center.z)
				if c.wants_collision and not changed_after_snapshot:
					_queue_collider_build(c)

				# ---- IMPORTANT: don't clobber a real dirty ----
				for s in c.SECTION_COUNT:
					c.section_dirty[s] = 0

				if changed_after_snapshot:
					# A newer mutation happened while this worker ran.
					# Keep dirty and ensure it rebuilds ASAP so notches/micro show up.
					c.dirty = true
					if not _rebuild_queue.has(c):
						_rebuild_queue.push_front(c)
				else:
					c.dirty = false

				_mesh_cache_put(cpos, c.snapshot_mesh_and_data())
				applied += 1

		i += 1

		# Only time-slice AFTER we’ve applied at least one result
		if applied > 0 and (Time.get_ticks_usec() - t0) > SLICE_US:	
			break

	# Re-queue ALL leftovers so nothing gets lost
	if i < pulled.size():
		_mesh_mutex.lock()
		for j in range(i, pulled.size()):
			_mesh_results.push_back(pulled[j])
		_mesh_mutex.unlock()

# Greedy topo layer at fixed y (opaque-only, +Y faces).
# Builds rectangles in X-Z where:
#  - current block is opaque (not transparent, not AIR)
#  - block above is AIR or transparent (face visible)
# Greedy topo layer at fixed y (opaque-only, +Y faces).

func _build_bottom_mask(CX:int, CY:int, CZ:int, blocks:Array, y:int) -> Array:
	var mask := []
	mask.resize(CX)
	for x in CX:
		var row := PackedInt32Array()
		row.resize(CZ)
		for z in CZ:
			row[z] = -1
			var id:int = blocks[x][y][z]
			if id == BlockDB.BlockId.AIR:
				continue
			if BlockDB.is_transparent(id):
				continue
			var below_id:int = BlockDB.BlockId.AIR
			if y - 1 >= 0:
				below_id = blocks[x][y - 1][z]
			if _face_hidden_fast(id, below_id):
				continue
			row[z] = BlockDB.get_face_tile(id, 3)  # -Y
		mask[x] = row
	return mask

func _emit_bottom_rects(mask:Array, y:int, dst_opaque:Dictionary) -> void:
	var CXv:int = mask.size()
	if CXv == 0:
		return
	var CZv:int = (mask[0] as PackedInt32Array).size()
	var visited := []
	visited.resize(CXv)
	for x in CXv:
		var rowb := PackedByteArray()
		rowb.resize(CZv)
		for z in CZv:
			rowb[z] = 0
		visited[x] = rowb

	var face_i:int = 3
	var nrm := Vector3(0, -1, 0)
	var locals := [Vector3(0,0,0), Vector3(1,0,0), Vector3(1,0,1), Vector3(0,0,1)]

	var x:int = 0
	while x < CXv:
		var z:int = 0
		while z < CZv:
			var tile:int = (mask[x] as PackedInt32Array)[z]
			if visited[x][z] == 0 and tile >= 0:
				var w:int = 1
				while (x + w) < CXv and visited[x + w][z] == 0 and (mask[x + w] as PackedInt32Array)[z] == tile:
					w += 1
				var h:int = 1
				while (z + h) < CZv:
					var ok:bool = true
					for xx in range(x, x + w):
						if visited[xx][z + h] == 1 or (mask[xx] as PackedInt32Array)[z + h] != tile:
							ok = false
							break
					if not ok:
						break
					h += 1
				for xx in range(x, x + w):
					for zz in range(z, z + h):
						visited[xx][zz] = 1

				var v0 := Vector3(x,     y, z)
				var v1 := Vector3(x + w, y, z)
				var v2 := Vector3(x + w, y, z + h)
				var v3 := Vector3(x,     y, z + h)

				var uvs := BlockDB.tile_uvs(tile)
				var uv0 := _chunk_uv_from_local_pre(face_i, locals[0], uvs)
				var uv1 := _chunk_uv_from_local_pre(face_i, locals[1], uvs)
				var uv2 := _chunk_uv_from_local_pre(face_i, locals[2], uvs)
				var uv3 := _chunk_uv_from_local_pre(face_i, locals[3], uvs)
				_push_quad(dst_opaque, [v0,v1,v2,v3], nrm, uv0, uv1, uv2, uv3)

				z += h
			else:
				z += 1
		x += 1

func _build_x_plane_mask(CX:int, CY:int, CZ:int, blocks:Array, x:int, y0:int, y1:int, face_i:int) -> Array:
	var H:int = y1 - y0 + 1
	var mask := []
	mask.resize(CZ)
	for z in CZ:
		var col := PackedInt32Array()
		col.resize(H)
		for i in H:
			col[i] = -1
			var y:int = y0 + i
			var id:int = blocks[x][y][z]
			if id == BlockDB.BlockId.AIR:
				continue
			if BlockDB.is_transparent(id):
				continue
			var nx:int = x + 1
			if face_i == 1:
				nx = x - 1
			var neighbor_id:int = BlockDB.BlockId.AIR
			if nx >= 0 and nx < CX:
				neighbor_id = blocks[nx][y][z]
			if _face_hidden_fast(id, neighbor_id):
				continue
			col[i] = BlockDB.get_face_tile(id, face_i)
		mask[z] = col
	return mask

func _emit_x_plane_rects(mask:Array, x:int, y0:int, dst_opaque:Dictionary, face_i:int) -> void:
	var CZv:int = mask.size()
	if CZv == 0:
		return
	var H:int = (mask[0] as PackedInt32Array).size()
	var visited := []
	visited.resize(CZv)
	for z in CZv:
		var colv := PackedByteArray()
		colv.resize(H)
		for i in H:
			colv[i] = 0
		visited[z] = colv

	var nrm := Vector3(1,0,0)
	if face_i == 1:
		nrm = Vector3(-1,0,0)
	var x_plane:int = x + 1
	if face_i == 1:
		x_plane = x

	var locals_px := [Vector3(1,0,0), Vector3(1,1,0), Vector3(1,1,1), Vector3(1,0,1)]
	var locals_nx := [Vector3(0,0,1), Vector3(0,1,1), Vector3(0,1,0), Vector3(0,0,0)]

	var z:int = 0
	while z < CZv:
		var i:int = 0
		while i < H:
			var tile:int = (mask[z] as PackedInt32Array)[i]
			if visited[z][i] == 0 and tile >= 0:
				var w:int = 1
				while (z + w) < CZv and visited[z + w][i] == 0 and (mask[z + w] as PackedInt32Array)[i] == tile:
					w += 1
				var h:int = 1
				while (i + h) < H:
					var ok:bool = true
					for zz in range(z, z + w):
						if visited[zz][i + h] == 1 or (mask[zz] as PackedInt32Array)[i + h] != tile:
							ok = false
							break
					if not ok:
						break
					h += 1
				for zz in range(z, z + w):
					for ii in range(i, i + h):
						visited[zz][ii] = 1

				var y_start:int = y0 + i
				var y_end:int = y_start + h
				var z_end:int = z + w

				var v0:Vector3
				var v1:Vector3
				var v2:Vector3
				var v3:Vector3
				if face_i == 0:
					v0 = Vector3(x_plane, y_start, z)
					v1 = Vector3(x_plane, y_end,   z)
					v2 = Vector3(x_plane, y_end,   z_end)
					v3 = Vector3(x_plane, y_start, z_end)
				else:
					v0 = Vector3(x_plane, y_start, z_end)
					v1 = Vector3(x_plane, y_end,   z_end)
					v2 = Vector3(x_plane, y_end,   z)
					v3 = Vector3(x_plane, y_start, z)

				var uvs := BlockDB.tile_uvs(tile)
				var uv0:Vector2
				var uv1:Vector2
				var uv2:Vector2
				var uv3:Vector2
				if face_i == 0:
					uv0 = _chunk_uv_from_local_pre(0, locals_px[0], uvs)
					uv1 = _chunk_uv_from_local_pre(0, locals_px[1], uvs)
					uv2 = _chunk_uv_from_local_pre(0, locals_px[2], uvs)
					uv3 = _chunk_uv_from_local_pre(0, locals_px[3], uvs)
				else:
					uv0 = _chunk_uv_from_local_pre(1, locals_nx[0], uvs)
					uv1 = _chunk_uv_from_local_pre(1, locals_nx[1], uvs)
					uv2 = _chunk_uv_from_local_pre(1, locals_nx[2], uvs)
					uv3 = _chunk_uv_from_local_pre(1, locals_nx[3], uvs)

				_push_quad(dst_opaque, [v0,v1,v2,v3], nrm, uv0, uv1, uv2, uv3)
				i += h
			else:
				i += 1
		z += 1

func _build_z_plane_mask(CX:int, CY:int, CZ:int, blocks:Array, z:int, y0:int, y1:int, face_i:int) -> Array:
	var H:int = y1 - y0 + 1
	var mask := []
	mask.resize(CX)
	for x in CX:
		var col := PackedInt32Array()
		col.resize(H)
		for i in H:
			col[i] = -1
			var y:int = y0 + i
			var id:int = blocks[x][y][z]
			if id == BlockDB.BlockId.AIR:
				continue
			if BlockDB.is_transparent(id):
				continue
			var nz:int = z + 1
			if face_i == 5:
				nz = z - 1
			var neighbor_id:int = BlockDB.BlockId.AIR
			if nz >= 0 and nz < CZ:
				neighbor_id = blocks[x][y][nz]
			if _face_hidden_fast(id, neighbor_id):
				continue
			col[i] = BlockDB.get_face_tile(id, face_i)
		mask[x] = col
	return mask

func _emit_z_plane_rects(mask:Array, z:int, y0:int, dst_opaque:Dictionary, face_i:int) -> void:
	var CXv:int = mask.size()
	if CXv == 0:
		return
	var H:int = (mask[0] as PackedInt32Array).size()
	var visited := []
	visited.resize(CXv)
	for x in CXv:
		var colv := PackedByteArray()
		colv.resize(H)
		for i in H:
			colv[i] = 0
		visited[x] = colv

	var nrm := Vector3(0,0,1)
	if face_i == 5:
		nrm = Vector3(0,0,-1)
	var z_plane:int = z + 1
	if face_i == 5:
		z_plane = z

	var locals_pz := [Vector3(0,0,1), Vector3(1,0,1), Vector3(1,1,1), Vector3(0,1,1)]
	var locals_nz := [Vector3(0,1,0), Vector3(1,1,0), Vector3(1,0,0), Vector3(0,0,0)]

	var x:int = 0
	while x < CXv:
		var i:int = 0
		while i < H:
			var tile:int = (mask[x] as PackedInt32Array)[i]
			if visited[x][i] == 0 and tile >= 0:
				var w:int = 1
				while (x + w) < CXv and visited[x + w][i] == 0 and (mask[x + w] as PackedInt32Array)[i] == tile:
					w += 1
				var h:int = 1
				while (i + h) < H:
					var ok:bool = true
					for xx in range(x, x + w):
						if visited[xx][i + h] == 1 or (mask[xx] as PackedInt32Array)[i + h] != tile:
							ok = false
							break
					if not ok:
						break
					h += 1
				for xx in range(x, x + w):
					for ii in range(i, i + h):
						visited[xx][ii] = 1

				var y_start:int = y0 + i
				var y_end:int = y_start + h
				var x_end:int = x + w

				var v0:Vector3
				var v1:Vector3
				var v2:Vector3
				var v3:Vector3
				if face_i == 4:
					v0 = Vector3(x,     y_start, z_plane)
					v1 = Vector3(x_end, y_start, z_plane)
					v2 = Vector3(x_end, y_end,   z_plane)
					v3 = Vector3(x,     y_end,   z_plane)
				else:
					v0 = Vector3(x_end, y_start, z_plane)
					v1 = Vector3(x,     y_start, z_plane)
					v2 = Vector3(x,     y_end,   z_plane)
					v3 = Vector3(x_end, y_end,   z_plane)

				var uvs := BlockDB.tile_uvs(tile)
				var uv0:Vector2
				var uv1:Vector2
				var uv2:Vector2
				var uv3:Vector2
				if face_i == 4:
					uv0 = _chunk_uv_from_local_pre(4, locals_pz[0], uvs)
					uv1 = _chunk_uv_from_local_pre(4, locals_pz[1], uvs)
					uv2 = _chunk_uv_from_local_pre(4, locals_pz[2], uvs)
					uv3 = _chunk_uv_from_local_pre(4, locals_pz[3], uvs)
				else:
					uv0 = _chunk_uv_from_local_pre(5, locals_nz[0], uvs)
					uv1 = _chunk_uv_from_local_pre(5, locals_nz[1], uvs)
					uv2 = _chunk_uv_from_local_pre(5, locals_nz[2], uvs)
					uv3 = _chunk_uv_from_local_pre(5, locals_nz[3], uvs)

				_push_quad(dst_opaque, [v0,v1,v2,v3], nrm, uv0, uv1, uv2, uv3)
				i += h
			else:
				i += 1
		x += 1


func _emit_greedy_tops_layer(CX:int, CY:int, CZ:int, blocks:Array, y:int, dst_opaque:Dictionary) -> void:
	# Build a mask of tiles for this layer; -1 means NO FACE.
	var tile_mask := []
	tile_mask.resize(CX)
	for x in CX:
		var row := PackedInt32Array()
		row.resize(CZ)
		for z in CZ:
			row[z] = -1  # <- EMPTY
			var id = blocks[x][y][z]
			if id != BlockDB.BlockId.AIR and not BlockDB.is_transparent(id):
				var above_id := BlockDB.BlockId.AIR
				if y + 1 < CY:
					above_id = blocks[x][y + 1][z]
				if not BlockDB.face_hidden_by_neighbor(id, above_id):
					row[z] = BlockDB.get_face_tile(id, 2)  # +Y tile index (can be 0!)
		tile_mask[x] = row

	# visited bitmap
	var visited := []
	visited.resize(CX)
	for x in CX:
		var rowb := PackedByteArray()
		rowb.resize(CZ)
		for z in CZ: rowb[z] = 0
		visited[x] = rowb

	var x := 0
	while x < CX:
		var z := 0
		while z < CZ:
			if visited[x][z] == 0 and tile_mask[x][z] >= 0:   # <- >= 0 now
				var tile = tile_mask[x][z]

				# width
				var w := 1
				while (x + w) < CX and visited[x + w][z] == 0 and tile_mask[x + w][z] == tile:
					w += 1

				# height
				var h := 1
				while (z + h) < CZ:
					var row_ok := true
					for xx in range(x, x + w):
						if visited[xx][z + h] == 1 or tile_mask[xx][z + h] != tile:
							row_ok = false
							break
					if not row_ok:
						break
					h += 1

				# mark
				for xx in range(x, x + w):
					for zz in range(z, z + h):
						visited[xx][zz] = 1

				_emit_top_rect_to(dst_opaque, x, y, z, w, h, tile)
				z += h
			else:
				z += 1
		x += 1

# Build one merged +Y quad at (x0,z0) of size (w,h); UVs stretch across the rect.
# (This keeps the atlas simple; if you later want UV tiling instead of stretching,
# we can move to texture arrays or a shader-based atlas.)

func _emit_top_rect_to(dst:Dictionary, x0:int, y:int, z0:int, w:int, h:int, tile:int) -> void:
	var nrm := Vector3(0,1,0)

	# Corners of the rect on the +Y plane (nrm up)
	# BL = (front-left), BR = (front-right), TR = (back-right), TL = (back-left)
	var vBL := Vector3(x0,     y + 1, z0)
	var vBR := Vector3(x0 + w, y + 1, z0)
	var vTR := Vector3(x0 + w, y + 1, z0 + h)
	var vTL := Vector3(x0,     y + 1, z0 + h)

	# Atlas UVs for one tile (no tiling — stretches across the merged rect)
	# Your BlockDB.tile_uvs returns [TL, TR, BR, BL]
	var uvs := BlockDB.tile_uvs(tile)
	var uvTL := uvs[0]
	var uvTR := uvs[1]
	var uvBR := uvs[2]
	var uvBL := uvs[3]

	# IMPORTANT: match your Chunk.rebuild_mesh() top-face order:
	# face_i==2 (+Y) originally used quads [TL,TR,BR,BL] and tris (v0,v2,v1) & (v0,v3,v2).
	# Map that to our rect vertices: vTL(=v0), vTR(=v1), vBR(=v2), vBL(=v3).

	# Tri 1: (TL, BR, TR)
	dst["v"].append(vTL); dst["v"].append(vBR); dst["v"].append(vTR)
	dst["n"].append(nrm); dst["n"].append(nrm); dst["n"].append(nrm)
	dst["uv"].append(uvTL); dst["uv"].append(uvBR); dst["uv"].append(uvTR)

	# Tri 2: (TL, BL, BR)
	dst["v"].append(vTL); dst["v"].append(vBL); dst["v"].append(vBR)
	dst["n"].append(nrm); dst["n"].append(nrm); dst["n"].append(nrm)
	dst["uv"].append(uvTL); dst["uv"].append(uvBL); dst["uv"].append(uvBR)

# Greedy +Y at fixed y using heightmap (opaque only).
# We emit a top face at (x,z,y) iff y == top_y from heightmap and block is opaque.
func _emit_greedy_tops_layer_hm(
		CX:int, CY:int, CZ:int,
		blocks:Array, heightmap:PackedInt32Array,
		y:int, dst_opaque:Dictionary
	) -> void:
	var tile_mask := []
	tile_mask.resize(CX)
	for x in CX:
		var row := PackedInt32Array()
		row.resize(CZ)
		for z in CZ:
			row[z] = -1  # empty by default
			var top_y := heightmap[x * CZ + z]
			if top_y == y:
				var id = blocks[x][y][z]
				if id != BlockDB.BlockId.AIR and not BlockDB.is_transparent(id):
					row[z] = BlockDB.get_face_tile(id, 2)  # +Y tile index (can be 0)
		tile_mask[x] = row

	# visited bitmap
	var visited := []
	visited.resize(CX)
	for x in CX:
		var rowb := PackedByteArray()
		rowb.resize(CZ)
		for z in CZ: rowb[z] = 0
		visited[x] = rowb

	var x := 0
	while x < CX:
		var z := 0
		while z < CZ:
			if visited[x][z] == 0 and tile_mask[x][z] >= 0:
				var tile = tile_mask[x][z]

				# width along +X
				var w := 1
				while (x + w) < CX and visited[x + w][z] == 0 and tile_mask[x + w][z] == tile:
					w += 1

				# height along +Z
				var h := 1
				while (z + h) < CZ:
					var row_ok := true
					for xx in range(x, x + w):
						if visited[xx][z + h] == 1 or tile_mask[xx][z + h] != tile:
							row_ok = false
							break
					if not row_ok:
						break
					h += 1

				# mark and emit merged rect
				for xx in range(x, x + w):
					for zz in range(z, z + h):
						visited[xx][zz] = 1
				_emit_top_rect_to(dst_opaque, x, y, z, w, h, tile)

				z += h
			else:
				z += 1
		x += 1

# Build a visibility mask for +Y faces at a specific y.
# Returns Array[PackedInt32Array] size [CX][CZ] with:
#  -1 = no +Y face here
#  >=0 = tile index for +Y (OK to be 0!)
func _build_top_mask(CX:int, CY:int, CZ:int, blocks:Array, y:int) -> Array:
	var mask := []
	mask.resize(CX)
	for x in CX:
		var row := PackedInt32Array()
		row.resize(CZ)
		for z in CZ:
			row[z] = -1
			var id = blocks[x][y][z]
			if id == BlockDB.BlockId.AIR: continue
			if BlockDB.is_transparent(id): continue
			var neighbor_id := BlockDB.BlockId.AIR
			if y + 1 < CY:
				neighbor_id = blocks[x][y + 1][z]
			if _face_hidden_fast(id, neighbor_id):
				continue
			row[z] = BlockDB.get_face_tile(id, 2)  # +Y tile index
		mask[x] = row
	return mask


# 1D greedy: merge runs along X for each Z row. Very robust and already a big win.
func _emit_greedy_tops_strips(mask:Array, y:int, dst_opaque:Dictionary) -> void:
	var CX := mask.size()
	if CX == 0: return
	var CZ := (mask[0] as PackedInt32Array).size()

	for z in CZ:
		var x := 0
		while x < CX:
			var tile := (mask[x] as PackedInt32Array)[z]
			if tile < 0:
				x += 1
				continue
			# extend run
			var x2 := x + 1
			while x2 < CX and (mask[x2] as PackedInt32Array)[z] == tile:
				x2 += 1
			var w := x2 - x
			_emit_top_rect_to(dst_opaque, x, y, z, w, 1, tile)
			x = x2


# 2D greedy rectangles (optional). Uses the same mask; merges both axes.
func _emit_greedy_tops_rects(mask:Array, y:int, dst_opaque:Dictionary) -> void:
	var CX := mask.size()
	if CX == 0: return
	var CZ := (mask[0] as PackedInt32Array).size()

	var visited := []
	visited.resize(CX)
	for x in CX:
		var rowb := PackedByteArray()
		rowb.resize(CZ)
		for z in CZ: rowb[z] = 0
		visited[x] = rowb

	var x := 0
	while x < CX:
		var z := 0
		while z < CZ:
			if visited[x][z] == 0 and (mask[x] as PackedInt32Array)[z] >= 0:
				var tile := (mask[x] as PackedInt32Array)[z]

				# width
				var w := 1
				while (x + w) < CX and visited[x + w][z] == 0 and (mask[x + w] as PackedInt32Array)[z] == tile:
					w += 1

				# height
				var h := 1
				while (z + h) < CZ:
					var ok := true
					for xx in range(x, x + w):
						if visited[xx][z + h] == 1 or (mask[xx] as PackedInt32Array)[z + h] != tile:
							ok = false; break
					if not ok: break
					h += 1

				# mark & emit
				for xx in range(x, x + w):
					for zz in range(z, z + h):
						visited[xx][zz] = 1
				_emit_top_rect_to(dst_opaque, x, y, z, w, h, tile)
				z += h
			else:
				z += 1
		x += 1


func _mesh_worker(snap: Dictionary) -> void:
	var cpos: Vector3i = snap["cpos"]
	var CX: int = snap["CX"]; var CY: int = snap["CY"]; var CZ: int = snap["CZ"]
	var SECTION_H: int = snap["section_h"]; var SECTION_COUNT: int = snap["section_count"]
	var blocks: Array = snap["blocks"]
	var heightmap: PackedInt32Array = snap["heightmap"]
	var micro: Dictionary = snap["micro"]

	# Return structure: per section {opaque:{v,n,uv}, trans:{v,n,uv}}
	var sections: Array = []
	sections.resize(SECTION_COUNT)
	for s in SECTION_COUNT:
		sections[s] = {
			"opaque": {"v": PackedVector3Array(), "n": PackedVector3Array(), "uv": PackedVector2Array()},
			"trans":  {"v": PackedVector3Array(), "n": PackedVector3Array(), "uv": PackedVector2Array()}
		}

	var faces := [
		Vector3( 1,0,0), Vector3(-1,0,0), Vector3(0,1,0),
		Vector3( 0,-1,0), Vector3(0,0,1), Vector3(0,0,-1)
	]
	var face_vertices := [
		[Vector3(1,0,0), Vector3(1,1,0), Vector3(1,1,1), Vector3(1,0,1)],
		[Vector3(0,0,1), Vector3(0,1,1), Vector3(0,1,0), Vector3(0,0,0)],
		[Vector3(0,1,1), Vector3(1,1,1), Vector3(1,1,0), Vector3(0,1,0)],
		[Vector3(0,0,0), Vector3(1,0,0), Vector3(1,0,1), Vector3(0,0,1)],
		[Vector3(0,0,1), Vector3(1,0,1), Vector3(1,1,1), Vector3(0,1,1)],
		[Vector3(0,1,0), Vector3(1,1,0), Vector3(1,0,0), Vector3(0,0,0)]
	]

	# ------- BIG BLOCKS -------
	for s in SECTION_COUNT:
		var y0 := s * SECTION_H
		var y1 = min(CY - 1, y0 + SECTION_H - 1)

		var dst_opaque = sections[s]["opaque"]
		var dst_trans  = sections[s]["trans"]

		# 1) Greedy +Y (opaque only), neighbor-based (works with caves/floating islands)
		if GREEDY_TOPS_MODE > 0:
			for y in range(y0, y1 + 1):
				var mask = _build_top_mask(CX, CY, CZ, blocks, y)  # -1 = no face, otherwise tile index
				if GREEDY_TOPS_MODE == 1:
					_emit_greedy_tops_strips(mask, y, dst_opaque)   # simple & robust
				else:
					_emit_greedy_tops_rects(mask, y, dst_opaque)    # 2D rectangles
		
		# --- Greedy -Y (opaque) ---
		if GREEDY_BOTTOMS:
			for y in range(y0, y1 + 1):
				var bm := _build_bottom_mask(CX, CY, CZ, blocks, y)
				_emit_bottom_rects(bm, y, dst_opaque)

		# --- Greedy sides (opaque): ±X and ±Z as 2D rectangles in Y with Z/X ---
		if GREEDY_SIDES:
			for x_ in CX:
				var mxp := _build_x_plane_mask(CX, CY, CZ, blocks, x_, y0, y1, 0)  # +X
				_emit_x_plane_rects(mxp, x_, y0, dst_opaque, 0)
			for x_ in CX:
				var mxn := _build_x_plane_mask(CX, CY, CZ, blocks, x_, y0, y1, 1)  # -X
				_emit_x_plane_rects(mxn, x_, y0, dst_opaque, 1)
			for z_ in CZ:
				var mzp := _build_z_plane_mask(CX, CY, CZ, blocks, z_, y0, y1, 4)  # +Z
				_emit_z_plane_rects(mzp, z_, y0, dst_opaque, 4)
			for z_ in CZ:
				var mzn := _build_z_plane_mask(CX, CY, CZ, blocks, z_, y0, y1, 5)  # -Z
				_emit_z_plane_rects(mzn, z_, y0, dst_opaque, 5)
		
		# 2) Regular emission for everything else:
		#    - all transparent blocks (all faces)
		#    - all opaque faces EXCEPT +Y (because greedy handled those when enabled)
		for x in CX:
			for z in CZ:
				for y in range(y0, y1 + 1):
					var id: int = blocks[x][y][z]
					if id == BlockDB.BlockId.AIR:
						continue
					var is_trans := BlockDB.is_transparent(id)
					
					

					for face_i in 6:
						if GREEDY_TOPS_MODE > 0 and (face_i == 2) and not is_trans:
							continue  # skip opaque +Y (greedy already emitted)
						
						if not is_trans:
							if GREEDY_TOPS_MODE > 0 and face_i == 2:
								continue
							if GREEDY_BOTTOMS and face_i == 3:
								continue
							if GREEDY_SIDES and (face_i == 0 or face_i == 1 or face_i == 4 or face_i == 5):
								continue

						var nrm = faces[face_i]
						var nx := x + int(nrm.x); var ny := y + int(nrm.y); var nz := z + int(nrm.z)
						var neighbor_id := BlockDB.BlockId.AIR
						if nx >= 0 and nx < CX and ny >= 0 and ny < CY and nz >= 0 and nz < CZ:
							neighbor_id = blocks[nx][ny][nz]
						if _face_hidden_fast(id, neighbor_id):
							continue

						var base := Vector3(x, y, z)
						var quad = face_vertices[face_i]
						var v0 = base + quad[0]
						var v1 = base + quad[1]
						var v2 = base + quad[2]
						var v3 = base + quad[3]

						var tile := BlockDB.get_face_tile(id, face_i)
						var uvs := BlockDB.tile_uvs(tile)  # once
						var uv0 := _chunk_uv_from_local_pre(face_i, quad[0], uvs)
						var uv1 := _chunk_uv_from_local_pre(face_i, quad[1], uvs)
						var uv2 := _chunk_uv_from_local_pre(face_i, quad[2], uvs)
						var uv3 := _chunk_uv_from_local_pre(face_i, quad[3], uvs)


						var dst = dst_opaque
						if is_trans: dst = dst_trans
						_push_quad(dst, [v0,v1,v2,v3], nrm, uv0, uv1, uv2, uv3)


	# ------- MICRO (notches) -------
	# Exactly like your rebuild, but append to dst arrays instead of SurfaceTool.
	for s in SECTION_COUNT:
		var y0 := s * SECTION_H
		var y1 = min(CY - 1, y0 + SECTION_H - 1)
		var dst_opaque = sections[s]["opaque"]
		var dst_trans  = sections[s]["trans"]

		for cell_lp in micro.keys():
			var p: Vector3i = cell_lp
			if p.y < y0 or p.y > y1:
				continue
			var a: PackedInt32Array = micro[p]
			if a.size() != 8:
				continue

			# Pack by base id → 8-bit mask (same as your code)
			var masks := {}
			for sub in 8:
				var base_id: int = int(a[sub])
				if base_id <= 0: continue
				var m := 0
				if masks.has(base_id): m = int(masks[base_id])
				m |= (1 << sub)
				masks[base_id] = m

			for base_id_key in masks.keys():
				var base_id := int(base_id_key)
				var mask := int(masks[base_id_key])
				var added := _emit_micro_faces_arrays(CX,CY,CZ, blocks, p, base_id, mask)
				# 'added' returns {"opaque":[v,n,uv], "trans":[v,n,uv]}
				var o = added["opaque"]; var t = added["trans"]
				# Append into dst_opaque/trans
				dst_opaque["v"].append_array(o["v"]); dst_opaque["n"].append_array(o["n"]); dst_opaque["uv"].append_array(o["uv"])
				dst_trans["v"].append_array(t["v"]);   dst_trans["n"].append_array(t["n"]);   dst_trans["uv"].append_array(t["uv"])

	# deliver to main thread
	var result := {"cpos": cpos, "sections": sections}
	_mesh_mutex.lock()
	_mesh_results.append(result)
	_mesh_mutex.unlock()

func _chunk_uv_from_local_pre(face_i:int, local:Vector3, uvs:Array) -> Vector2:
	var u0 := (uvs[0] as Vector2).x
	var v0 := (uvs[0] as Vector2).y
	var u1 := (uvs[2] as Vector2).x
	var v1 := (uvs[2] as Vector2).y
	var s := 0.0
	var t := 0.0
	match face_i:
		0: s = local.z;           t = 1.0 - local.y   # +X
		1: s = 1.0 - local.z;     t = 1.0 - local.y   # -X
		2: s = local.x;           t = 1.0 - local.z   # +Y (top)
		3: s = local.x;           t = local.z         # -Y (bottom)
		4: s = local.x;           t = 1.0 - local.y   # +Z
		5: s = 1.0 - local.x;     t = local.y         # -Z 
	return Vector2(lerpf(u0, u1, s), lerpf(v0, v1, t))


# --- helpers used by the worker ---

func _dist2_chunk_to_player(cpos: Vector3i) -> float:
	var p := _player.global_position
	var cx := float(cpos.x * CX)
	var cz := float(cpos.z * CZ)
	return (cx - p.x) * (cx - p.x) + (cz - p.z) * (cz - p.z)

func _chunk_uv_from_local(face_i:int, local:Vector3, tile:int) -> Vector2:
	# Same math as Chunk._uv_from_local, duplicated here (workers can’t call instance methods).
	var uvs := BlockDB.tile_uvs(tile)     # [TL, TR, BR, BL]
	var u0 := uvs[0].x; var v0 := uvs[0].y
	var u1 := uvs[2].x; var v1 := uvs[2].y
	var s := 0.0
	var t := 0.0
	match face_i:
		0: s = local.z;           t = 1.0 - local.y
		1: s = 1.0 - local.z;     t = 1.0 - local.y
		2: s = local.x;           t = 1.0 - local.z
		3: s = local.x;           t = local.z
		4: s = local.x;           t = 1.0 - local.y
		5: s = 1.0 - local.x;     t = local.y
	return Vector2(lerpf(u0, u1, s), lerpf(v0, v1, t))
	
func _has(m:int,sx:int,sy:int,sz:int)->bool:
	var idx := (sy << 2) | (sz << 1) | sx
	return ((m >> idx) & 1) == 1


func _emit_micro_faces_arrays(CX:int,CY:int,CZ:int, blocks:Array, cell_lp:Vector3i, base_id:int, mask:int) -> Dictionary:
	var faces := [
		Vector3( 1,0,0), Vector3(-1,0,0), Vector3(0,1,0),
		Vector3( 0,-1,0), Vector3(0,0,1), Vector3(0,0,-1)
	]
	var face_vertices := [
		[Vector3(1,0,0), Vector3(1,1,0), Vector3(1,1,1), Vector3(1,0,1)],
		[Vector3(0,0,1), Vector3(0,1,1), Vector3(0,1,0), Vector3(0,0,0)],
		[Vector3(0,1,1), Vector3(1,1,1), Vector3(1,1,0), Vector3(0,1,0)],
		[Vector3(0,0,0), Vector3(1,0,0), Vector3(1,0,1), Vector3(0,0,1)],
		[Vector3(0,0,1), Vector3(1,0,1), Vector3(1,1,1), Vector3(0,1,1)],
		[Vector3(0,1,0), Vector3(1,1,0), Vector3(1,0,0), Vector3(0,0,0)]
	]

	var out_o := {"v": PackedVector3Array(), "n": PackedVector3Array(), "uv": PackedVector2Array()}
	var out_t := {"v": PackedVector3Array(), "n": PackedVector3Array(), "uv": PackedVector2Array()}



	var size := 0.5
	var cell_origin := Vector3(cell_lp.x, cell_lp.y, cell_lp.z)

	for mz in 2:
		for my in 2:
			for mx in 2:
				if not _has(mask, mx,my,mz): continue
				var sub_origin := cell_origin + Vector3(mx * size, my * size, mz * size)

				for face_i in 6:
					var cull := false
					# A) sibling micro
					if face_i == 0 and mx + 1 < 2 and _has(mask,mx+1,my,mz): cull = true
					elif face_i == 1 and mx - 1 >= 0 and _has(mask,mx-1,my,mz): cull = true
					elif face_i == 2 and my + 1 < 2 and _has(mask,mx,my+1,mz): cull = true
					elif face_i == 3 and my - 1 >= 0 and _has(mask,mx,my-1,mz): cull = true
					elif face_i == 4 and mz + 1 < 2 and _has(mask,mx,my,mz+1): cull = true
					elif face_i == 5 and mz - 1 >= 0 and _has(mask,mx,my,mz-1): cull = true

					# B) neighbor macro cell
					if not cull:
						var nx := cell_lp.x
						var ny := cell_lp.y
						var nz := cell_lp.z
						var check := false
						if face_i == 0 and mx == 1: nx += 1; check = true
						elif face_i == 1 and mx == 0: nx -= 1; check = true
						elif face_i == 2 and my == 1: ny += 1; check = true
						elif face_i == 3 and my == 0: ny -= 1; check = true
						elif face_i == 4 and mz == 1: nz += 1; check = true
						elif face_i == 5 and mz == 0: nz -= 1; check = true

						if check and nx>=0 and nx<CX and ny>=0 and ny<CY and nz>=0 and nz<CZ:
							var neighbor_id = blocks[nx][ny][nz]
							if _face_hidden_fast(base_id, neighbor_id):
								cull = true

					if cull: continue

					var quad = face_vertices[face_i]
					var v0 = sub_origin + quad[0] * size
					var v1 = sub_origin + quad[1] * size
					var v2 = sub_origin + quad[2] * size
					var v3 = sub_origin + quad[3] * size
					var nrm = faces[face_i]
					var tile := BlockDB.get_face_tile(base_id, face_i)
					var uvs := BlockDB.tile_uvs(tile)

					# Use copies of the local quad verts for UVs (don’t touch geometry).
					var l0 = quad[0]
					var l1 = quad[1]
					var l2 = quad[2]
					var l3 = quad[3]

					# Flip V only for -Z so micro faces match big-block mapping.
					if face_i == 5:
						l0.y = 1.0 - l0.y
						l1.y = 1.0 - l1.y
						l2.y = 1.0 - l2.y
						l3.y = 1.0 - l3.y

					var uv0 := _chunk_uv_from_local_pre(face_i, l0, uvs)
					var uv1 := _chunk_uv_from_local_pre(face_i, l1, uvs)
					var uv2 := _chunk_uv_from_local_pre(face_i, l2, uvs)
					var uv3 := _chunk_uv_from_local_pre(face_i, l3, uvs)



					var dst := out_o
					if BlockDB.is_transparent(base_id):
						dst = out_t
					_push_quad(dst, [v0,v1,v2,v3], nrm, uv0, uv1, uv2, uv3)

	return {"opaque": out_o, "trans": out_t}


func _player_chunk() -> Vector3i:
	var p := _player.global_position
	return Vector3i(floori(p.x / CX), 0, floori(p.z / CZ))

func _update_chunks_around_player(force_full: bool=false) -> void:
	var center: Vector3i = _player_chunk()

	var wanted_spawn: Dictionary = {} # inside PRELOAD_RADIUS → must exist
	var wanted_keep: Dictionary = {}  # inside DESPAWN_RADIUS → do not despawn yet

	for dz in range(-DESPAWN_RADIUS, DESPAWN_RADIUS + 1):
		for dx in range(-DESPAWN_RADIUS, DESPAWN_RADIUS + 1):
			var cpos := Vector3i(center.x + dx, 0, center.z + dz)
			if abs(dx) <= PRELOAD_RADIUS and abs(dz) <= PRELOAD_RADIUS:
				wanted_spawn[cpos] = true
			if abs(dx) <= DESPAWN_RADIUS and abs(dz) <= DESPAWN_RADIUS:
				wanted_keep[cpos] = true

	# Spawn inside preload radius
	for cpos in wanted_spawn.keys():
		if not chunks.has(cpos):
			if not _spawn_queue.has(cpos):
				_spawn_queue.append(cpos)

	# Despawn only outside DESPAWN_RADIUS
	var to_remove: Array[Vector3i] = []
	for cpos_key in chunks.keys():
		var cpos_rm: Vector3i = cpos_key
		if not wanted_keep.has(cpos_rm):
			to_remove.append(cpos_rm)
	for cpos_rm in to_remove:
		despawn_chunk(cpos_rm)

	# Collision ring with hysteresis
	_set_collision_rings(center)

	# Optional warm start
	if force_full:
		for cpos_key in chunks.keys():
			var ch_full: Chunk = chunks[cpos_key]
			_queue_rebuild(ch_full)

func _set_collision_rings(center: Vector3i) -> void:
	for c in chunks.values():
		var dx = abs(c.chunk_pos.x - center.x)
		var dz = abs(c.chunk_pos.z - center.z)

		var enter = (dx <= COLLISION_ON_RADIUS and dz <= COLLISION_ON_RADIUS)
		var exit_far = (dx > COLLISION_OFF_RADIUS or dz > COLLISION_OFF_RADIUS)

		# Turn ON: if we have a mesh but no shape, create the collider NOW.
		if enter:
			c.wants_collision = true
			if c.collision_shape.shape == null:
				var m = c.mesh_instance.mesh
				if m != null and m.get_surface_count() > 0:
					_queue_collider_build(c)
					#c._set_collision_after_mesh(m)  # immediate; no defer when near
		else:
			# Inside the middle band: keep whatever collider we have (hysteresis).
			pass

		# Turn OFF only when safely far
		if exit_far:
			c.wants_collision = false
			# Optional: free the shape to save memory
			if c.collision_shape.shape != null:
				c.collision_shape.shape = null


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
		
		# If we have a ready mesh/shape, attach & skip heavy work
		if _mesh_cache_try_restore(c):
			# Optional: still do micro terrain smoothing if your cache predates it.
			# Otherwise, we’re done.
			continue


		# Try restoring from cache; if hit, skip generation
		if _try_restore_from_cache(c):
			_seed_micro_slopes_terrain(c)
			_queue_rebuild(c)
		else:
			# Generation will be done on worker thread
			_gen_queue.append(c)

func _drain_gen_queue(max_count: int) -> void:
	if _gen_queue.size() == 0:
		return

	# Nearest-first
	var p: Vector3 = _player.global_position
	_gen_queue.sort_custom(func(a, b):
		return a.position.distance_squared_to(p) < b.position.distance_squared_to(p)
	)

	var n: int = min(max_count, _gen_queue.size())
	var started := 0
	for i in n:
		if GEN_TASK_CONCURRENCY > 0 and _gen_tasks.size() >= GEN_TASK_CONCURRENCY:
			break  # don't flood the pool this frame

		var c: Chunk = _gen_queue.pop_front()
		if c == null or not is_instance_valid(c) or c.pending_kill:
			continue

		_start_gen_task(c)  # ← run generation off-thread
		started += 1

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
		_add_to_cache(cpos, c.snapshot_data())
		c.pending_kill = true
		_remove_from_queues_by_chunk(c)
		_mesh_cache_put(cpos, c.snapshot_mesh_and_data())
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

func _mesh_cache_touch(cpos: Vector3i) -> void:
	_mesh_lru.erase(cpos)
	_mesh_lru.push_front(cpos)

func _mesh_cache_put(cpos: Vector3i, snap: Dictionary) -> void:
	if not MESH_CACHE_STORE_MESH and snap.has("mesh"):
		snap.erase("mesh")
	if not MESH_CACHE_STORE_SHAPE and snap.has("shape"):
		snap.erase("shape")
	_mesh_cache[cpos] = snap
	_mesh_cache_touch(cpos)
	while _mesh_lru.size() > MESH_CACHE_LIMIT:
		var old: Vector3i = _mesh_lru.pop_back()
		_mesh_cache.erase(old)

func _mesh_cache_try_restore(c: Chunk) -> bool:
	var cpos := c.chunk_pos
	if not _mesh_cache.has(cpos):
		return false

	var snap: Dictionary = _mesh_cache[cpos]
	_mesh_cache_touch(cpos)

	if not snap.has("mesh"):
		return false
	var m = snap["mesh"]
	if m == null:
		return false
	if not (m is ArrayMesh):
		return false
	if (m as ArrayMesh).get_surface_count() <= 0:
		return false

	c.apply_snapshot_with_mesh(snap)
	return true


# =========================================================
# Deterministic helpers / noise utils
# =========================================================
func _try_restore_from_cache(c: Chunk) -> bool:
	var cpos := c.chunk_pos
	if not _chunk_cache.has(cpos):
		return false
	var snap: Dictionary = _chunk_cache[cpos]
	c.apply_snapshot(snap)
	_touch_cache_lru(cpos)
	return true

func _add_to_cache(cpos: Vector3i, snap: Dictionary) -> void:
	_chunk_cache[cpos] = snap
	_touch_cache_lru(cpos)
	while _cache_lru.size() > CACHE_LIMIT:
		var old = _cache_lru.pop_back()
		_chunk_cache.erase(old)

func _touch_cache_lru(cpos: Vector3i) -> void:
	_cache_lru.erase(cpos)
	_cache_lru.push_front(cpos)


func _drain_gen_results(max_count: int) -> void:
	var batch: Array = []
	_gen_mutex.lock()
	var n = min(max_count, _gen_results.size())
	for i in n:
		batch.append(_gen_results.pop_front())
	_gen_mutex.unlock()

	for r in batch:
		var cpos: Vector3i = r["cpos"]
		_gen_tasks.erase(cpos)

		if not chunks.has(cpos):
			_add_to_cache(cpos, r)
			continue

		var c: Chunk = chunks[cpos]
		if c == null or not is_instance_valid(c) or c.pending_kill:
			continue

		# Adopt raw data
		c.blocks = r["blocks"]
		c.heightmap_top_solid = r["heightmap"]
		for s in c.SECTION_COUNT:
			c.section_dirty[s] = 1
		c.dirty = true

		var dx = abs(c.chunk_pos.x - _player_chunk().x)
		var dz = abs(c.chunk_pos.z - _player_chunk().z)
		var near = dx <= COLLISION_ON_RADIUS + 1 and dz <= COLLISION_ON_RADIUS + 1

		if near:
			# FAST FIRST: skip beautify; get ground/collider ASAP
			_start_mesh_task(c)
			# schedule beautify later
			if not _beautify_queue.has(c):
				_beautify_queue.append(c)
		else:
			_start_mesh_task(c)
			if not _beautify_queue.has(c):
				_beautify_queue.append(c)


func _start_gen_task(c: Chunk) -> void:
	var cpos := c.chunk_pos
	if _gen_tasks.has(cpos):
		return
	_gen_tasks[cpos] = true

	# Pack noise settings so worker can recreate local noises safely
	var np := {
		"height": {"type": height_noise.noise_type, "oct": height_noise.fractal_octaves, "freq": height_noise.frequency, "seed": height_noise.seed},
		"tree":   {"type": tree_noise.noise_type,   "oct": tree_noise.fractal_octaves,   "freq": tree_noise.frequency,   "seed": tree_noise.seed},
		"leaf":   {"type": leaf_noise.noise_type,   "oct": leaf_noise.fractal_octaves,   "freq": leaf_noise.frequency,   "seed": leaf_noise.seed}
	}
	var payload := {
		"cpos": cpos,
		"CX": CX, "CY": CY, "CZ": CZ,
		"noise": np
	}
	WorkerThreadPool.add_task(Callable(self, "_gen_worker").bind(payload))

func _make_noise(np: Dictionary) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = np["type"]
	n.fractal_octaves = np["oct"]
	n.frequency = np["freq"]
	n.seed = np["seed"]
	return n

func _gen_worker(payload: Dictionary) -> void:
	# Recreate local noises (thread-safe)
	var cpos: Vector3i = payload["cpos"]
	var CX_: int = int(payload["CX"]); var CY_: int = int(payload["CY"]); var CZ_: int = int(payload["CZ"])
	var hn := _make_noise(payload["noise"]["height"])
	var tn := _make_noise(payload["noise"]["tree"])
	var ln := _make_noise(payload["noise"]["leaf"])

	# Allocate arrays
	var blocks: Array = []
	blocks.resize(CX_)
	for x in CX_:
		var col := []
		col.resize(CY_)
		for y in CY_:
			var stack := []
			stack.resize(CZ_)
			for z in CZ_:
				stack[z] = BlockDB.BlockId.AIR
			col[y] = stack
		blocks[x] = col

	var heightmap := PackedInt32Array()
	heightmap.resize(CX_ * CZ_)

	var trees: Array = []   # each: {"at": Vector3i, "height": int}

	var base_x := cpos.x * CX_
	var base_z := cpos.z * CZ_

	for x in CX_:
		for z in CZ_:
			var wx := base_x + x
			var wz := base_z + z

			var h_f := remap(hn.get_noise_2d(wx, wz), -1.0, 1.0, float(SURFACE_MIN), float(SURFACE_MAX))
			var h = clamp(int(round(h_f)), 1, CY_ - 2)
			heightmap[x * CZ_ + z] = h - 1

			for y in range(0, h):
				var id := BlockDB.BlockId.DIRT
				if y == h - 1:
					id = BlockDB.BlockId.GRASS
				elif y < h - 10:
					id = BlockDB.BlockId.STONE
				blocks[x][y][z] = id

			# Trees (no notches here; we'll decorate on main thread)
			var place_val := 0.5 * (tn.get_noise_2d(wx, wz) + 1.0)
			if place_val > 0.80:
				var hval := 0.5 * (tn.get_noise_2d(wx + 12345, wz - 54321) + 1.0)
				var t_height := 4 + int(round(hval * 2.0))
				# require grass under trunk
				if blocks[x][h - 1][z] == BlockDB.BlockId.GRASS:
					# trunk
					for i in t_height:
						var py = h + i
						if py >= CY_: break
						blocks[x][py][z] = BlockDB.BlockId.LOG
					# crown
					var top_y = h + t_height
					for dx in range(-2, 3):
						for dy in range(-2, 2):
							for dz in range(-2, 3):
								var px := x + dx
								var py = top_y + dy
								var pz := z + dz
								if px < 0 or px >= CX_ or py < 0 or py >= CY_ or pz < 0 or pz >= CZ_:
									continue
								var dist := Vector3(abs(dx), abs(dy) * 1.3, abs(dz)).length()
								if dist <= 2.6:
									var keep := 0.5 * (ln.get_noise_3d(float(wx + dx * 97), float(top_y + dy * 57), float(wz + dz * 131)) + 1.0)
									if keep > 0.15 and blocks[px][py][pz] == BlockDB.BlockId.AIR:
										blocks[px][py][pz] = BlockDB.BlockId.LEAVES
					trees.append({"at": Vector3i(x, h, z), "height": t_height})

	# publish result to main thread
	var result := {"cpos": cpos, "blocks": blocks, "heightmap": heightmap, "trees": trees}
	_gen_mutex.lock()
	_gen_results.append(result)
	_gen_mutex.unlock()


func _queue_rebuild(c: Chunk) -> void:
	if c == null: return
	if not is_instance_valid(c): return
	if not _rebuild_queue.has(c):
		_rebuild_queue.append(c)

func _start_mesh_task(c: Chunk) -> void:
	if MESH_TASK_CONCURRENCY > 0 and _mesh_tasks.size() >= MESH_TASK_CONCURRENCY:
		if not _rebuild_queue.has(c):
			_rebuild_queue.push_front(c)
		return

	var cpos := c.chunk_pos
	if _mesh_tasks.has(cpos):
		return
	_mesh_tasks[cpos] = true

	# NEW: mark snapshot point. Any edits after this set dirty back to true.
	c.dirty = false

	var snap := c.snapshot_mesh_and_data()
	snap.erase("mesh")
	snap.erase("shape")
	snap["cpos"] = cpos
	snap["CX"] = Chunk.CX
	snap["CY"] = Chunk.CY
	snap["CZ"] = Chunk.CZ
	snap["section_count"] = Chunk.SECTION_COUNT
	snap["section_h"] = Chunk.SECTION_H

	WorkerThreadPool.add_task(Callable(self, "_mesh_worker").bind(snap))

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
		if c == null or not is_instance_valid(c) or c.pending_kill:
			continue
		if not c.dirty:
			continue
		_start_mesh_task(c)

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

			var h_f: float = remap(height_noise.get_noise_2d(wx, wz), -1.0, 1.0, float(SURFACE_MIN), float(SURFACE_MAX))
			var h: int = clamp(int(round(h_f)), 1, Chunk.CY - 2)

			for y in range(0, h):
				var id: int = BlockDB.BlockId.DIRT
				if y == h - 1:
					id = BlockDB.BlockId.GRASS
				elif y < h - 5:
					id = BlockDB.BlockId.STONE
				c.set_block(Vector3i(x, y, z), id)

			c.heightmap_set_top(x, z, h - 1)
			
			# Trees...
			var place_val: float = _n2d01(tree_noise, wx, wz)
			if place_val > 0.80:
				var hval: float = _n2d01(tree_noise, wx + 12345, wz - 54321)
				var t_height: int = 4 + int(round(hval * 2.0))
				_place_tree_deterministic(c, Vector3i(x, h, z), t_height, wx, wz)

			# Update cached top solid per (x,z)



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
	var CXv:int = Chunk.CX
	var CYv:int = Chunk.CY
	var CZv:int = Chunk.CZ

	var base_x:int = c.chunk_pos.x * CXv
	var base_z:int = c.chunk_pos.z * CZv

	var blocks:Array = c.blocks
	var hm:PackedInt32Array = c.heightmap_top_solid

	var idx:int
	var y0:int
	var id0:int
	var lp_above:Vector3i
	var placed:bool
	var gate_val:float

	for x in CXv:
		for z in CZv:
			idx = x * CZv + z
			y0 = hm[idx]
			if y0 < 0:
				continue

			id0 = blocks[x][y0][z]
			if not _is_terrain(id0):
				continue

			gate_val = micro_noise.get_noise_2d(base_x + x, base_z + z)
			if gate_val < MICRO_TERRAIN_GATE:
				continue

			lp_above = Vector3i(x, y0 + 1, z)
			if lp_above.y >= CYv:
				continue
			if blocks[lp_above.x][lp_above.y][lp_above.z] != BlockDB.BlockId.AIR:
				continue

			placed = false

			# Use heightmap neighbors (O(1)) instead of scanning
			if x + 1 < CXv and (hm[(x + 1) * CZv + z] - y0) == 1:
				c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 0), id0)
				c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 1), id0)
				placed = true

			if x - 1 >= 0 and (hm[(x - 1) * CZv + z] - y0) == 1:
				c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 0), id0)
				c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 1), id0)
				placed = true

			if z + 1 < CZv and (hm[x * CZv + (z + 1)] - y0) == 1:
				c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 1), id0)
				c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 1), id0)
				placed = true

			if z - 1 >= 0 and (hm[x * CZv + (z - 1)] - y0) == 1:
				c.set_micro_sub(lp_above, Chunk._sub_index(0, 0, 0), id0)
				c.set_micro_sub(lp_above, Chunk._sub_index(1, 0, 0), id0)
				placed = true

			if placed:
				c.dirty = true
			
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
		var samples: int = 8

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
	_queue_rebuild(c)
	#c.rebuild_mesh()

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
	_queue_rebuild(c)
	#c.rebuild_mesh()


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
