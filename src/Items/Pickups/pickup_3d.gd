extends Node3D
class_name Pickup3D

@export var block_id: int = -1
@export var count: int = 1
@export var max_per_pickup := 99

# presentation
@export var bob_height := 0.15
@export var bob_speed := 2.2
@export var spin_speed := 70.0

# player collection (walk-into-it)
@export var collect_radius := 0.9

# pickup↔pickup clumping
@export var merge_radius := 1.1         # area radius for "neighbors"
@export var clump_magnet_speed := 3.0   # how fast pickups drift together
@export var merge_distance := 0.45      # when two neighbors are this close, merge

var _phase := randf() * TAU
var _atlas: Texture2D

# --- visual clump rules ---
@export var max_visual_cubes := 8
@export var base_cube_scale := 0.34
@export var layout_radius_min := 0.06
@export var layout_radius_step := 0.028
@export var layout_shuffle_time := 0.12

var _last_visual_count := -999

@export var hover_height := 0.24
@export var fall_gravity := 18.0
@export var terminal_speed := 18.0
var _vy := 0.0

# --- entity preview mode ---
@export var use_entity_preview: bool = true
@export var entity_preview_scale: float = 0.36
var _entity_preview_scene: PackedScene = null
var _entity_preview_loaded: bool = false

@export var piece_y_jitter: float = 0.012   # ~1.2 cm; small but effective


func _ready() -> void:
	add_to_group("pickup")
	_atlas = load(BlockDB.ATLAS_PATH)
	_build_cluster()

	# --- collect trigger (player) ---
	var trig := $Trigger as Area3D
	trig.monitoring = true
	trig.monitorable = true
	trig.collision_layer = 0
	trig.collision_mask = 1  # default player layer
	var tshape := $Trigger/CollisionShape3D as CollisionShape3D
	if tshape and tshape.shape is SphereShape3D:
		(tshape.shape as SphereShape3D).radius = collect_radius
	trig.body_entered.connect(_on_body_entered)

	# --- merge area (other pickups) ---
	var merge := $Merge as Area3D
	merge.monitoring = true
	merge.monitorable = true
	merge.collision_layer = 1 << 2       # put all pickups on layer 3
	merge.collision_mask  = 1 << 2       # and only look for layer 3
	var mshape := $Merge/CollisionShape3D as CollisionShape3D
	if mshape and mshape.shape is SphereShape3D:
		(mshape.shape as SphereShape3D).radius = merge_radius

	# catch “already overlapping at spawn”
	#call_deferred("_merge_initial_overlaps")

func _process(dt: float) -> void:
	# spin + bob
	rotation.y += deg_to_rad(spin_speed) * dt
	var y := sin(Time.get_ticks_msec() / 1000.0 * bob_speed + _phase) * bob_height
	$Cluster.position.y = 0.2 + y

	# --- clumping (robust; no signals needed) ---
	var neighbors := _neighbor_pickups()
	if neighbors.size() > 0:
		# 1) soft magnet toward local centroid so clumps form visually
		var c := global_transform.origin
		for p in neighbors: c += p.global_transform.origin
		c /= float(neighbors.size() + 1)

		var cur := global_transform.origin
		var target := Vector3(c.x, cur.y, c.z)  # 👈 keep physics-owned Y
		global_transform.origin = cur.lerp(target, clamp(clump_magnet_speed * dt, 0.0, 0.5))

		# 2) merge when close; stable leader absorbs
		for p in neighbors:
			if not is_instance_valid(p): continue
			if cur.distance_to(p.global_transform.origin) <= merge_distance:
				_try_merge_with(p)


func _physics_process(dt: float) -> void:
	# cast from above so we always hit ground even if we're inside geometry
	var from := global_position + Vector3(0, 2.0, 0)   # 👈 was 0.4
	var to := from + Vector3.DOWN * 8.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = false
	q.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(q)

	var y := global_position.y
	if hit.is_empty():
		# no ground → keep falling
		_vy = clamp(_vy - fall_gravity * dt, -terminal_speed, terminal_speed)
		y += _vy * dt
	else:
		var target_y = hit.position.y + hover_height
		if y > target_y + 0.02:
			_vy = clamp(_vy - fall_gravity * dt, -terminal_speed, terminal_speed)
			y += _vy * dt
		else:
			# landed → lock to hover plane
			y = target_y
			_vy = 0.0

	global_position = Vector3(global_position.x, y, global_position.z)

