extends Node3D
class_name Chunk

const CX := 16
const CY := 128
const CZ := 16

var chunk_pos: Vector3i            # chunk grid coords (cx, cy, cz) — we’ll keep cy=0 for heightmap world
var blocks: Array                   # blocks[x][y][z] -> int BlockId
var dirty := true

@onready var mesh_instance := MeshInstance3D.new()
@onready var collider := StaticBody3D.new()
@onready var collision_shape := CollisionShape3D.new()

var atlas_tex: Texture2D
var material: StandardMaterial3D

const SECTION_H: int = 16
const SECTION_COUNT: int = CY / SECTION_H

var wants_collision: bool = true
var pending_kill: bool = false

# Cached top solid Y for each (x,z) column; -1 means empty
var heightmap_top_solid: PackedInt32Array = PackedInt32Array()

# Optional per-section dirtiness (used by world to mark edits)
var section_dirty: PackedByteArray = PackedByteArray()		# 0/1 per section

# (Optional) could be used later for micro-aware culling if needed
# simple counters to know if a section has any micro voxels
var micro_section_counts: PackedInt32Array = PackedInt32Array()


# 2x2x2 micro-voxels per cell. Stored only where needed.
# Key = Vector3i(local_x, local_y, local_z)
# Value = PackedInt32Array length 8; each entry = base block id (or 0 if empty)
var micro := {}  # Dictionary<Vector3i, PackedInt32Array]

func _ready():
	add_child(mesh_instance)
	add_child(collider)
	collider.add_child(collision_shape)

func setup(chunk_pos_:Vector3i, atlas:Texture2D):
	chunk_pos = chunk_pos_
	atlas_tex = atlas
	material = StandardMaterial3D.new()
	material.albedo_texture = atlas_tex
	material.roughness = 1.0
	# To avoid blurry UVs:
	if atlas_tex is Texture2D:
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	blocks = []
	for x in CX:
		var col := []
		for y in CY:
			var stack := []
			for z in CZ:
				stack.append(BlockDB.BlockId.AIR)
			col.append(stack)
		blocks.append(col)
	dirty = true

# sub index layout: bit0=x (0..1), bit1=z (0..1), bit2=y (0..1)
#static func _sub_index(ix:int, iy:int, iz:int) -> int:
	#return (iy << 2) | (iz << 1) | ix
	
func reuse_setup(chunk_pos_: Vector3i, atlas: Texture2D) -> void:
	chunk_pos = chunk_pos_
	atlas_tex = atlas

	if material == null:
		material = StandardMaterial3D.new()
	material.albedo_texture = atlas_tex
	material.roughness = 1.0
	if atlas_tex is Texture2D:
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	# Allocate block grid
	blocks = []
	for x in CX:
		var col: Array = []
		for y in CY:
			var stack: Array = []
			for z in CZ:
				stack.append(BlockDB.BlockId.AIR)
			col.append(stack)
		blocks.append(col)

	# Clear micro dict
	micro.clear()

	# Clear mesh & collider
	mesh_instance.mesh = null
	collision_shape.shape = null

	# Heightmap + per-section flags
	heightmap_top_solid = PackedInt32Array()
	heightmap_top_solid.resize(CX * CZ)
	for i in heightmap_top_solid.size():
		heightmap_top_solid[i] = -1

	section_dirty = PackedByteArray()
	section_dirty.resize(SECTION_COUNT)
	for s in SECTION_COUNT:
		section_dirty[s] = 1	# dirty on first build

	micro_section_counts = PackedInt32Array()
	micro_section_counts.resize(SECTION_COUNT)
	for s in SECTION_COUNT:
		micro_section_counts[s] = 0

	dirty = true
	wants_collision = true
	pending_kill = false

func prepare_for_pool() -> void:
	# Keep arrays allocated but make it inert; keeps node reusable
	dirty = false
	wants_collision = false
	mesh_instance.mesh = null
	collision_shape.shape = null

func set_active(enable: bool) -> void:
	visible = enable
	set_process(enable)

