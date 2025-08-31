extends TextureRect
class_name ItemSlot

signal changed

@export var slot_size := Vector2(88, 88)
const MAX_STACK := 99

# Backing arrays (optional for counts)
var backing_ids: Array[int] = []
var backing_counts: Array[int] = []

var index: int = -1
var block_id: int = -1
var count: int = 0

var atlas: Texture2D
var _pressing := false
var _press_pos := Vector2.ZERO

var _count_label: Label

signal quick_move(slot: ItemSlot)
var _press_button := 0
var _drag_split := false    # true = RMB drag (half stack)


func _ready() -> void:
	custom_minimum_size = slot_size
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical   = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED

	atlas = load(BlockDB.ATLAS_PATH)

	# Count label (bottom-right)
	_count_label = Label.new()
	_count_label.name = "Count"
	_count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_count_label.anchor_left = 0; _count_label.anchor_top = 0
	_count_label.anchor_right = 1; _count_label.anchor_bottom = 1
	_count_label.offset_right = -6; _count_label.offset_bottom = -2
	_count_label.add_theme_font_size_override("font_size", 14)
	_count_label.add_theme_constant_override("outline_size", 2)
	_count_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	add_child(_count_label)

	_update_visual()

# ---- Binding ----
# Backwards compatible:
# - Old usage: bind(inv_ids, i)
# - New usage: bind(inv_ids, i, inv_counts)
func bind(ids_ref: Array[int], i: int, counts_ref: Array[int] = []) -> void:
	backing_ids = ids_ref
	backing_counts = counts_ref
	index = i

	var id_ok := (i >= 0 and i < backing_ids.size())
	block_id = (backing_ids[i] if id_ok else -1)

	if backing_counts.size() == backing_ids.size() and i >= 0 and i < backing_counts.size():
		count = int(backing_counts[i])
	else:
		# If no counts array provided, default to 1 for any present item.
		count = (1 if block_id >= 0 else 0)

	_normalize_stack()
	_apply_to_backing()
	_update_visual()

# Keep compatibility with your existing calls
func set_block_id(id: int) -> void:
	# If no explicit count yet, treat as 1 when placing an item, 0 when clearing.
	var new_count := (0 if id < 0 else (count if count > 0 else 1))
	set_stack(id, new_count)

# New explicit setter
func set_stack(id: int, ct: int) -> void:
	block_id = id
	count = ct
	_normalize_stack()
	_apply_to_backing()
	_update_visual()
	emit_signal("changed")

# ---- Internals ----
func _normalize_stack() -> void:
	if block_id < 0 or count <= 0:
		block_id = -1
		count = 0
	else:
		if count > MAX_STACK:
			count = MAX_STACK

# ------------ Drag & Drop ------------
func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb: InputEventMouseButton = e
		if mb.pressed:
			_pressing = true
			_press_pos = mb.position
			_press_button = mb.button_index

			# SHIFT + LMB = quick move (no drag)
			if mb.button_index == MOUSE_BUTTON_LEFT and mb.shift_pressed:
				emit_signal("quick_move", self)
				_pressing = false
				return
		else:
			_pressing = false

	elif e is InputEventMouseMotion and _pressing:
		var mm: InputEventMouseMotion = e
		var d: float = _press_pos.distance_to(mm.position)
		if d >= 6.0 and block_id >= 0 and count > 0:
			_drag_split = (_press_button == MOUSE_BUTTON_RIGHT)

			var grab: int = count
			if _drag_split:
				grab = int(ceil(float(count) / 2.0))

			var preview: TextureRect = TextureRect.new()
			preview.texture = texture
			preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			preview.custom_minimum_size = slot_size
			preview.mouse_filter = Control.MOUSE_FILTER_IGNORE

			var data: Dictionary = {
				"type": "slot_item",
				"block_id": block_id,
				"count": grab,
				"from": self,
				"split": _drag_split
			}
			force_drag(data, preview)
			_pressing = false

func _get_drag_data(_pos: Vector2) -> Variant:
	if block_id < 0 or count <= 0:
		return null
	var preview: TextureRect = TextureRect.new()
	preview.texture = texture
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.custom_minimum_size = slot_size
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_drag_preview(preview)

	var data: Dictionary = {
		"type": "slot_item",
		"block_id": block_id,
		"count": count,
		"from": self,
		"split": false
	}
	return data