func _is_entity_pickup() -> bool:
	return use_entity_preview and BlockDB.is_entity(block_id)

func _ensure_entity_preview_loaded() -> void:
	if _entity_preview_loaded:
		return
	_entity_preview_loaded = true
	_entity_preview_scene = BlockDB.entity_packed_scene(block_id)
	# If none registered, we’ll silently fall back to blocklets.

func _instantiate_entity_preview_piece() -> Node3D:
	# Return a lightweight, disabled preview of the entity scene.
	# If anything goes wrong, return null so caller can fall back.
	if _entity_preview_scene == null:
		return null
	var inst := _entity_preview_scene.instantiate()
	if inst == null or not (inst is Node3D):
		return null

	var root := inst as Node3D
	# Freeze all processing/physics under this preview copy
	_disable_processing_recursively(root)
	_disable_collisions_recursively(root)
	_make_meshes_unshaded_if_textured(root) # optional: keeps PBRs; no harm if none
	#root.scale = Vector3(entity_preview_scale, entity_preview_scale, entity_preview_scale)
	return root

func _disable_processing_recursively(n: Node) -> void:
	n.process_mode = Node.PROCESS_MODE_DISABLED
	for c in n.get_children():
		if c is Node:
			_disable_processing_recursively(c)

func _disable_collisions_recursively(n: Node) -> void:
	if n is CollisionObject3D:
		(n as CollisionObject3D).collision_layer = 0
		(n as CollisionObject3D).collision_mask = 0
	if n is Area3D:
		(n as Area3D).monitoring = false
		(n as Area3D).monitorable = false
	for c in n.get_children():
		if c is Node:
			_disable_collisions_recursively(c)

func _make_meshes_unshaded_if_textured(n: Node) -> void:
	# purely optional polish; safe no-op if your entity uses PBR
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var mesh := mi.mesh
		if mesh:
			for si in mesh.get_surface_count():
				var mat := mi.get_active_material(si)
				if mat is BaseMaterial3D:
					var bm := mat as BaseMaterial3D
					# don’t force unshaded if you like PBR; comment next line out to keep original
					# bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
					bm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	for c in n.get_children():
		if c is Node:
			_make_meshes_unshaded_if_textured(c)


# --- neighbor collection (uses the Merge area so it's cheap) ---
func _neighbor_pickups() -> Array:
	var out: Array = []
	var merge := $Merge as Area3D
	for a in merge.get_overlapping_areas():
		var parent := a.get_parent()
		if parent == self: continue
		if parent is Pickup3D and (parent as Pickup3D).block_id == block_id:
			out.append(parent)
	return out

# --- merging rules ---
func _try_merge_with(other: Pickup3D) -> void:
	if other == null or other == self: return
	if other.block_id != block_id: return
	# deterministic leader so two neighbors don't both try absorbing each other
	if get_instance_id() > other.get_instance_id():
		return

	var space := max_per_pickup - count
	if space <= 0:
		return
	var take = min(space, other.count)
	if take <= 0:
		return

	count += take
	_pop_vfx()	
	other.count -= take
	_refresh_cluster_counts()
	if other.count <= 0:
		other.queue_free()
	else:
		other._refresh_cluster_counts()

func _pop_vfx():
	$Cluster.scale = Vector3.ONE
	var tw := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property($Cluster, "scale", Vector3(1.12,1.12,1.12), 0.06).set_delay(0.0)
	tw.tween_property($Cluster, "scale", Vector3.ONE, 0.08)

# --- player pickup ---
func _on_body_entered(body: Node) -> void:
	if not body.is_in_group("player"): return
	_try_collect_into_inventory()

func _try_collect_into_inventory() -> void:
	var inv := _find_inventory()
	if inv == null: return
	var leftover := inv.add_items(block_id, count)  # hotbar merge → backpack → empties
	if leftover <= 0:
		queue_free()
	else:
		count = leftover
		_refresh_cluster_counts()
		_split_if_needed()  # safety if someone set count > 99

