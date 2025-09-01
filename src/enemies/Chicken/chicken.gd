extends RigidBody3D
class_name Chicken

# ---- Tuning ----
@export var max_hp := 10

# Wander
@export var walk_force := 28.0        # push while alive
@export var walk_speed := 3.0         # target horizontal speed
@export var turn_torque := 6.0        # face new direction faster
@export var think_min := 0.8
@export var think_max := 2.0
@export var obstacle_check := 0.9     # forward wall check distance
@export var ledge_check_down := 1.6   # look down ahead; if no ground, turn

# Hit response
@export var hit_upkick := 12.0        # extra upward impulse
@export var hit_stun_time := 0.35     # time AI stops pushing after hit
@export var hit_knock_mult := 1.0     # multiplier on incoming impulse

var hp := 0
var wander_dir := Vector3.ZERO
var think_t := 0.0
var alive := true
var stun_t := 0.0
var rng := RandomNumberGenerator.new()

@onready var mesh: MeshInstance3D = $MeshInstance3D  # adjust path if different
var _flash_running := false
var _base_color := Color(1,1,1,1)

func _ready() -> void:
	hp = max_hp
	rng.randomize()
	# physics feel
	mass = 3.0
	linear_damp = 0.1
	angular_damp = 0.2
	can_sleep = true
	contact_monitor = true
	max_contacts_reported = 4
	
	var m := mesh.get_active_material(0)
	if m is StandardMaterial3D:
		m = m.duplicate()
		mesh.set_surface_override_material(0, m)
	else:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = _base_color
		mesh.material_override = mat


func _physics_process(delta: float) -> void:
	if not alive:
		return # dead = pure floppy physics

	# tick stun
	if stun_t > 0.0:
		stun_t = max(stun_t - delta, 0.0)

	# pick a new wander direction sometimes
	think_t -= delta
	if think_t <= 0.0:
		_pick_new_wander()
		think_t = rng.randf_range(think_min, think_max)

	# avoid walls / ledges
	if _wall_ahead() or not _ground_ahead():
		_pick_new_wander()

	# gentle locomotion while not stunned
	if stun_t <= 0.0:
		var vel := linear_velocity
		var horiz := Vector3(vel.x, 0, vel.z)
		if horiz.length() < walk_speed and wander_dir != Vector3.ZERO:
			apply_central_force(wander_dir * walk_force)

		# face movement dir
		if wander_dir.length() > 0.1:
			var target_yaw := atan2(-wander_dir.x, -wander_dir.z) # -Z is forward
			var yaw_diff := wrapf(target_yaw - rotation.y, -PI, PI)
			apply_torque(Vector3(0, yaw_diff * turn_torque, 0))

func hit(damage: int, impulse_dir: Vector3, impulse_strength: float, hit_pos: Vector3) -> void:
	hit_flash()
	
	# Strong knockback with upward kick, plus short stun
	var dir := impulse_dir.normalized()
	var offset := hit_pos - global_position
	var impulse := dir * (impulse_strength * hit_knock_mult) + Vector3.UP * hit_upkick
	apply_impulse(impulse, offset)
	stun_t = max(stun_t, hit_stun_time)

	if not alive:
		return

	hp -= max(damage, 0)
	if hp <= 0:
		die()

func hit_flash() -> void:
	if not is_instance_valid(mesh):
		return
	var mat := mesh.get_active_material(0) as StandardMaterial3D
	if mat == null:
		return

	# prevent overlapping timers from fighting
	if _flash_running:
		return
	_flash_running = true

	mat.albedo_color = Color(1, 0.8, 0.8, 1)
	await get_tree().create_timer(0.06).timeout
	mat.albedo_color = _base_color
	_flash_running = false

func die() -> void:
	pass
	#alive = false
	# make it settle after tumbling
	#linear_damp = 0.4
	#angular_damp = 0.6

# --- helpers ---

func _pick_new_wander() -> void:
	# random horizontal dir (normalized)
	var d := Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1))
	if d.length() < 0.2:
		d = Vector3(0, 0, -1)
	wander_dir = d.normalized().rotated(Vector3.UP, rng.randf_range(-0.7, 0.7))

func _wall_ahead() -> bool:
	var origin := global_position + Vector3(0, 0.3, 0)
	var forward := -global_transform.basis.z
	var to := origin + forward * obstacle_check
	var q := PhysicsRayQueryParameters3D.create(origin, to)
	q.exclude = [self]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return not hit.is_empty()

func _ground_ahead() -> bool:
	# cast a little forward and then down to see if there's ground to step onto
	var forward := -global_transform.basis.z
	var start := global_position + forward * 0.6 + Vector3(0, 0.3, 0)
	var end := start + Vector3(0, -ledge_check_down, 0)
	var q := PhysicsRayQueryParameters3D.create(start, end)
	q.exclude = [self]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return not hit.is_empty()