static func _hm_index(x: int, z: int) -> int:
	return x * CZ + z

func heightmap_set_top(x: int, z: int, top_y: int) -> void:
	var idx: int = _hm_index(x, z)
	if idx >= 0 and idx < heightmap_top_solid.size():
		heightmap_top_solid[idx] = top_y

func update_heightmap_column(x: int, z: int) -> void:
	var top: int = -1
	for y in range(CY - 1, -1, -1):
		var id: int = get_block(Vector3i(x, y, z))
		if id != BlockDB.BlockId.AIR:
			top = y
			break
	heightmap_set_top(x, z, top)

func mark_section_dirty_for_local_y(y: int) -> void:
	if y < 0:
		return
	var s: int = y / SECTION_H
	if s >= 0 and s < SECTION_COUNT:
		section_dirty[s] = 1
	dirty = true


func get_micro_cell(lp: Vector3i) -> PackedInt32Array:
	if micro.has(lp): return micro[lp]
	return PackedInt32Array([])

func _ensure_micro_cell(lp: Vector3i) -> PackedInt32Array:
	var a := get_micro_cell(lp)
	if a.size() != 8:
		a = PackedInt32Array([0,0,0,0,0,0,0,0])
		micro[lp] = a
	return a

func set_micro_sub(lp: Vector3i, sub: int, base_id: int) -> void:
	if not index_in_bounds(lp.x, lp.y, lp.z):
		return
	var a: PackedInt32Array = _ensure_micro_cell(lp)
	var prev: int = a[sub]
	a[sub] = base_id
	micro[lp] = a
	dirty = true
	mark_section_dirty_for_local_y(lp.y)
	if prev == 0 and base_id != 0:
		var s: int = lp.y / SECTION_H
		if s >= 0 and s < SECTION_COUNT:
			micro_section_counts[s] = micro_section_counts[s] + 1

func clear_micro_sub(lp: Vector3i, sub: int) -> void:
	if not micro.has(lp):
		return
	var a: PackedInt32Array = micro[lp]
	var prev: int = a[sub]
	a[sub] = 0
	var any: bool = false
	for v in a:
		if v != 0:
			any = true
			break
	if any:
		micro[lp] = a
	else:
		micro.erase(lp)
	dirty = true
	mark_section_dirty_for_local_y(lp.y)
	if prev != 0:
		var s: int = lp.y / SECTION_H
		if s >= 0 and s < SECTION_COUNT:
			micro_section_counts[s] = max(0, micro_section_counts[s] - 1)

static func index_in_bounds(x:int,y:int,z:int) -> bool:
	return x>=0 and x<CX and y>=0 and y<CY and z>=0 and z<CZ

func set_block(local: Vector3i, id: int) -> void:
	if not index_in_bounds(local.x, local.y, local.z):
		return
	blocks[local.x][local.y][local.z] = id
	dirty = true
	if id != BlockDB.BlockId.AIR:
		heightmap_raise_if_higher_local(local)


func get_block(local:Vector3i) -> int:
	if not index_in_bounds(local.x, local.y, local.z): return BlockDB.BlockId.AIR
	return blocks[local.x][local.y][local.z]

func _uv_from_local(face_i:int, local:Vector3, tile:int) -> Vector2:
	var uvs := BlockDB.tile_uvs(tile)     # [TL, TR, BR, BL]
	var u0 := uvs[0].x; var v0 := uvs[0].y
	var u1 := uvs[2].x; var v1 := uvs[2].y

	var s := 0.0  # horizontal 0..1
	var t := 0.0  # vertical   0..1 (t=0 is top of the image)

	match face_i:
		0: s = local.z;           t = 1.0 - local.y      # +X
		1: s = 1.0 - local.z;     t = 1.0 - local.y      # -X
		2: s = local.x;           t = 1.0 - local.z      # +Y (top)
		3: s = local.x;           t = local.z            # -Y (bottom)
		4: s = local.x;           t = 1.0 - local.y      # +Z
		5: s = 1.0 - local.x;     t = 1.0 - local.y      # -Z

	return Vector2(lerpf(u0, u1, s), lerpf(v0, v1, t))
	
