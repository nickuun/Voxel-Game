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

func _ready():
	#rng.randomize()
	atlas = load(BlockDB.ATLAS_PATH)
	BlockDB.configure_from_texture(atlas)
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_octaves = 3
	noise.frequency = 0.01

	generate_initial_area()
	
func _process(dt: float) -> void:
	_tick_accum += dt
	if _tick_accum >= 0.5:
		_world_tick()
		_tick_accum = 0.0
		
# Treat leaves as “let light through” so grass survives under trees
func _opaque_for_light(id:int) -> bool:
	return BlockDB.is_opaque(id) and id != BlockDB.BlockId.LEAVES

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
			generate_chunk_blocks(chunks[cpos])
			chunks[cpos].rebuild_mesh()

func spawn_chunk(cpos:Vector3i):
	if chunks.has(cpos): return
	var c := Chunk.new()
	add_child(c)
	c.position = Vector3(cpos.x*CX, 0, cpos.z*CZ)
	c.setup(cpos, atlas)
	chunks[cpos] = c

func generate_chunk_blocks(c: Chunk) -> void:
	var base_x := c.chunk_pos.x * CX
	var base_z := c.chunk_pos.z * CZ

	for x in CX:
		for z in CZ:
			var wx := base_x + x
			var wz := base_z + z
			var h := int(remap(noise.get_noise_2d(wx, wz), -1, 1, 20, 40))
			h = clamp(h, 1, Chunk.CY - 1)

			for y in range(0, h):
				var id: int = BlockDB.BlockId.DIRT
				if y == h - 1:
					id = BlockDB.BlockId.GRASS
				elif y < h - 5:
					id = BlockDB.BlockId.STONE
				c.set_block(Vector3i(x, y, z), id)
				
			# sprinkle trees (1 in ~32 columns), only if there’s space
			if rng.randi() % 32 == 0:
				_place_tree(c, Vector3i(x, h, z))


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
