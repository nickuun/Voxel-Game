extends Control
class_name InventoryUI

# ----- NODE REFS -----
@onready var center          : CenterContainer  = $CenterContainer
@onready var panel           : PanelContainer            = $CenterContainer/Panel
@onready var content         : HBoxContainer    = $CenterContainer/Panel/Margin/VBox/Content

@onready var chest_panel     : PanelContainer            = $CenterContainer/Panel/Margin/VBox/Content/ChestPanel
@onready var backpack_panel  : PanelContainer            = $CenterContainer/Panel/Margin/VBox/Content/BackpackPanel

@onready var chest_pane      : VBoxContainer    = $CenterContainer/Panel/Margin/VBox/Content/ChestPanel/ChestPane
@onready var backpack_pane   : VBoxContainer    = $CenterContainer/Panel/Margin/VBox/Content/BackpackPanel/BackpackPane

@onready var chest_grid      : GridContainer    = $CenterContainer/Panel/Margin/VBox/Content/ChestPanel/ChestPane/ChestGrid
@onready var inv_grid        : GridContainer    = $CenterContainer/Panel/Margin/VBox/Content/BackpackPanel/BackpackPane/InvGrid
@onready var bar_grid        : GridContainer    = $CenterContainer/Panel/Margin/VBox/Content/BackpackPanel/BackpackPane/BarGrid

@onready var hotbar          : Hotbar           = $"../Hotbar"

# ----- INVENTORY DATA -----
const MAX_STACK := 99

var inv_counts: Array[int] = []
var bar_counts: Array[int] = []
var chest_counts: Array[int] = []


const INV_COLS := 10
const INV_ROWS := 5

var inv_ids: Array[int] = []
var bar_ids: Array[int] = []

var _open: bool = false
var _chest: Chest = null
var chest_ids: Array[int] = []

const DEBUG_SEED := true   # flip to false for release

const DEBUG_INV_LOG := true

var _hover_slot: ItemSlot = null

# ----- SETUP -----
func _ready() -> void:
	add_to_group("inventory_ui")
	# 0) make root fill screen and center things
	set_anchors_preset(Control.PRESET_FULL_RECT)
	center.set_anchors_preset(Control.PRESET_FULL_RECT)

	# 1) no manual sizes anywhere; let containers work
	panel.clip_contents = true  # safety if we ever overflow

	# 2) HBox should center its children
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.size_flags_horizontal = 0  # don't force expand; center within panel

	# 3) Panels should be centered within their own column
	for p in [chest_panel, backpack_panel]:
		p.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		p.size_flags_vertical   = Control.SIZE_SHRINK_CENTER

	# 4) Panes expand to their panel
	for p in [chest_pane, backpack_pane]:
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# (mouse filter keep as you had if you need it)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for n in [panel, content, chest_panel, backpack_panel, chest_pane, backpack_pane, inv_grid, bar_grid, chest_grid]:
		(n as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 5) Start hidden
	visible = false
	panel.visible = false
	chest_panel.visible = false

	# 6) Data init
	inv_ids.resize(INV_COLS * INV_ROWS)
	for i in inv_ids.size(): inv_ids[i] = -1
	
	inv_counts.resize(INV_COLS * INV_ROWS)
	for i in inv_counts.size(): inv_counts[i] = 0


	# 7) Grid config
	inv_grid.columns = INV_COLS
	inv_grid.add_theme_constant_override("h_separation", 40)
	inv_grid.add_theme_constant_override("v_separation", 40)

	bar_grid.columns = 9
	bar_grid.add_theme_constant_override("h_separation", 80)

	chest_grid.columns = 9
	chest_grid.add_theme_constant_override("h_separation", 40)
	chest_grid.add_theme_constant_override("v_separation", 40)
	
	if DEBUG_SEED:
		_seed_player_inventory()

	# 8) Build slots
	_build_inv_slots()
	_build_bar_slots_from_hotbar()

	# 9) React to viewport resize
	get_viewport().size_changed.connect(func(): call_deferred("_reflow"))

	# 10) First layout
	call_deferred("_reflow")