func rebuild_mesh() -> void:
	if not dirty:
		return

	# Materials (opaque + transparent)
	var mat_opaque: Material = material
	var mat_trans: StandardMaterial3D
	if material is StandardMaterial3D:
		mat_trans = (material as StandardMaterial3D).duplicate()
	else:
		var m: StandardMaterial3D = StandardMaterial3D.new()
		mat_opaque = m
		mat_trans = m.duplicate()
	mat_trans.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var mesh: ArrayMesh = ArrayMesh.new()

	# Build per section (reduces working set and lets us skip empty tops)
	for s in SECTION_COUNT:
		var y0: int = s * SECTION_H
		var y1: int = min(CY - 1, y0 + SECTION_H - 1)

		# Surface builders for this section
		var st_opaque: SurfaceTool = SurfaceTool.new()
		st_opaque.begin(Mesh.PRIMITIVE_TRIANGLES)
		st_opaque.set_material(mat_opaque)

		var st_trans: SurfaceTool = SurfaceTool.new()
		st_trans.begin(Mesh.PRIMITIVE_TRIANGLES)
		st_trans.set_material(mat_trans)

		var had_opaque: bool = false
		var had_trans: bool = false

		# Static face data
		var faces: Array = [
			Vector3( 1, 0, 0),  # +X
			Vector3(-1, 0, 0),  # -X
			Vector3( 0, 1, 0),  # +Y
			Vector3( 0,-1, 0),  # -Y
			Vector3( 0, 0, 1),  # +Z
			Vector3( 0, 0,-1)   # -Z
		]
		var face_vertices: Array = [
			[Vector3(1,0,0), Vector3(1,1,0), Vector3(1,1,1), Vector3(1,0,1)],  # +X
			[Vector3(0,0,1), Vector3(0,1,1), Vector3(0,1,0), Vector3(0,0,0)],  # -X
			[Vector3(0,1,1), Vector3(1,1,1), Vector3(1,1,0), Vector3(0,1,0)],  # +Y
			[Vector3(0,0,0), Vector3(1,0,0), Vector3(1,0,1), Vector3(0,0,1)],  # -Y
			[Vector3(0,0,1), Vector3(1,0,1), Vector3(1,1,1), Vector3(0,1,1)],  # +Z
			[Vector3(0,1,0), Vector3(1,1,0), Vector3(1,0,0), Vector3(0,0,0)]   # -Z
		]

		# --------------- BIG (full) blocks within this section ---------------
		for x in CX:
			for z in CZ:
				var top: int = heightmap_top_solid[_hm_index(x, z)]
				if top < y0:
					continue
				var y_max: int = min(top, y1)
				for y in range(y0, y_max + 1):
					var id: int = blocks[x][y][z]
					if id == BlockDB.BlockId.AIR:
						continue

					for face_i in 6:
						var npos: Vector3i = Vector3i(x, y, z) + Vector3i(faces[face_i])
						var neighbor_id: int = BlockDB.BlockId.AIR
						if index_in_bounds(npos.x, npos.y, npos.z):
							neighbor_id = blocks[npos.x][npos.y][npos.z]
						if BlockDB.face_hidden_by_neighbor(id, neighbor_id):
							continue

						var base: Vector3 = Vector3(x, y, z)
						var quad: Array = face_vertices[face_i]
						var normal: Vector3 = faces[face_i]
						var tile: int = BlockDB.get_face_tile(id, face_i)

						var v0: Vector3 = base + (quad[0] as Vector3)
						var v1: Vector3 = base + (quad[1] as Vector3)
						var v2: Vector3 = base + (quad[2] as Vector3)
						var v3: Vector3 = base + (quad[3] as Vector3)

						var uv0: Vector2 = _uv_from_local(face_i, quad[0], tile)
						var uv1: Vector2 = _uv_from_local(face_i, quad[1], tile)
						var uv2: Vector2 = _uv_from_local(face_i, quad[2], tile)
						var uv3: Vector2 = _uv_from_local(face_i, quad[3], tile)

						var st_target: SurfaceTool = st_opaque
						if BlockDB.is_transparent(id):
							st_target = st_trans

						st_target.set_normal(normal); st_target.set_uv(uv0); st_target.add_vertex(v0)
						st_target.set_normal(normal); st_target.set_uv(uv2); st_target.add_vertex(v2)
						st_target.set_normal(normal); st_target.set_uv(uv1); st_target.add_vertex(v1)

						st_target.set_normal(normal); st_target.set_uv(uv0); st_target.add_vertex(v0)
						st_target.set_normal(normal); st_target.set_uv(uv3); st_target.add_vertex(v3)
						st_target.set_normal(normal); st_target.set_uv(uv2); st_target.add_vertex(v2)

						if st_target == st_opaque:
							had_opaque = true
						else:
							had_trans = true

		# --------------- MICRO (notch) voxels in this section ---------------
		for lp in micro.keys():
			var cell_lp: Vector3i = lp
			if cell_lp.y < y0 or cell_lp.y > y1:
				continue

			var a: PackedInt32Array = micro[cell_lp]
			if a.size() != 8:
				continue

			var masks: Dictionary = {}  # base_id -> 8-bit mask
			for sub in 8:
				var base_id: int = int(a[sub])
				if base_id <= 0:
					continue
				var current_mask: int = 0
				if masks.has(base_id):
					current_mask = int(masks[base_id])
				current_mask |= (1 << sub)
				masks[base_id] = current_mask

			for base_id_key in masks.keys():
				var mask: int = int(masks[base_id_key])
				var added: Dictionary = _emit_micro_faces(st_opaque, st_trans, cell_lp, int(base_id_key), mask)
				if added.has("opaque") and bool(added["opaque"]):
					had_opaque = true
				if added.has("trans") and bool(added["trans"]):
					had_trans = true

		# --------------- Commit this section's surfaces ---------------
		if had_opaque:
			st_opaque.commit(mesh)
		if had_trans:
			st_trans.commit(mesh)

		section_dirty[s] = 0

	# Assign mesh
	mesh_instance.mesh = mesh

	# Defer collider creation to avoid same-frame spikes
	call_deferred("_set_collision_after_mesh", mesh)

	dirty = false

