extends Label
class_name DevCoordsOverlay

@export var player_body: Node3D
@export_enum("XYZ", "XZY", "YXZ", "YZX", "ZXY", "ZYX")
var axis_order: String = "ZYX"

# chunk size
@export var units_per_chunk: float = 16.0

# F3 toggle
@export var toggle_action: String = "dev_coords_toggle"

var _visible_on: bool = true
var _max_width: float = 0.0

func _ready() -> void:
	_ensure_default_input()
	_update_text()

func _process(delta: float) -> void:
	if not _visible_on:
		visible = false
		return
	visible = true
	_update_text()

func _unhandled_input(event: InputEvent) -> void:
	if Input.is_action_just_pressed(toggle_action):
		_visible_on = not _visible_on

func _update_text() -> void:
	if player_body == null:
		text = "No player set"
		_lock_width_to_current()
		return

	var p: Vector3 = player_body.global_transform.origin
	var names: PackedStringArray = _ordered_names()
	var values: PackedFloat32Array = _ordered_values(p)

	# integers only (no decimals)
	var world0: int = roundi(values[0])
	var world1: int = roundi(values[1])
	var world2: int = roundi(values[2])

	var scale: float = units_per_chunk
	if scale == 0.0:
		scale = 1.0

	# chunk indices (floor)
	var idx0: int = int(floor(values[0] / scale))
	var idx1: int = int(floor(values[1] / scale))
	var idx2: int = int(floor(values[2] / scale))

	var s0: String = names[0] + ": " + _fmt_i(world0) + " (" + _fmt_i(idx0) + ")"
	var s1: String = names[1] + ": " + _fmt_i(world1) + " (" + _fmt_i(idx1) + ")"
	var s2: String = names[2] + ": " + _fmt_i(world2) + " (" + _fmt_i(idx2) + ")"

	text = s0 + " | " + s1 + " | " + s2
	_lock_width_to_current()

func _fmt_i(v: int) -> String:
	# Signed, no zero-padding. If you don't want the '+' for positives, use "%d" instead.
	return "%+d" % v

func _ordered_values(p: Vector3) -> PackedFloat32Array:
	var vals: PackedFloat32Array = PackedFloat32Array()
	if axis_order == "XYZ":
		vals.push_back(p.x); vals.push_back(p.y); vals.push_back(p.z)
	elif axis_order == "XZY":
		vals.push_back(p.x); vals.push_back(p.z); vals.push_back(p.y)
	elif axis_order == "YXZ":
		vals.push_back(p.y); vals.push_back(p.x); vals.push_back(p.z)
	elif axis_order == "YZX":
		vals.push_back(p.y); vals.push_back(p.z); vals.push_back(p.x)
	elif axis_order == "ZXY":
		vals.push_back(p.z); vals.push_back(p.x); vals.push_back(p.y)
	else:
		vals.push_back(p.z); vals.push_back(p.y); vals.push_back(p.x) # ZYX default
	return vals

func _ordered_names() -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	if axis_order == "XYZ":
		names.push_back("X"); names.push_back("Y"); names.push_back("Z")
	elif axis_order == "XZY":
		names.push_back("X"); names.push_back("Z"); names.push_back("Y")
	elif axis_order == "YXZ":
		names.push_back("Y"); names.push_back("X"); names.push_back("Z")
	elif axis_order == "YZX":
		names.push_back("Y"); names.push_back("Z"); names.push_back("X")
	elif axis_order == "ZXY":
		names.push_back("Z"); names.push_back("X"); names.push_back("Y")
	else:
		names.push_back("Z"); names.push_back("Y"); names.push_back("X")
	return names

func _lock_width_to_current() -> void:
	# Grow-only min width so the label doesn’t jitter as digits change.
	var w: float = get_minimum_size().x
	if w > _max_width:
		_max_width = w
		custom_minimum_size = Vector2(_max_width, custom_minimum_size.y)

func _ensure_default_input() -> void:
	if not InputMap.has_action(toggle_action):
		InputMap.add_action(toggle_action)

	var ev1: InputEventKey = InputEventKey.new()
	ev1.physical_keycode = Key.KEY_F3
	if not InputMap.action_has_event(toggle_action, ev1):
		InputMap.action_add_event(toggle_action, ev1)

	var ev2: InputEventKey = InputEventKey.new()
	ev2.physical_keycode = Key.KEY_F3
	if not InputMap.action_has_event(toggle_action, ev2):
		InputMap.action_add_event(toggle_action, ev2)