func _seed_player_inventory() -> void:
	var seed: Array[int] = [
		BlockDB.BlockId.MOSSY_STONE_BRICKS, BlockDB.BlockId.MOSSY_COBBLE, BlockDB.BlockId.SNOW_DIRT,
		BlockDB.BlockId.ICE, BlockDB.BlockId.CLAY_TILE, BlockDB.BlockId.LOG_JUNGLE, BlockDB.BlockId.WOOD_JUNGLE,
		BlockDB.BlockId.LOG_ACACIA, BlockDB.BlockId.WOOD_ACACIA, BlockDB.BlockId.LOG_SPRUCE, BlockDB.BlockId.WOOD_SPRUCE,
		BlockDB.BlockId.WOOD_BIRCH, BlockDB.BlockId.LOG_BIRCH, BlockDB.BlockId.CHEST
	]
	var seed_counts: Array[int] = [12, 20, 64, 3, 48, 15, 6, 9, 99, 7, 2, 1, 25, 1]

	var write_i := 0
	for i in inv_ids.size():
		if write_i >= seed.size(): break
		if inv_ids[i] == -1:
			inv_ids[i] = seed[write_i]
			inv_counts[i] = clamp(seed_counts[write_i], 1, MAX_STACK)
			write_i += 1

# ----- LAYOUT (simple, unbreakable) -----
func _reflow() -> void:
	# Only decide who is visible and how the row splits.
	var chest_visible := _chest != null and _open
	chest_panel.visible = chest_visible
	chest_pane.visible  = chest_visible

	# Row split: backpack:chest = 2:1 when both shown; otherwise just backpack
	backpack_panel.size_flags_stretch_ratio = 1.0
	if chest_visible:
		backpack_panel.size_flags_stretch_ratio = 2.0
	else:
		backpack_panel.size_flags_stretch_ratio = 1.0
			
		
		
	chest_panel.size_flags_stretch_ratio    = 1.0

	# Let containers update, then log
	await get_tree().process_frame
	_log_layout("reflow")

# ----- BUILDERS -----
func _build_inv_slots() -> void:
	for c in inv_grid.get_children():
		c.queue_free()
	for i in inv_ids.size():
		var s: ItemSlot = ItemSlot.new()
		s.slot_size = Vector2(88, 88)
		inv_grid.add_child(s)
		s.bind(inv_ids, i, inv_counts)
		s.set_meta("area", "inv")
		s.changed.connect(_on_any_slot_changed)
		s.quick_move.connect(_on_quick_move)
		s.mouse_entered.connect(_on_slot_entered.bind(s))
		s.mouse_exited.connect(_on_slot_exited.bind(s))

func _build_bar_slots_from_hotbar() -> void:
	bar_ids = hotbar.get_ids()
	bar_counts = hotbar.get_counts()
	for c in bar_grid.get_children():
		c.queue_free()
	for i in bar_ids.size():
		var s: ItemSlot = ItemSlot.new()
		s.slot_size = Vector2(88, 88)
		bar_grid.add_child(s)
		s.bind(bar_ids, i, bar_counts)
		s.set_meta("area", "bar")
		s.changed.connect(_on_any_slot_changed)
		s.quick_move.connect(_on_quick_move)
		s.mouse_entered.connect(_on_slot_entered.bind(s))
		s.mouse_exited.connect(_on_slot_exited.bind(s))


func _build_chest_slots() -> void:
	for c in chest_grid.get_children(): c.queue_free()
	if _chest == null: return
	chest_ids    = _chest.get_ids()
	# if your Chest already has counts; otherwise create zeros of same size
	chest_counts = (_chest.get_counts() if _chest.has_method("get_counts") else [])
	if chest_counts.is_empty():
		chest_counts.resize(chest_ids.size())
		for i in chest_counts.size(): chest_counts[i] = 0
	for i in chest_ids.size():
		var s := ItemSlot.new()
		s.slot_size = Vector2(88, 88)
		chest_grid.add_child(s)
		s.bind(chest_ids, i, chest_counts) # <—
		s.changed.connect(_on_any_slot_changed)


func _on_slot_entered(slot: ItemSlot) -> void:
	_hover_slot = slot

func _on_slot_exited(slot: ItemSlot) -> void:
	if _hover_slot == slot:
		_hover_slot = null

func _on_quick_move(slot: ItemSlot) -> void:
	var area_any: Variant = slot.get_meta("area")
	var area: String = String(area_any)
	if area == "bar":
		_quick_move_from_bar_index(slot.index)
	elif area == "inv":
		_quick_move_from_inv_index(slot.index)
	_refresh_all_slots()

