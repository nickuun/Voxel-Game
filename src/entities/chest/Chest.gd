extends Node3D
class_name Chest

@export var slots: int = 27        # 3×9
@export var debug_seed: bool = false

const MAX_STACK := 99

# NEW: configure how spill looks/behaves
@export var pickup_scene: PackedScene = preload("res://src/Items/Pickups/pickup_3d.tscn")
@export var spill_radius: float = 0.65     # how far items can land horizontally
@export var spill_up_offset: float = 0.55  # spawn slightly above chest top
@export var chest_drop_id: int = BlockDB.BlockId.CHEST

var ids: Array[int] = []
var counts: Array[int] = []

func _ready() -> void:
	add_to_group("chest")
	_resize_storage(slots)
	if debug_seed:
		_seed_example()

# If you ever change `slots` in the inspector at runtime, call this.
func _resize_storage(n: int) -> void:
	ids.resize(n)
	counts.resize(n)
	for i in n:
		if ids[i] == 0:
			ids[i] = -1
		if ids[i] < 0 or counts[i] <= 0:
			ids[i] = -1
			counts[i] = 0
		else:
			if counts[i] > MAX_STACK:
				counts[i] = MAX_STACK

# ----------------- GETTERS -----------------
func get_ids() -> Array[int]:
	return ids.duplicate()

func get_counts() -> Array[int]:
	return counts.duplicate()

func get_ids_counts() -> Dictionary:
	return {"ids": get_ids(), "counts": get_counts()}

# ----------------- SETTERS -----------------
func set_ids(new_ids: Array[int]) -> void:
	var a: Array[int] = new_ids.duplicate()
	a.resize(ids.size())
	for i in ids.size():
		if i >= new_ids.size():
			a[i] = -1
	ids = a
	for i in ids.size():
		if ids[i] < 0:
			counts[i] = 0
		else:
			if counts[i] <= 0:
				counts[i] = 1
			if counts[i] > MAX_STACK:
				counts[i] = MAX_STACK

func set_counts(new_counts: Array[int]) -> void:
	var c: Array[int] = new_counts.duplicate()
	c.resize(counts.size())
	for i in counts.size():
		var v: int = 0
		if i < new_counts.size():
			v = int(new_counts[i])
		if v <= 0 or ids[i] < 0:
			counts[i] = 0
			ids[i] = -1
		else:
			if v > MAX_STACK:
				v = MAX_STACK
			counts[i] = v

func set_ids_counts(new_ids: Array[int], new_counts: Array[int]) -> void:
	var n: int = ids.size()
	var a: Array[int] = new_ids.duplicate()
	a.resize(n)
	var c: Array[int] = new_counts.duplicate()
	c.resize(n)

	for i in n:
		var id_i: int = -1
		var ct_i: int = 0
		if i < new_ids.size():
			id_i = int(new_ids[i])
		if i < new_counts.size():
			ct_i = int(new_counts[i])

		if id_i < 0 or ct_i <= 0:
			ids[i] = -1
			counts[i] = 0
		else:
			if ct_i > MAX_STACK:
				ct_i = MAX_STACK
			ids[i] = id_i
			counts[i] = ct_i

# ----------------- OPTIONAL EXAMPLE SEED -----------------
func _seed_example() -> void:
	var seed_ids: Array[int] = [
		BlockDB.BlockId.WOOD_BIRCH, BlockDB.BlockId.LOG_BIRCH, BlockDB.BlockId.ICE,
		BlockDB.BlockId.CHEST
	]
	var seed_counts: Array[int] = [8, 12, 3, 1]

	for i in seed_ids.size():
		if i >= ids.size():
			break
		ids[i] = seed_ids[i]
		var ct: int = seed_counts[i]
		if ct > MAX_STACK:
			ct = MAX_STACK
		counts[i] = ct
	for i in range(seed_ids.size(), ids.size()):
		ids[i] = -1
		counts[i] = 0

# ----------------- BREAK LOGIC -----------------

func break_and_delete() -> void:
	# 1) spill all contents as pickups
	_spill_contents_as_pickups()
	# 2) drop the chest itself as a pickup
	_drop_self_as_pickup()
	# 3) if inventory UI was open on this chest, close it (safety)
	_close_inventory_if_open_on_this()
	# 4) remove this entity
	queue_free()

# ---- helpers ----

func _spill_contents_as_pickups() -> void:
	var origin: Vector3 = global_position + Vector3(0.0, spill_up_offset, 0.0)
	for i in ids.size():
		var id_i: int = ids[i]
		var ct_i: int = counts[i]
		if id_i >= 0 and ct_i > 0:
			var where: Vector3 = origin + _random_spread(spill_radius)
			_spawn_pickup(id_i, ct_i, where)
			# clear the slot
			ids[i] = -1
			counts[i] = 0

func _drop_self_as_pickup() -> void:
	var where: Vector3 = global_position + Vector3(0.0, spill_up_offset, 0.0)
	_spawn_pickup(chest_drop_id, 1, where)

func _spawn_pickup(id: int, count: int, where: Vector3) -> void:
	if pickup_scene == null:
		return
	var p: Pickup3D = pickup_scene.instantiate() as Pickup3D
	if p == null:
		return
	p.block_id = id
	p.count = count
	get_tree().current_scene.add_child(p)
	p.global_position = where

func _random_spread(r: float) -> Vector3:
	var ang: float = randf() * TAU
	var rad: float = randf() * r
	var x: float = cos(ang) * rad
	var z: float = sin(ang) * rad
	return Vector3(x, 0.0, z)

func _close_inventory_if_open_on_this() -> void:
	var nodes: Array = get_tree().get_nodes_in_group("inventory_ui")
	if nodes.size() == 0:
		return
	var inv: InventoryUI = nodes[0] as InventoryUI
	if inv == null:
		return
	# dumb-but-safe: just close if open (prevents dangling reference)
	if inv.is_open():
		inv.close()