func _find_inventory() -> InventoryUI:
	var nodes := get_tree().get_nodes_in_group("inventory_ui")
	return (nodes[0] as InventoryUI) if nodes.size() > 0 else null

# --- split/spawn helpers (unchanged logic) ---
func _split_if_needed() -> void:
	var extra = max(count - max_per_pickup, 0)
	if extra <= 0: return
	count = max_per_pickup
	_refresh_cluster_counts()
	_spawn_extra(extra)

func _spawn_extra(amount: int) -> void:
	var scene := preload("res://src/Items/Pickups/pickup_3d.tscn")
	var left := amount
	while left > 0:
		var take = min(left, max_per_pickup)
		var p := scene.instantiate() as Pickup3D
		p.block_id = block_id
		p.count = take
		get_tree().current_scene.add_child(p)
		p.global_position = global_position + Vector3(randf_range(-0.2,0.2), 0.0, randf_range(-0.2,0.2))
		left -= take

# ---------------- visuals (unchanged apart from your UV fix) ----------------
func _make_blocklet_mesh(id:int, scale:float=0.32) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _atlas
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	
	if BlockDB.is_transparent(id):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		mat.alpha_scissor_threshold = 0.0
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED   # optional: render both sides
		mat.disable_receive_shadows = true             # optional: cleaner for glass


	var faces = [
		{ "n": Vector3( 1,0,0), "v":[Vector3(0.5,-0.5,-0.5),Vector3(0.5,-0.5,0.5),Vector3(0.5,0.5,0.5),Vector3(0.5,0.5,-0.5)], "f":0 }, # +X
		{ "n": Vector3(-1,0,0), "v":[Vector3(-0.5,-0.5,0.5),Vector3(-0.5,-0.5,-0.5),Vector3(-0.5,0.5,-0.5),Vector3(-0.5,0.5,0.5)], "f":1 }, # -X
		{ "n": Vector3( 0,1,0), "v":[Vector3(-0.5,0.5,-0.5),Vector3(0.5,0.5,-0.5),Vector3(0.5,0.5,0.5),Vector3(-0.5,0.5,0.5)], "f":2 },   # +Y
		{ "n": Vector3( 0,-1,0),"v":[Vector3(-0.5,-0.5,0.5),Vector3(0.5,-0.5,0.5),Vector3(0.5,-0.5,-0.5),Vector3(-0.5,-0.5,-0.5)], "f":3 }, # -Y
		{ "n": Vector3( 0,0,1), "v":[Vector3(0.5,-0.5,0.5),Vector3(-0.5,-0.5,0.5),Vector3(-0.5,0.5,0.5),Vector3(0.5,0.5,0.5)], "f":4 },  # +Z
		{ "n": Vector3( 0,0,-1),"v":[Vector3(-0.5,-0.5,-0.5),Vector3(0.5,-0.5,-0.5),Vector3(0.5,0.5,-0.5),Vector3(-0.5,0.5,-0.5)], "f":5 } # -Z
	]

	var V := PackedVector3Array()
	var N := PackedVector3Array()
	var UV := PackedVector2Array()
	var I := PackedInt32Array()
	var start := 0
	for face in faces:
		var tile := BlockDB.get_face_tile(id, face["f"])
		var uvs := _uv_for_face(tile, face["f"])
		for j in 4:
			V.append((face["v"][j] as Vector3) * scale)
			N.append(face["n"])
			UV.append(uvs[j])
		I.append_array([start, start+1, start+2, start, start+2, start+3])
		start += 4

	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = V
	arr[Mesh.ARRAY_NORMAL] = N
	arr[Mesh.ARRAY_TEX_UV] = UV
	arr[Mesh.ARRAY_INDEX] = I
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(0, mat)
	return mesh

func _uv_for_face(tile_index:int, face:int) -> PackedVector2Array:
	var uvs := BlockDB.tile_uvs(tile_index)
	var TL := uvs[0]; var TR := uvs[1]; var BR := uvs[2]; var BL := uvs[3]
	match face:
		2:  return PackedVector2Array([TL, TR, BR, BL])         # +Y
		3:  return PackedVector2Array([BR, BL, TL, TR])         # -Y rotated
		_:  return PackedVector2Array([                         # sides flipped V
			Vector2(TL.x, BR.y), Vector2(TR.x, BR.y),
			Vector2(TR.x, TL.y), Vector2(TL.x, TL.y)
		])