func _quick_move_from_bar_index(i: int) -> void:
	if i < 0 or i >= bar_ids.size():
		return
	var id: int = bar_ids[i]
	var ct: int = bar_counts[i]
	if id < 0 or ct <= 0:
		return
	var left: int = _merge_into_existing(inv_ids, inv_counts, id, ct)
	left = _fill_empty_slots(inv_ids, inv_counts, id, left)
	var moved: int = ct - left
	if moved > 0:
		bar_counts[i] = bar_counts[i] - moved
		if bar_counts[i] <= 0:
			bar_counts[i] = 0
			bar_ids[i] = -1

func _quick_move_from_inv_index(i: int) -> void:
	if i < 0 or i >= inv_ids.size():
		return
	var id: int = inv_ids[i]
	var ct: int = inv_counts[i]
	if id < 0 or ct <= 0:
		return
	var left: int = _merge_into_existing(bar_ids, bar_counts, id, ct)
	left = _fill_empty_slots(bar_ids, bar_counts, id, left)
	var moved: int = ct - left
	if moved > 0:
		inv_counts[i] = inv_counts[i] - moved
		if inv_counts[i] <= 0:
			inv_counts[i] = 0
			inv_ids[i] = -1

func _unhandled_input(e: InputEvent) -> void:
	if not _open:
		return

	if e is InputEventKey and e.pressed:
		var k: InputEventKey = e

		# ESC closes inventory
		if k.keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()
			return

		# number keys 1..9 map to bar slots 0..8
		var n: int = k.keycode - KEY_1
		if n >= 0 and n < 9:
			_on_hotbar_number(n)

func _on_hotbar_number(n: int) -> void:
	if _hover_slot == null:
		return
	var area_any: Variant = _hover_slot.get_meta("area")
	var area: String = String(area_any)

	if area == "bar":
		var h: int = _hover_slot.index
		if h == n:
			_quick_move_from_bar_index(h)   # same number over same slot → send to backpack
		else:
			_swap_bar_slots(h, n)          # swap bar slots
	elif area == "inv":
		_swap_inv_bar(_hover_slot.index, n) # swap inv <-> bar[n]

	_refresh_all_slots()

func _swap_bar_slots(i: int, j: int) -> void:
	if i < 0 or j < 0 or i >= bar_ids.size() or j >= bar_ids.size():
		return
	var id_i: int = bar_ids[i]
	var ct_i: int = bar_counts[i]
	bar_ids[i] = bar_ids[j]
	bar_counts[i] = bar_counts[j]
	bar_ids[j] = id_i
	bar_counts[j] = ct_i
	
func _swap_inv_bar(inv_i: int, bar_i: int) -> void:
	if inv_i < 0 or inv_i >= inv_ids.size():
		return
	if bar_i < 0 or bar_i >= bar_ids.size():
		return
	var id_i: int = inv_ids[inv_i]
	var ct_i: int = inv_counts[inv_i]
	inv_ids[inv_i] = bar_ids[bar_i]
	inv_counts[inv_i] = bar_counts[bar_i]
	bar_ids[bar_i] = id_i
	bar_counts[bar_i] = ct_i


# ----- OPEN/CLOSE -----

func open_with_chest(chest: Chest) -> void:
	_chest = chest
	if not _open:
		open()
	else:
		_build_chest_slots()
		call_deferred("_reflow")

func open() -> void:
	if _open: return
	_open = true
	bar_ids = hotbar.get_ids()
	bar_counts = hotbar.get_counts()
	for i in bar_grid.get_child_count():
		(bar_grid.get_child(i) as ItemSlot).bind(bar_ids, i, bar_counts)
	visible = true
	panel.visible = true
	hotbar.visible = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	chest_panel.visible = _chest != null
	if _chest: _build_chest_slots()
	call_deferred("_reflow")

func close() -> void:
	if not _open: return
	_open = false
	visible = false
	panel.visible = false
	hotbar.visible = true
	hotbar.reapply_selection()
	hotbar.set_ids_counts(bar_ids, bar_counts)   # <—
	if _chest:
		if _chest.has_method("set_ids_counts"):
			_chest.set_ids_counts(chest_ids, chest_counts)
		else:
			_chest.set_ids(chest_ids) # fallback
	_chest = null
	chest_panel.visible = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	call_deferred("_reflow")

func _refresh_all_slots() -> void:
	for grid in [inv_grid, bar_grid, chest_grid]:
		for c in grid.get_children():
			if c and c.has_method("refresh"):
				c.refresh()

