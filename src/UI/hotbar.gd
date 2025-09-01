extends Control
class_name Hotbar

signal selected_changed(index:int, block_id:int)

const SLOT_COUNT := 9

@export var slot_size := Vector2(48, 48)   # base size before scaling
@export var ui_scale := 4.0                 # 4x bigger, tweak as you like
@export var bottom_margin := 24.0           # distance from screen bottom
@export var bar_padding := Vector2(12, 8)   # left/right, top/bottom padding
@export var slot_separation := 6.0          # space between slots


var block_ids: Array[int] = [
	BlockDB.BlockId.GRASS, BlockDB.BlockId.CLAY_BRICKS, BlockDB.BlockId.STONE,
	BlockDB.BlockId.WOOD,  BlockDB.BlockId.LOG,  BlockDB.BlockId.CHEST,
	BlockDB.BlockId.COBBLE, BlockDB.BlockId.STONE_BRICKS, BlockDB.BlockId.GLASS,
]

const MAX_STACK := 99
var counts: Array[int] = [
	16, 32, 64,
	12,  8,  1,
	40, 20,  6,
]

var selected := 0
var atlas: Texture2D
var slots_container: HBoxContainer

func _ready() -> void:
	atlas = load(BlockDB.ATLAS_PATH)
	if atlas == null:
		push_error("Hotbar: atlas not found at %s" % BlockDB.ATLAS_PATH)

	# ---- Layout: bottom-center, full width strip ----
	anchor_left = 0.0
	anchor_right = 1.0
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = 0
	offset_right = 0
	offset_bottom = -bottom_margin
	# height = scaled slot height + vertical padding*2
	var bar_h := slot_size.y * ui_scale + bar_padding.y * 2.0
	offset_top = -bottom_margin - bar_h
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Create/find container and center it
	slots_container = $Slots if has_node("Slots") else HBoxContainer.new()
	if slots_container.get_parent() == null:
		slots_container.name = "Slots"
		add_child(slots_container)
	slots_container.anchor_left = 0.0
	slots_container.anchor_right = 1.0
	slots_container.anchor_top = 0.0
	slots_container.anchor_bottom = 1.0
	slots_container.offset_left = bar_padding.x
	slots_container.offset_right = -bar_padding.x
	slots_container.offset_top = bar_padding.y
	slots_container.offset_bottom = -bar_padding.y
	slots_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slots_container.size_flags_vertical = Control.SIZE_FILL
	slots_container.alignment = BoxContainer.ALIGNMENT_CENTER
	slots_container.add_theme_constant_override("separation", int(slot_separation * ui_scale))

	_build_slots()
	_update_selection()

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		if visible:
			# run after the layout container has finished assigning rects
			call_deferred("_update_selection")

func reapply_selection() -> void:
	call_deferred("_update_selection")

func _build_slots() -> void:
	for c in slots_container.get_children():
		c.queue_free()

	var final_slot := slot_size * ui_scale

	for i in SLOT_COUNT:
		# Parent container controls selection tint/scale
		var slot := Control.new()
		slot.custom_minimum_size = final_slot
		slot.pivot_offset = final_slot * 0.5   # 👈 scale around center
		
		slot.name = "Slot%d" % i
		slot.custom_minimum_size = final_slot
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.pivot_offset = final_slot * 0.5
		slot.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		slot.size_flags_vertical   = Control.SIZE_SHRINK_CENTER

		# Icon child holds the texture and empty-state fade
		var icon := TextureRect.new()
		icon.name = "Icon"
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		#icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		# Fill parent
		icon.anchor_left = 0; icon.anchor_top = 0
		icon.anchor_right = 1; icon.anchor_bottom = 1
		icon.offset_left = 0; icon.offset_top = 0
		icon.offset_right = 0; icon.offset_bottom = 0

		slot.add_child(icon)
		_set_slot_icon(icon, block_ids[i])

		# Selected-border child (on top)
		var border := Panel.new()
		border.name = "Border"
		border.mouse_filter = Control.MOUSE_FILTER_IGNORE
		border.add_theme_constant_override("border_width", int(2 * ui_scale))
		border.add_theme_color_override("border_color", Color(1,1,1))
		border.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
		border.visible = false
		border.anchor_left = 0; border.anchor_top = 0
		border.anchor_right = 1; border.anchor_bottom = 1
		border.offset_left = 0; border.offset_top = 0
		border.offset_right = 0; border.offset_bottom = 0
		slot.add_child(border)
		
		# Count label (bottom-right)
		var label := Label.new()
		label.name = "Count"
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		label.vertical_alignment   = VERTICAL_ALIGNMENT_BOTTOM
		label.anchor_left = 0; label.anchor_top = 0
		label.anchor_right = 1; label.anchor_bottom = 1
		label.offset_right = -int(4 * ui_scale)
		label.offset_bottom = -int(2 * ui_scale)
		label.add_theme_font_size_override("font_size", int(10 * ui_scale))
		label.add_theme_constant_override("outline_size", 2)
		label.add_theme_color_override("font_outline_color", Color(0,0,0,0.9))
		slot.add_child(label)
		label.text = _count_text(i)
		
		var sb := StyleBoxFlat.new()
		sb.draw_center = false
		sb.border_width_left = int(2 * ui_scale)
		sb.border_width_top = int(2 * ui_scale)
		sb.border_width_right = int(2 * ui_scale)
		sb.border_width_bottom = int(2 * ui_scale)
		sb.border_color = Color(1, 1, 1)   # highlight color
		border.add_theme_stylebox_override("panel", sb)

		slots_container.add_child(slot)