func _build_cluster() -> void:
	_reflow_cluster(false)

func _refresh_cluster_counts() -> void:
	var before := _visual_piece_count()

	# If block type changed, refresh meshes for blocklet mode.
	# For entity mode, pieces are whole preview nodes; nothing to remesh.
	if not _is_entity_pickup():
		for i in $Cluster.get_child_count():
			var node := $Cluster.get_child(i)
			if node is MeshInstance3D:
				(node as MeshInstance3D).mesh = _make_blocklet_mesh(block_id, base_cube_scale)

	_reflow_cluster(before != _visual_piece_count() or _last_visual_count != before)
	_last_visual_count = _visual_piece_count()

func _visual_piece_count() -> int:
	# 1..3 show exact count, then ease toward max_visual_cubes
	if count <= 3:
		return count
	var t = clamp(float(count - 3) / float(max_per_pickup - 3), 0.0, 1.0)
	var eased := pow(t, 0.6)  # front-load small counts
	return clamp(3 + int(round(eased * (max_visual_cubes - 3))), 3, max_visual_cubes)

func _layout_offsets(n:int) -> Array[Vector3]:
	var out:Array[Vector3] = []
	if n <= 1:
		out.append(Vector3.ZERO)
		return out

	# one or two rings based on n
	var ring1 = min(n, 6)
	var ring2 = max(0, n - ring1)

	var r1 := layout_radius_min + layout_radius_step * float(ring1)
	var r2 := r1 + 0.045

	for i in ring1:
		var ang := (TAU * float(i) / float(ring1)) + randf() * 0.15
		out.append(Vector3(cos(ang) * r1, 0.0, sin(ang) * r1))
	for i in ring2:
		var ang := (TAU * float(i) / float(ring2)) + randf() * 0.20
		out.append(Vector3(cos(ang) * r2, 0.0, sin(ang) * r2))

	return out

func _reflow_cluster(animated: bool) -> void:
	var want := _visual_piece_count()
	var curr := $Cluster.get_child_count()

	# create/destroy children to match want
	while curr < want:
		var piece: Node3D = null
		if _is_entity_pickup():
			_ensure_entity_preview_loaded()
			piece = _instantiate_entity_preview_piece()
			if piece == null:
				# fallback to blocklet if preview not available
				var mi := MeshInstance3D.new()
				mi.mesh = _make_blocklet_mesh(block_id, base_cube_scale)
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				piece = mi
		else:
			var mi2 := MeshInstance3D.new()
			mi2.mesh = _make_blocklet_mesh(block_id, base_cube_scale)
			mi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			piece = mi2

		$Cluster.add_child(piece)
		curr += 1

	while curr > want:
		$Cluster.get_child(curr - 1).queue_free()
		curr -= 1

	# layout offsets
	var offs := _layout_offsets(want)

	# tween positions/rotations a smidge
	for i in want:
		var node := $Cluster.get_child(i) as Node3D

		# --- tiny vertical jitter so faces aren't coplanar ---
		var yoff: float = 0.0
		if want > 1:
			# deterministic tiny jitter using golden-ratio noise + your _phase
			var t: float = fmod(float(i) * 0.61803398875 + _phase * 0.159, 1.0)
			yoff = (t - 0.5) * 2.0 * piece_y_jitter

		# --- scale (entities) + random yaw, as you already do ---
		var s: float = 1.0
		if _is_entity_pickup():
			s = entity_preview_scale
		var basis := Basis().rotated(Vector3.UP, randf_range(-0.2, 0.2)).scaled(Vector3(s, s, s))

		# ⬇️ apply the extra Y offset here
		var pos: Vector3 = offs[i] + Vector3(0.0, yoff, 0.0)
		var target := Transform3D(basis, pos)

		# --- transparent only: nudge sorting so order is stable ---
		if BlockDB.is_transparent(block_id):
			if node is GeometryInstance3D:
				var gi := node as GeometryInstance3D
				gi.sorting_offset = float(i) * 0.001   # tiny, monotonic

		if animated:
			var tw := create_tween()
			tw.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			tw.tween_property(node, "transform", target, layout_shuffle_time)
		else:
			node.transform = target
