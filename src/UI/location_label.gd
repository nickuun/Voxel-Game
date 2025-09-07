extends Label
class_name DevCoordsOverlay

@export var player_body: Node3D
@export_enum("XYZ", "XZY", "YXZ", "YZX", "ZXY", "ZYX")
var axis_order: String = "ZYX"
@export var decimals: int = 2
@export var block_size_units: float = 16.0
@export var toggle_action: String = "dev_coords_toggle"

var _visible_on: bool = true

func _ready() -> void:
	_ensure_default_input()
	_update_text(0.0)

func _process(delta: float) -> void:
	if not _visible_on:
		visible = false
		return
	visible = true
	_update_text(delta)

func _unhandled_input(event: InputEvent) -> void:
	if Input.is_action_just_pressed(toggle_action):
		_visible_on = not _visible_on

func _update_text(delta: float) -> void:
	if player_body == null:
		text = "No player set"
		return

	var p: Vector3 = player_body.global_transform.origin
	var names: PackedStringArray = _ordered_names()
	var values: PackedFloat32Array = _ordered_values(p)

	var bx: int = 0
	var by: int = 0
	var bz: int = 0

	if block_size_units == 0.0:
		block_size_units = 1.0

	# Compute block indices by axis using the same order mapping
	var block_vals: PackedFloat32Array = PackedFloat32Array()
	block_vals.push_back(floor(values[0] / block_size_units))
	block_vals.push_back(floor(values[1] / block_size_units))
	block_vals.push_back(floor(values[2] / block_size_units))

	# Format: "Z: 12.34 (0) | Y: 64.00 (4) | X: -3.00 (-1)"
	var s0: String = names[0] + ": " + _fmt(values[0]) + " (" + str(int(block_vals[0])) + ")"
	var s1: String = names[1] + ": " + _fmt(values[1]) + " (" + str(int(block_vals[1])) + ")"
	var s2: String = names[2] + ": " + _fmt(values[2]) + " (" + str(int(block_vals[2])) + ")"
	text = s0 + " | " + s1 + " | " + s2

func _fmt(v: float) -> String:
	var f: float = roundf(v * pow(10.0, float(decimals))) / pow(10.0, float(decimals))
	return str(f)

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

func _ensure_default_input() -> void:
	var has: bool = InputMap.has_action(toggle_action)
	if not has:
		InputMap.add_action(toggle_action)
	var ev: InputEventKey = InputEventKey.new()
	ev.physical_keycode = Key.KEY_F3
	var already: bool = InputMap.action_has_event(toggle_action, ev)
	if not already:
		InputMap.action_add_event(toggle_action, ev)