func _set_slot_icon(icon: TextureRect, id: int) -> void:
	if id < 0:
		icon.texture = null
		icon.self_modulate = Color(1, 1, 1, 0.18) # faded empty
		return
	icon.self_modulate = Color(1, 1, 1, 1)
	var tile := BlockDB.get_face_tile(id, 2)
	var region := BlockDB.tile_region_rect(tile)
	var at := AtlasTexture.new()
	at.atlas = atlas
	at.region = region
	icon.texture = at

func _count_text(i: int) -> String:
	return (str(counts[i]) if block_ids[i] >= 0 and counts[i] > 1 else "")

func _clamp_counts() -> void:
	for i in SLOT_COUNT:
		if block_ids[i] < 0 or counts[i] <= 0:
			block_ids[i] = -1
			counts[i] = 0
		elif counts[i] > MAX_STACK:
			counts[i] = MAX_STACK


func _update_selection() -> void:
	for i in SLOT_COUNT:
		var slot := slots_container.get_node_or_null("Slot%d" % i) as Control
		if slot:
			var is_sel := (i == selected)

			# Lighten selected container, dim others
			slot.self_modulate = (Color(1.1, 1.1, 1.1, 1) if is_sel else Color(0.8, 0.8, 0.8, 1))
			# Scale bump on the container (icon + border follow)
			slot.scale = (Vector2(1.15, 1.15) if is_sel else Vector2.ONE)

			var border := slot.get_node_or_null("Border") as Panel
			if border:
				border.visible = is_sel

	emit_signal("selected_changed", selected, block_ids[selected])


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed:
		var n = e.keycode - KEY_1
		if n >= 0 and n < SLOT_COUNT:
			selected = n
			_update_selection()
	elif e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			selected = (selected + SLOT_COUNT - 1) % SLOT_COUNT
			_update_selection()
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			selected = (selected + 1) % SLOT_COUNT
			_update_selection()

func current_block_id() -> int:
	return block_ids[selected]

func _refresh_icons_only() -> void:
	for i in SLOT_COUNT:
		var slot := slots_container.get_node_or_null("Slot%d" % i) as Control
		if slot:
			var icon := slot.get_node_or_null("Icon") as TextureRect
			if icon:
				_set_slot_icon(icon, block_ids[i])
			var label := slot.get_node_or_null("Count") as Label
			if label:
				label.text = _count_text(i)

# Add at bottom of Hotbar.gd
func get_ids() -> Array[int]:
	var out: Array[int] = []
	out.resize(block_ids.size())
	for i in block_ids.size():
		out[i] = int(block_ids[i])
	return out

func set_ids(ids: Array[int]) -> void:
	block_ids.resize(SLOT_COUNT)
	for i in SLOT_COUNT:
		block_ids[i] = (int(ids[i]) if i < ids.size() else -1)
	_refresh_icons_only()
	_update_selection()

func get_counts() -> Array[int]:
	var out: Array[int] = []
	out.resize(counts.size())
	for i in counts.size():
		out[i] = int(counts[i])
	return out

func set_counts(cs: Array[int]) -> void:
	counts.resize(SLOT_COUNT)
	for i in SLOT_COUNT:
		counts[i] = (int(cs[i]) if i < cs.size() else 0)
	_clamp_counts()
	_refresh_icons_only()

func set_ids_counts(ids: Array[int], cs: Array[int]) -> void:
	set_ids(ids)
	set_counts(cs)
	_update_selection()

func get_ids_counts() -> Dictionary:
	return { "ids": get_ids(), "counts": get_counts() }

func current_stack() -> Dictionary:
	return { "id": block_ids[selected], "count": counts[selected] }

func can_place_selected() -> bool:
	return selected >= 0 \
		and selected < SLOT_COUNT \
		and block_ids[selected] >= 0 \
		and counts[selected] > 0

func consume_selected(n:int = 1) -> bool:
	if not can_place_selected():
		return false
	counts[selected] -= n
	if counts[selected] <= 0:
		counts[selected] = 0
		block_ids[selected] = -1  # clear icon when empty
	_clamp_counts()
	_refresh_icons_only()
	# re-emit so Player updates its current_block_id if the slot went empty
	emit_signal("selected_changed", selected, block_ids[selected])
	return true
