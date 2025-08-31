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

static func index_in_bounds(x:int,y:int,z:int) -> bool:
	return x>=0 and x<CX and y>=0 and y<CY and z>=0 and z<CZ

func set_block(local:Vector3i, id:int):
	if not index_in_bounds(local.x, local.y, local.z): return
	blocks[local.x][local.y][local.z] = id
	dirty = true

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

	# Materials: reuse your existing for opaque; duplicate for transparent and enable alpha
	var mat_opaque: Material = material
	var mat_trans: StandardMaterial3D
	if material is StandardMaterial3D:
		mat_trans = (material as StandardMaterial3D).duplicate()
	else:
		var m := StandardMaterial3D.new()
		mat_opaque = m
		mat_trans = m.duplicate()
	mat_trans.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# (no depth_draw_mode needed on 4.4.1)

	# Two surfaces
	var st_opaque := SurfaceTool.new()
	st_opaque.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_opaque.set_material(mat_opaque)

	var st_trans := SurfaceTool.new()
	st_trans.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_trans.set_material(mat_trans)

	var had_opaque := false
	var had_trans := false

	var faces := [
		Vector3(1, 0, 0),   # +X
		Vector3(-1, 0, 0),  # -X
		Vector3(0, 1, 0),   # +Y
		Vector3(0, -1, 0),  # -Y
		Vector3(0, 0, 1),   # +Z
		Vector3(0, 0, -1),  # -Z
	]

	var face_vertices: Array = [
		[Vector3(1,0,0), Vector3(1,1,0), Vector3(1,1,1), Vector3(1,0,1)],  # +X
		[Vector3(0,0,1), Vector3(0,1,1), Vector3(0,1,0), Vector3(0,0,0)],  # -X
		[Vector3(0,1,1), Vector3(1,1,1), Vector3(1,1,0), Vector3(0,1,0)],  # +Y
		[Vector3(0,0,0), Vector3(1,0,0), Vector3(1,0,1), Vector3(0,0,1)],  # -Y
		[Vector3(0,0,1), Vector3(1,0,1), Vector3(1,1,1), Vector3(0,1,1)],  # +Z
		[Vector3(0,1,0), Vector3(1,1,0), Vector3(1,0,0), Vector3(0,0,0)],  # -Z
	]

	for x in CX:
		for y in CY:
			for z in CZ:
				var id: int = blocks[x][y][z]
				if id == BlockDB.BlockId.AIR:
					continue

				for face_i in 6:
					var npos := Vector3i(x, y, z) + Vector3i(faces[face_i])
					var neighbor_id: int = BlockDB.BlockId.AIR
					if index_in_bounds(npos.x, npos.y, npos.z):
						neighbor_id = blocks[npos.x][npos.y][npos.z]

					# Hide faces against opaque neighbors AND between identical transparent blocks (e.g. glass↔glass)
					if BlockDB.face_hidden_by_neighbor(id, neighbor_id):
						continue

					var base: Vector3 = Vector3(x, y, z)
					var verts: Array = face_vertices[face_i]
					var normal: Vector3 = faces[face_i]
					var tile: int = BlockDB.get_face_tile(id, face_i)

					var v0: Vector3 = base + (verts[0] as Vector3)
					var v1: Vector3 = base + (verts[1] as Vector3)
					var v2: Vector3 = base + (verts[2] as Vector3)
					var v3: Vector3 = base + (verts[3] as Vector3)

					var uv0: Vector2 = _uv_from_local(face_i, verts[0], tile)
					var uv1: Vector2 = _uv_from_local(face_i, verts[1], tile)
					var uv2: Vector2 = _uv_from_local(face_i, verts[2], tile)
					var uv3: Vector2 = _uv_from_local(face_i, verts[3], tile)

					var st_target: SurfaceTool = st_opaque
					if BlockDB.is_transparent(id):
						st_target = st_trans

					# Tri 1
					st_target.set_normal(normal); st_target.set_uv(uv0); st_target.add_vertex(v0)
					st_target.set_normal(normal); st_target.set_uv(uv2); st_target.add_vertex(v2)
					st_target.set_normal(normal); st_target.set_uv(uv1); st_target.add_vertex(v1)
					# Tri 2
					st_target.set_normal(normal); st_target.set_uv(uv0); st_target.add_vertex(v0)
					st_target.set_normal(normal); st_target.set_uv(uv3); st_target.add_vertex(v3)
					st_target.set_normal(normal); st_target.set_uv(uv2); st_target.add_vertex(v2)

					if st_target == st_opaque:
						had_opaque = true
					else:
						had_trans = true

	# Build one mesh with up to two surfaces (commit only if we actually added verts)
	var mesh := ArrayMesh.new()
	if had_opaque:
		st_opaque.commit(mesh)
	if had_trans:
		st_trans.commit(mesh)

	mesh_instance.mesh = mesh

	# Rebuild collider
	if mesh and mesh.get_surface_count() > 0:
		collision_shape.shape = mesh.create_trimesh_shape()
	else:
		collision_shape.shape = null

	dirty = false