func _merge_into_existing(ids: Array[int], counts: Array[int], id: int, add: int) -> int:
	if add <= 0: return 0
	for i in ids.size():
		if ids[i] == id and counts[i] < MAX_STACK:
			var space := MAX_STACK - counts[i]
			var take = min(space, add)
			counts[i] += take
			add -= take
			if add == 0: break
	return add

func _fill_empty_slots(ids: Array[int], counts: Array[int], id: int, add: int) -> int:
	if add <= 0: return 0
	for i in ids.size():
		if ids[i] < 0 or counts[i] <= 0:
			var take = min(MAX_STACK, add)
			ids[i] = id
			counts[i] = take
			add -= take
			if add == 0: break
	return add

# public API: try add, prefer hotbar first
# ===================== DEBUG HELPERS =====================

func _dbg(msg:String) -> void:
	if DEBUG_INV_LOG:
		print(msg)

func _block_name(id:int) -> String:
	return BlockDB.BLOCKS.get(id, {}).get("name", "id"+str(id))

func _snapshot(ids:Array[int], counts:Array[int]) -> String:
	var parts := []
	var n = min(ids.size(), counts.size())
	for i in n:
		var id := ids[i]
		var c  := counts[i]
		if id < 0 or c <= 0:
			parts.append("·")     # empty
		else:
			parts.append("%s(%d):%d" % [_block_name(id), id, c])
	return "[" + ", ".join(parts) + "]"

func _log_diff(label:String, ids_before:Array[int], cs_before:Array[int],
			   ids_after:Array[int],  cs_after:Array[int]) -> void:
	if not DEBUG_INV_LOG: return
	var changes := []
	var n = min(ids_after.size(), ids_before.size())
	for i in n:
		var ib := ids_before[i]; var ia := ids_after[i]
		var cb := cs_before[i];  var ca := cs_after[i]
		if ib == ia:
			if cb != ca and ia >= 0:
				changes.append("%s[%d] %s(%d): %d -> %d (%+d)"
					% [label, i, _block_name(ia), ia, cb, ca, ca-cb])
		else:
			var from := ("·" if ib < 0 or cb <= 0 else "%s(%d):%d" % [_block_name(ib), ib, cb])
			var to   := ("·" if ia < 0 or ca <= 0 else "%s(%d):%d" % [_block_name(ia), ia, ca])
			changes.append("%s[%d] %s -> %s" % [label, i, from, to])
	if changes.is_empty():
		_dbg("  %s: no changes" % label)
	else:
		_dbg("  %s changes:\n   - %s" % [label, "\n   - ".join(changes)])

func _sum_in(id:int, ids:Array[int], counts:Array[int]) -> int:
	var s := 0
	for i in ids.size():
		if i < counts.size() and ids[i] == id:
			s += max(0, counts[i])
	return s