func _can_drop_data(_pos, data) -> bool:
	var ok = (data is Dictionary) and data.get("type","") == "slot_item"
	return ok

func _drop_data(_pos: Vector2, data: Variant) -> void:
	if not (data is Dictionary):
		return
	var dict: Dictionary = data
	if String(dict.get("type", "")) != "slot_item":
		return

	var src_any: Variant = dict.get("from")
	if src_any == null or not (src_any is ItemSlot):
		return
	var src: ItemSlot = src_any
	if src == self:
		return

	var src_id: int = int(dict.get("block_id", -1))
	var move_ct: int = int(dict.get("count", 0))
	var split: bool = bool(dict.get("split", false))

	var dst_id: int = block_id
	var dst_ct: int = count

	# --- RMB split behavior: deposit half into empty or same-id (no swap) ---
	if split:
		if src_id < 0 or move_ct <= 0:
			return

		# empty destination
		if dst_id < 0 or dst_ct <= 0:
			var take_empty: int = min(move_ct, MAX_STACK)
			set_stack(src_id, take_empty)
			var new_src_ct: int = src.count - take_empty
			if new_src_ct <= 0:
				src.set_stack(-1, 0)
			else:
				src.set_stack(src.block_id, new_src_ct)
			emit_signal("changed")
			return

		# merge into same-id
		if dst_id == src_id and dst_ct < MAX_STACK:
			var space: int = MAX_STACK - dst_ct
			var take_merge: int = min(space, move_ct)
			set_stack(dst_id, dst_ct + take_merge)
			var new_src_ct2: int = src.count - take_merge
			if new_src_ct2 <= 0:
				src.set_stack(-1, 0)
			else:
				src.set_stack(src.block_id, new_src_ct2)
			emit_signal("changed")
			return

		# otherwise do nothing
		return

	# --- LMB: merge if same id, else swap whole stacks ---
	if src_id >= 0 and dst_id == src_id and dst_ct < MAX_STACK and move_ct > 0:
		var space2: int = MAX_STACK - dst_ct
		var take2: int = min(space2, move_ct)
		set_stack(dst_id, dst_ct + take2)
		var new_src_ct3: int = src.count - take2
		if new_src_ct3 <= 0:
			src.set_stack(-1, 0)
		else:
			src.set_stack(src.block_id, new_src_ct3)
		emit_signal("changed")
		return

	# swap stacks
	var src_full_ct: int = src.count
	var old_dst_id: int = dst_id
	var old_dst_ct: int = dst_ct
	src.set_stack(old_dst_id, old_dst_ct)
	set_stack(src_id, src_full_ct)
	emit_signal("changed")

func _sync_from_backing() -> void:
	var id_ok := index >= 0 and index < backing_ids.size()
	var new_id := (int(backing_ids[index]) if id_ok else -1)

	var new_count := 0
	if backing_counts.size() == backing_ids.size() and id_ok:
		new_count = int(backing_counts[index])
	elif new_id >= 0:
		new_count = 1  # default if no counts array provided

	block_id = new_id
	count = new_count
	_normalize_stack()

func _apply_to_backing() -> void:
	if index >= 0 and index < backing_ids.size():
		backing_ids[index] = block_id
	if backing_counts.size() == backing_ids.size() and index >= 0 and index < backing_counts.size():
		backing_counts[index] = count

func _update_visual() -> void:
	if block_id < 0 or count <= 0:
		texture = null
		self_modulate = Color(1, 1, 1, 0.18)
		_count_label.text = ""
		return
	var tile := BlockDB.get_face_tile(block_id, 2)
	var at := AtlasTexture.new()
	at.atlas = atlas
	at.region = BlockDB.tile_region_rect(tile)
	texture = at
	self_modulate = Color(1, 1, 1, 1)
	_count_label.text = (str(count) if count > 1 else "")

# Replace the old refresh with this:
func refresh() -> void:
	_sync_from_backing()   # 👈 pull latest id/count from arrays
	_update_visual()
