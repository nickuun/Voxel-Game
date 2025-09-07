extends Node
class_name DevFreecamController

@export var move_speed: float = 8.0
@export var fast_multiplier: float = 4.0
@export var mouse_sensitivity: float = 0.0025
@export var toggle_action: String = "dev_freecam_toggle"

var _active: bool = false
var _rig: Node3D = null
var _pitch_node: Node3D = null
var _cam: Camera3D = null
var _prev_cam: Camera3D = null
var _yaw: float = 0.0
var _pitch: float = 0.0
var _prev_mouse_mode: int = Input.MOUSE_MODE_VISIBLE

func _ready() -> void:
	_ensure_default_input()

func _process(delta: float) -> void:
	if _active and _rig != null:
		var velocity: Vector3 = _get_input_direction() * _current_speed() * delta
		_rig.global_translate(velocity)

func _unhandled_input(event: InputEvent) -> void:
	if Input.is_action_just_pressed(toggle_action):
		_toggle_freecam()
		return

	if _active and event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		_yaw -= mm.relative.x * mouse_sensitivity
		_pitch -= mm.relative.y * mouse_sensitivity
		if _pitch > deg_to_rad(89.9):
			_pitch = deg_to_rad(89.9)
		if _pitch < deg_to_rad(-89.9):
			_pitch = deg_to_rad(-89.9)
		if _rig != null:
			_rig.rotation.y = _yaw
		if _pitch_node != null:
			_pitch_node.rotation.x = _pitch

func _toggle_freecam() -> void:
	if _active:
		_deactivate_freecam()
	else:
		_activate_freecam()

func _activate_freecam() -> void:
	_prev_cam = get_viewport().get_camera_3d()
	if _prev_cam == null:
		push_warning("DevFreecamController: No current Camera3D found to copy from.")
		return

	_rig = Node3D.new()
	_pitch_node = Node3D.new()
	_cam = Camera3D.new()

	_rig.name = "FreecamRig"
	_pitch_node.name = "FreecamPitch"
	_cam.name = "Freecam"

	# Place rig at current camera transform
	var xf: Transform3D = _prev_cam.global_transform
	_rig.global_transform = Transform3D(xf.basis, xf.origin)

	# Derive yaw/pitch from current forward
	var forward: Vector3 = -xf.basis.z.normalized()
	_yaw = atan2(forward.x, forward.z)
	_pitch = asin(forward.y)
	_rig.rotation = Vector3(0.0, _yaw, 0.0)
	_pitch_node.rotation = Vector3(_pitch, 0.0, 0.0)

	# Build hierarchy: rig -> pitch -> cam
	add_child(_rig)
	_rig.add_child(_pitch_node)
	_pitch_node.add_child(_cam)

	# Mirror key camera properties so it feels identical
	_cam.fov = _prev_cam.fov
	_cam.near = _prev_cam.near
	_cam.far = _prev_cam.far
	_cam.current = true

	# Capture mouse for mouselook
	_prev_mouse_mode = Input.get_mouse_mode()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	_active = true

func _deactivate_freecam() -> void:
	Input.set_mouse_mode(_prev_mouse_mode)

	if _cam != null:
		_cam.current = false
	if _prev_cam != null and is_instance_valid(_prev_cam):
		_prev_cam.current = true

	if _rig != null:
		_rig.queue_free()
	if _pitch_node != null:
		_pitch_node.queue_free()
	if _cam != null:
		_cam.queue_free()

	_rig = null
	_pitch_node = null
	_cam = null
	_active = false

func _get_input_direction() -> Vector3:
	var dir: Vector3 = Vector3.ZERO
	if _rig == null:
		return dir

	var basis: Basis = _rig.global_transform.basis
	var forward: Vector3 = -basis.z
	var right: Vector3 = basis.x
	var up_vec: Vector3 = Vector3.UP

	if Input.is_action_pressed("dev_freecam_forward"):
		dir += forward
	if Input.is_action_pressed("dev_freecam_back"):
		dir -= forward
	if Input.is_action_pressed("dev_freecam_right"):
		dir += right
	if Input.is_action_pressed("dev_freecam_left"):
		dir -= right
	if Input.is_action_pressed("dev_freecam_up"):
		dir += up_vec
	if Input.is_action_pressed("dev_freecam_down"):
		dir -= up_vec

	if dir.length() > 0.0:
		dir = dir.normalized()

	return dir

func _current_speed() -> float:
	var spd: float = move_speed
	if Input.is_action_pressed("dev_freecam_fast"):
		spd = move_speed * fast_multiplier
	return spd

func _ensure_default_input() -> void:
	_add_key_if_missing(toggle_action, Key.KEY_F6)
	_add_key_if_missing("dev_freecam_forward", Key.KEY_W)
	_add_key_if_missing("dev_freecam_back", Key.KEY_S)
	_add_key_if_missing("dev_freecam_left", Key.KEY_A)
	_add_key_if_missing("dev_freecam_right", Key.KEY_D)
	_add_key_if_missing("dev_freecam_up", Key.KEY_SPACE)
	_add_key_if_missing("dev_freecam_down", Key.KEY_CTRL)
	_add_key_if_missing("dev_freecam_fast", Key.KEY_SHIFT)

func _add_key_if_missing(action: String, keycode: int) -> void:
	var has_action: bool = InputMap.has_action(action)
	if not has_action:
		InputMap.add_action(action)
	var ev: InputEventKey = InputEventKey.new()
	ev.physical_keycode = keycode
	var already: bool = InputMap.action_has_event(action, ev)
	if not already:
		InputMap.action_add_event(action, ev)