# ===================== ADD ITEMS (with heavy logs) =====================
# public API: try add, prefer HOTBAR first (merge -> empties), then INVENTORY (merge -> empties)
func add_items(id: int, amount: int) -> int:
	if amount <= 0: return 0

	# keep arrays sane even if UI hasn’t been opened yet
	if inv_ids.is_empty():
		inv_ids.resize(INV_COLS * INV_ROWS)
		for i in inv_ids.size(): inv_ids[i] = -1
	if inv_counts.size() != inv_ids.size():
		inv_counts.resize(inv_ids.size())

	# when closed, mirror latest hotbar contents
	if not _open and is_instance_valid(hotbar):
		bar_ids = hotbar.get_ids()
		bar_counts = hotbar.get_counts()

	_dbg("\n=== ADD %s(%d) x%d ===" % [_block_name(id), id, amount])
	_dbg("  BEFORE bar: " + _snapshot(bar_ids, bar_counts))
	_dbg("  BEFORE inv: " + _snapshot(inv_ids, inv_counts))
	_dbg("  totals for this id -> bar:%d inv:%d"
		% [_sum_in(id, bar_ids, bar_counts), _sum_in(id, inv_ids, inv_counts)])

	# ---- Step 1: merge into existing HOTBAR stacks ----
	var a0 := amount
	var b_ids := bar_ids.duplicate(); var b_cts := bar_counts.duplicate()
	amount = _merge_into_existing(bar_ids, bar_counts, id, amount)
	_dbg("Step1 merge→bar: placed %d, leftover %d" % [a0-amount, amount])
	_log_diff("bar", b_ids, b_cts, bar_ids, bar_counts)

	# ---- Step 2: fill empty HOTBAR slots ----
	a0 = amount
	b_ids = bar_ids.duplicate(); b_cts = bar_counts.duplicate()
	amount = _fill_empty_slots(bar_ids, bar_counts, id, amount)
	_dbg("Step2 fill-empties→bar: placed %d, leftover %d" % [a0-amount, amount])
	_log_diff("bar", b_ids, b_cts, bar_ids, bar_counts)

	# ---- Step 3: merge into existing INVENTORY stacks ----
	a0 = amount
	var i_ids := inv_ids.duplicate(); var i_cts := inv_counts.duplicate()
	amount = _merge_into_existing(inv_ids, inv_counts, id, amount)
	_dbg("Step3 merge→inv: placed %d, leftover %d" % [a0-amount, amount])
	_log_diff("inv", i_ids, i_cts, inv_ids, inv_counts)

	# ---- Step 4: fill empty INVENTORY slots ----
	a0 = amount
	i_ids = inv_ids.duplicate(); i_cts = inv_counts.duplicate()
	amount = _fill_empty_slots(inv_ids, inv_counts, id, amount)
	_dbg("Step4 fill-empties→inv: placed %d, leftover %d" % [a0-amount, amount])
	_log_diff("inv", i_ids, i_cts, inv_ids, inv_counts)

	# ---- Final snapshots ----
	_dbg("  AFTER  bar: " + _snapshot(bar_ids, bar_counts))
	_dbg("  AFTER  inv: " + _snapshot(inv_ids, inv_counts))
	_dbg("  totals for this id -> bar:%d inv:%d  | leftover:%d"
		% [_sum_in(id, bar_ids, bar_counts), _sum_in(id, inv_ids, inv_counts), amount])

	_refresh_all_slots()

	# push back to hotbar if UI is closed
	if not _open and is_instance_valid(hotbar):
		hotbar.set_ids_counts(bar_ids, bar_counts)

	return amount  # leftover if everything full


func remove_items(id: int, amount: int) -> int:
	var need := amount
	if not _open and is_instance_valid(hotbar):
		bar_ids = hotbar.get_ids()
		bar_counts = hotbar.get_counts()

	for i in bar_ids.size():
		if bar_ids[i] == id and bar_counts[i] > 0:
			var take = min(bar_counts[i], need)
			bar_counts[i] -= take
			need -= take
			if bar_counts[i] <= 0: bar_ids[i] = -1
			if need == 0: break

	for i in inv_ids.size():
		if need == 0: break
		if inv_ids[i] == id and inv_counts[i] > 0:
			var take = min(inv_counts[i], need)
			inv_counts[i] -= take
			need -= take
			if inv_counts[i] <= 0: inv_ids[i] = -1

	_refresh_all_slots()
	if not _open and is_instance_valid(hotbar):
		hotbar.set_ids_counts(bar_ids, bar_counts)
	return need


# ----- LOGGING -----
func _log_layout(tag: String) -> void:
	var vs = get_viewport_rect().size
	var pmin = panel.get_combined_minimum_size()
	var p = panel.get_global_rect()
	var cmin = content.get_combined_minimum_size()
	var c = content.get_global_rect()
	var bmin = backpack_panel.get_combined_minimum_size()
	var b = backpack_panel.get_global_rect()
	var chmin = chest_panel.get_combined_minimum_size()
	var ch = chest_panel.get_global_rect()
	var igrid = inv_grid.get_combined_minimum_size()
	var bgrid = bar_grid.get_combined_minimum_size()
	var cgrid = chest_grid.get_combined_minimum_size()

	#print("\n=== INV LAYOUT [", tag, "] ===")
	#print("viewport:      ", vs)
	#print("panel rect:    ", p, "  min:", pmin)
	#print("content rect:  ", c, "  min:", cmin, "  sep:", content.get_theme_constant("separation"))
	#print("backpack rect: ", b, "  min:", bmin)
	#print("chest rect:    ", ch, "  min:", chmin, "  visible:", chest_panel.visible)
	#print("inv_grid min:  ", igrid, "  cols:", inv_grid.columns)
	#print("bar_grid min:  ", bgrid, "  cols:", bar_grid.columns)
	#print("chest_grid min:", cgrid, "  cols:", chest_grid.columns)
	#print("=============================\n")

func _on_any_slot_changed() -> void:
	pass


func toggle() -> void:
	if _open: 
		close()
	else: open()

func is_open() -> bool:
	return _open