func _set_collision_after_mesh(mesh: ArrayMesh) -> void:
	if wants_collision and mesh != null and mesh.get_surface_count() > 0:
		collision_shape.shape = mesh.create_trimesh_shape()
	else:
		collision_shape.shape = null

func heightmap_raise_if_higher(x: int, z: int, y: int) -> void:
	var idx: int = _hm_index(x, z)
	if idx < 0:
		return
	if idx >= heightmap_top_solid.size():
		return
	var cur: int = heightmap_top_solid[idx]
	if y > cur:
		heightmap_top_solid[idx] = y

func heightmap_raise_if_higher_local(lp: Vector3i) -> void:
	if not index_in_bounds(lp.x, lp.y, lp.z):
		return
	heightmap_raise_if_higher(lp.x, lp.z, lp.y)



# Emit geometry for a 2×2×2 "micro" cube set inside a single voxel cell.
# - cell_lp: the parent cell (local chunk coords)
# - notch_id: the notch item id (we resolve its base block for textures/flags)
# - mask: 8-bit occupancy of subcells (bit 0..7 for (x,y,z) in {0,1}³)
# Returns {"opaque": bool, "trans": bool} to help the caller decide whether to commit surfaces.
# Emit geometry for a 2×2×2 “micro” set inside a single voxel cell.
# - cell_lp: parent cell (local chunk coords)
# - base_id: regular block id to skin these micro-cubes with
# - mask: 8-bit occupancy (bits 0..7 for (x,y,z) in {0,1}³)
# Returns {"opaque": bool, "trans": bool}
func _emit_micro_faces(
		st_opaque: SurfaceTool,
		st_trans: SurfaceTool,
		cell_lp: Vector3i,
		base_id: int,
		mask: int
	) -> Dictionary:
	var added_opaque: bool = false
	var added_trans: bool = false

	if base_id <= 0:
		return {"opaque": false, "trans": false}

	# Face normals and per-face quad verts in 0..1 block space
	var faces: Array[Vector3] = [
		Vector3( 1, 0, 0),  # +X
		Vector3(-1, 0, 0),  # -X
		Vector3( 0, 1, 0),  # +Y
		Vector3( 0,-1, 0),  # -Y
		Vector3( 0, 0, 1),  # +Z
		Vector3( 0, 0,-1)   # -Z
	]
	var face_vertices: Array = [
		[Vector3(1,0,0), Vector3(1,1,0), Vector3(1,1,1), Vector3(1,0,1)],  # +X
		[Vector3(0,0,1), Vector3(0,1,1), Vector3(0,1,0), Vector3(0,0,0)],  # -X
		[Vector3(0,1,1), Vector3(1,1,1), Vector3(1,1,0), Vector3(0,1,0)],  # +Y
		[Vector3(0,0,0), Vector3(1,0,0), Vector3(1,0,1), Vector3(0,0,1)],  # -Y
		[Vector3(0,0,1), Vector3(1,0,1), Vector3(1,1,1), Vector3(0,1,1)],  # +Z
		[Vector3(0,1,0), Vector3(1,1,0), Vector3(1,0,0), Vector3(0,0,0)]   # -Z
	]

	var size: float = 0.5
	var cell_origin: Vector3 = Vector3(cell_lp.x, cell_lp.y, cell_lp.z)

	for mz in 2:
		for my in 2:
			for mx in 2:
				if not _micro_has(mask, mx, my, mz):
					continue

				var sub_origin: Vector3 = cell_origin + Vector3(mx * size, my * size, mz * size)

				for face_i in 6:
					var normal: Vector3 = faces[face_i]
					var cull: bool = false

					# (A) cull against sibling micro in same parent cell
					if face_i == 0:
						if mx + 1 < 2 and _micro_has(mask, mx + 1, my, mz):
							cull = true
					elif face_i == 1:
						if mx - 1 >= 0 and _micro_has(mask, mx - 1, my, mz):
							cull = true
					elif face_i == 2:
						if my + 1 < 2 and _micro_has(mask, mx, my + 1, mz):
							cull = true
					elif face_i == 3:
						if my - 1 >= 0 and _micro_has(mask, mx, my - 1, mz):
							cull = true
					elif face_i == 4:
						if mz + 1 < 2 and _micro_has(mask, mx, my, mz + 1):
							cull = true
					else: # face_i == 5
						if mz - 1 >= 0 and _micro_has(mask, mx, my, mz - 1):
							cull = true

					# (B) if on outer boundary, cull vs neighbor macro cell
					if not cull:
						var neighbor_lp: Vector3i = cell_lp
						var check_neighbor: bool = false
						if face_i == 0 and mx == 1:
							neighbor_lp = cell_lp + Vector3i(1, 0, 0); check_neighbor = true
						elif face_i == 1 and mx == 0:
							neighbor_lp = cell_lp + Vector3i(-1, 0, 0); check_neighbor = true
						elif face_i == 2 and my == 1:
							neighbor_lp = cell_lp + Vector3i(0, 1, 0); check_neighbor = true
						elif face_i == 3 and my == 0:
							neighbor_lp = cell_lp + Vector3i(0, -1, 0); check_neighbor = true
						elif face_i == 4 and mz == 1:
							neighbor_lp = cell_lp + Vector3i(0, 0, 1); check_neighbor = true
						elif face_i == 5 and mz == 0:
							neighbor_lp = cell_lp + Vector3i(0, 0, -1); check_neighbor = true

						if check_neighbor:
							var neighbor_id: int = _get_local_or_air(neighbor_lp)
							if BlockDB.face_hidden_by_neighbor(base_id, neighbor_id):
								cull = true

					if cull:
						continue

					# choose surface tool by transparency
					var st_target: SurfaceTool = st_opaque
					if BlockDB.is_transparent(base_id):
						st_target = st_trans

					var tile: int = BlockDB.get_face_tile(base_id, face_i)
					var quad: Array = face_vertices[face_i]

					var v0_local: Vector3 = quad[0]
					var v1_local: Vector3 = quad[1]
					var v2_local: Vector3 = quad[2]
					var v3_local: Vector3 = quad[3]

					var v0: Vector3 = sub_origin + v0_local * size
					var v1: Vector3 = sub_origin + v1_local * size
					var v2: Vector3 = sub_origin + v2_local * size
					var v3: Vector3 = sub_origin + v3_local * size

					var uv0: Vector2 = _uv_from_local(face_i, v0_local, tile)
					var uv1: Vector2 = _uv_from_local(face_i, v1_local, tile)
					var uv2: Vector2 = _uv_from_local(face_i, v2_local, tile)
					var uv3: Vector2 = _uv_from_local(face_i, v3_local, tile)

					# Tri 1
					st_target.set_normal(normal); st_target.set_uv(uv0); st_target.add_vertex(v0)
					st_target.set_normal(normal); st_target.set_uv(uv2); st_target.add_vertex(v2)
					st_target.set_normal(normal); st_target.set_uv(uv1); st_target.add_vertex(v1)
					# Tri 2
					st_target.set_normal(normal); st_target.set_uv(uv0); st_target.add_vertex(v0)
					st_target.set_normal(normal); st_target.set_uv(uv3); st_target.add_vertex(v3)
					st_target.set_normal(normal); st_target.set_uv(uv2); st_target.add_vertex(v2)

					if st_target == st_opaque:
						added_opaque = true
					else:
						added_trans = true

	return {"opaque": added_opaque, "trans": added_trans}

