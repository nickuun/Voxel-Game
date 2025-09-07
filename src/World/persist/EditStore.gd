extends RefCounted
class_name EditStore

# cpos -> { Vector3i(local) : int(block_id) }
var _blocks := {}

# cpos -> { Vector3i(cell_lp) : { sub_index(int) : base_id(int) } }
# base_id <= 0 => clear that sub
var _micro := {}

func record_block(cpos: Vector3i, lpos: Vector3i, id: int) -> void:
	var map: Dictionary = _blocks.get(cpos, {})
	map[lpos] = id
	_blocks[cpos] = map

func record_micro_sub(cpos: Vector3i, cell_lp: Vector3i, sub_index: int, base_id: int) -> void:
	var by_chunk: Dictionary = _micro.get(cpos, {})
	var cell: Dictionary = by_chunk.get(cell_lp, {})
	if base_id <= 0:
		cell.erase(sub_index)
	else:
		cell[sub_index] = base_id
	if cell.size() == 0:
		by_chunk.erase(cell_lp)
	else:
		by_chunk[cell_lp] = cell
	_micro[cpos] = by_chunk

func apply_to_chunk(c: Chunk) -> void:
	var cpos: Vector3i = c.chunk_pos
	var changed := false

	if _blocks.has(cpos):
		var map: Dictionary = _blocks[cpos]
		for lp_key in map.keys():
			var lp: Vector3i = lp_key
			var id: int = int(map[lp_key])
			if Chunk.index_in_bounds(lp.x, lp.y, lp.z):
				c.set_block(lp, id)
				c.mark_section_dirty_for_local_y(lp.y)
				c.update_heightmap_column(lp.x, lp.z)
				changed = true

	if _micro.has(cpos):
		var mm: Dictionary = _micro[cpos]
		for cell_key in mm.keys():
			var cell_lp: Vector3i = cell_key
			var subs: Dictionary = mm[cell_key]
			for k in subs.keys():
				var s: int = int(k)
				var base_id: int = int(subs[k])
				if base_id <= 0:
					c.clear_micro_sub(cell_lp, s)
				else:
					c.set_micro_sub(cell_lp, s, base_id)
				changed = true

	if changed:
		c.dirty = true

# Optional hooks for future save/load
func to_dict() -> Dictionary:
	return {"blocks": _blocks, "micro": _micro}

func from_dict(d: Dictionary) -> void:
	_blocks = d.get("blocks", {})
	_micro  = d.get("micro", {})