func snapshot_data() -> Dictionary:
	# Deep copy blocks (Array<Array<Array<int>>>)
	var blocks_copy: Array = []
	blocks_copy.resize(CX)
	for x in CX:
		var col := []
		col.resize(CY)
		for y in CY:
			col[y] = (blocks[x][y] as Array).duplicate()  # one level deep
		blocks_copy[x] = col

	# Copy heightmap
	var hm := PackedInt32Array()
	hm.resize(heightmap_top_solid.size())
	for i in hm.size():
		hm[i] = heightmap_top_solid[i]

	# Copy micro dict
	var micro_copy := {}
	for k in micro.keys():
		var arr: PackedInt32Array = micro[k]
		var arr_copy := PackedInt32Array()
		arr_copy.resize(arr.size())
		for i in arr.size():
			arr_copy[i] = arr[i]
		micro_copy[k] = arr_copy

	return {"blocks": blocks_copy, "heightmap": hm, "micro": micro_copy}

func apply_snapshot(snap: Dictionary) -> void:
	blocks = snap["blocks"]
	heightmap_top_solid = snap["heightmap"]
	micro = snap["micro"]

	# mark everything dirty
	for s in SECTION_COUNT:
		section_dirty[s] = 1
	dirty = true


# Returns true if subcell (sx,sy,sz) is present in the 2×2×2 mask.
# sx/sy/sz must be 0 or 1.
# --- keep this helper if you find it handy ---
static func _sub_index(ix:int, iy:int, iz:int) -> int:
	# bit0=x, bit1=z, bit2=y  →  idx = (iy<<2) | (iz<<1) | ix
	return (iy << 2) | (iz << 1) | ix

# Returns true if subcell (sx,sy,sz) ∈ {0,1}³ is present in the 8-bit mask.
func _micro_has(mask:int, sx:int, sy:int, sz:int) -> bool:
	if sx < 0 or sx > 1 or sy < 0 or sy > 1 or sz < 0 or sz > 1:
		return false
	var idx:int = (sy << 2) | (sz << 1) | sx   # ← match _sub_index!
	return ((mask >> idx) & 1) == 1


# Read a block id from a neighbor cell in local-chunk coords; AIR if OOB.
func _get_local_or_air(p: Vector3i) -> int:
	if index_in_bounds(p.x, p.y, p.z):
		return get_block(p)
	return BlockDB.BlockId.AIR
