extends CharacterBody3D

@onready var cam: Camera3D = $Cam
@onready var ray: RayCast3D = $Ray

const SPEED := 6.0
const JUMP_VELOCITY := 5.5
const MOUSE_SENS := 0.12

var pitch := 0.0

@export var world_path: NodePath
var world: World
const INTERACT_DIST := 6.0
const EPS := 0.001

# If you know your capsule shape, set these roughly:
const PLAYER_RADIUS := 0.45
const PLAYER_HEIGHT := 1.8
@onready var selection_box := $"../SelectionBox"            # adjust path if needed
@onready var hotbar := $"../UI/Hotbar" as Hotbar
@onready var inventory_ui := $"../UI/Inventory" as InventoryUI

var current_block_id := BlockDB.BlockId.DIRT

# add at top
@export var hotbar_path: NodePath

enum MoveMode { WALK, GLIDE }
var mode: MoveMode = MoveMode.WALK

# --- Glide tuning (tweak freely) ---
const GLIDE_FORWARD_ACCEL := 20.0     # forward push
const GLIDE_LIFT_COEFF    := 18.0     # how much pitch converts to lift
const GLIDE_GRAVITY       := 3.5      # weaker than normal gravity
const GLIDE_DRAG          := 0.08     # quadratic-ish drag factor
const GLIDE_MAX_SPEED     := 28.0
const GLIDE_MIN_SPEED     := 6.0

var air_time := 0.0
const GLIDE_ENTER_GRACE := 0.12   # seconds you must be airborne before glide can start

const SHOOT_DIST := 40.0
const SHOOT_DAMAGE := 6
const SHOOT_IMPULSE := 14.0

const PUSH_IMPULSE := 2.0      # base shove
const PUSH_VEL_FACTOR := 0.25   # extra shove based on your current velocity

const NOTCH_HALF := 0.25  # sub-voxel is a 0.5m cube


func _apply_push_to_bodies() -> void:
	for i in range(get_slide_collision_count()):
		var col := get_slide_collision(i)
		var body := col.get_collider()
		if body is RigidBody3D:
			# push away along the contact normal, plus some of your current velocity
			var push_dir := -col.get_normal()          # away from the surface you hit
			var impulse := push_dir * PUSH_IMPULSE + velocity * PUSH_VEL_FACTOR
			body.apply_central_impulse(impulse)


func _ready() -> void:
	_capture_mouse()
	if hotbar:
		current_block_id = hotbar.current_block_id()
		hotbar.selected_changed.connect(_on_hotbar_selected_changed)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	if world_path != NodePath():
		world = get_node(world_path)

func _on_hotbar_selected_changed(_i:int, id:int) -> void:
	current_block_id = id

func _try_place_block() -> void:
	if hotbar and not hotbar.can_place_selected():
		return

	var hit := _camera_ray_hit()
	if hit.is_empty(): 
		return

	var id_to_place := current_block_id
	if BlockDB.is_orientable(id_to_place):
		id_to_place = BlockDB.orient_block_for_normal(id_to_place, hit.normal)

	# ----- placing a notch uses the smart placer (unchanged) -----
	if BlockDB.is_notch(id_to_place):
		_place_notch_smart(hit, id_to_place)
		if hotbar: hotbar.consume_selected(1)
		return

	# ----- FULL BLOCK / ENTITY -----
	# First target cell (standard neighbor along the clicked face)
	var pos = hit.position + hit.normal * 0.5 + hit.normal * EPS

	# If that target cell already has *any* micros, treat it as solid and step
	# one more cell outward (prevents z-fighting / overlap).
	if world.cell_has_any_notch_at_world(pos):
		pos += hit.normal   # move to the next cell along the same face

	# Do not place into an occupied cell (either a full block or micros)
	if world.get_block_id_at_world(pos) != BlockDB.BlockId.AIR:
		return
	if world.cell_has_any_notch_at_world(pos):
		return
	if _block_would_intersect_player(pos):
		return

	var placed := false
	if BlockDB.is_entity(id_to_place):
		var cam_forward := -cam.global_transform.basis.z
		world.place_entity_at_world_oriented(pos, id_to_place, hit.normal, global_position, cam_forward)
		placed = true
	else:
		world.edit_block_at_world(pos, id_to_place)
		placed = true

	if placed and hotbar:
		hotbar.consume_selected(1)


func _notch_would_intersect_player(center: Vector3) -> bool:
	# Treat the player as a vertical cylinder (same idea as your block check).
	var px := global_position.x
	var pz := global_position.z
	var py := global_position.y
	var half_h := PLAYER_HEIGHT * 0.5

	var horizontal := Vector2(center.x - px, center.z - pz).length()
	var vertical_overlap := (center.y + NOTCH_HALF) > (py - half_h) and (center.y - NOTCH_HALF) < (py + half_h)
	return horizontal < (PLAYER_RADIUS + NOTCH_HALF) and vertical_overlap


func _vec_sign(n: Vector3) -> Vector3i:
	return Vector3i(_signi(n.x), _signi(n.y), _signi(n.z))

func _signi(f: float) -> int:
	return 1 if f > 0.0 else (-1 if f < 0.0 else 0)
	
func _place_notch_smart(hit: Dictionary, notch_id: int) -> void:
	var p: Vector3 = hit.position
	var n: Vector3 = hit.normal
	var eps := 0.001

	# Did we click a notch face? (peek just behind the face)
	var clicked_notch := world.has_notch_at_world(p - n * 0.05)

	# Pick the solid-side cell first
	var solid_cell := Vector3i(
		floori((p - n * eps).x),
		floori((p - n * eps).y),
		floori((p - n * eps).z)
	)

	# Destination cell:
	#  - clicking a notch  -> stay in same cell
	#  - clicking a block  -> neighbor along face normal
	var dest_cell := solid_cell + (Vector3i.ZERO if clicked_notch else _vec_sign(n))

	# Local 0..1 in that cell
	var local := p - Vector3(dest_cell)
	var ix := int(floor(clamp(local.x, 0.0, 0.999) * 2.0))
	var iy := int(floor(clamp(local.y, 0.0, 0.999) * 2.0))
	var iz := int(floor(clamp(local.z, 0.0, 0.999) * 2.0))

	# Snap the half touching the clicked face
	if abs(n.x) > 0.5:
		ix = (1 if n.x > 0.0 else 0) if clicked_notch else (0 if n.x > 0.0 else 1)
	elif abs(n.y) > 0.5:
		iy = (1 if n.y > 0.0 else 0) if clicked_notch else (0 if n.y > 0.0 else 1)
	else:
		iz = (1 if n.z > 0.0 else 0) if clicked_notch else (0 if n.z > 0.0 else 1)

	# Center of the sub-cube we want
	var wpos := Vector3(
		dest_cell.x + (ix * 0.5 + 0.25),
		dest_cell.y + (iy * 0.5 + 0.25),
		dest_cell.z + (iz * 0.5 + 0.25)
	)

	# ⛔ don’t place if it would intersect the player
	if _notch_would_intersect_player(wpos):
		return

	# Normal used for orientable notch types (e.g., log bark direction)
	var eff_n := n

	# If already filled, try chaining into the neighbor cell
	if world.has_notch_at_world(wpos):
		var nb := dest_cell + _vec_sign(n)

		var ix2 := (0 if abs(n.x) > 0.5 and n.x > 0.0 else 1) if abs(n.x) > 0.5 else ix
		var iy2 := (0 if abs(n.y) > 0.5 and n.y > 0.0 else 1) if abs(n.y) > 0.5 else iy
		var iz2 := (0 if abs(n.z) > 0.5 and n.z > 0.0 else 1) if abs(n.z) > 0.5 else iz

		var wpos2 := Vector3(
			nb.x + (ix2 * 0.5 + 0.25),
			nb.y + (iy2 * 0.5 + 0.25),
			nb.z + (iz2 * 0.5 + 0.25)
		)

		# Bridging across a top/bottom face? Pick sideways normal by in-plane half.
		if abs(n.y) > 0.5:
			var dx := local.x - 0.5
			var dz := local.z - 0.5
			eff_n = Vector3(_signi(dx), 0, 0) if abs(dx) >= abs(dz) else Vector3(0, 0, _signi(dz))
		else:
			eff_n = n

		if not world.has_notch_at_world(wpos2) and not _notch_would_intersect_player(wpos2):
			world.place_notch_at_world(wpos2, notch_id, eff_n)
		return

	# First spot was free & safe
	world.place_notch_at_world(wpos, notch_id, eff_n)


func _process(_dt):
	# Move selection box to the targeted block (the one you'd BREAK)
	var hit := _camera_ray_hit()
	if hit.is_empty():
		if is_instance_valid(selection_box): selection_box.visible = false
	else:
		if is_instance_valid(selection_box):
			selection_box.show_at_block(hit.position - hit.normal * 0.5)

# Try to break a micro-voxel near the hit. Returns true if something was broken.
func _try_break_micro_first(hit: Dictionary) -> bool:
	if hit.is_empty():
		return false
	var pos_block: Vector3 = hit.position - hit.normal * 0.5 + hit.normal * EPS

	# Micro steps in your world commonly live in the AIR cell above the top block,
	# but we also check the same cell and the one below (for trunk collars).
	var candidates := [
		pos_block,                               # same cell
		pos_block + Vector3(0,  1, 0) * 0.51,    # above cell
		pos_block + Vector3(0, -1, 0) * 0.51     # below cell
	]

	for p in candidates:
		var drop_id := world.break_notch_at_world(p)
		if drop_id >= 0:
			_drop_block_as_pickup(drop_id, p, 1)
			return true

	return false


func _try_break_block():
	var hit := _camera_ray_hit()
	if hit.is_empty():
		return

	# chest handling (unchanged) ...
	var obj = hit.get("collider")
	if obj:
		var n := obj as Node
		while n and not n.is_in_group("chest"):
			n = n.get_parent()
		if n and n.is_in_group("chest"):
			(n as Chest).break_and_delete()
			return

	# --- try micro-voxel first ---
	var notch_pickup_id := world.break_notch_at_world(hit.position - hit.normal * 0.001)
	if notch_pickup_id != -1:
		_drop_block_as_pickup(notch_pickup_id, hit.position, 1)
		return  # IMPORTANT: don't also break the full block

	# --- normal full block fallback ---
	var pos: Vector3 = hit.position - hit.normal * 0.5 + hit.normal * EPS
	var broken_id := world.get_block_id_at_world(pos)
	world.edit_block_at_world(pos, BlockDB.BlockId.AIR)
	if broken_id >= 0 and broken_id != BlockDB.BlockId.AIR and not BlockDB.is_entity(broken_id):
		_drop_block_as_pickup(broken_id, pos, 1)

func _unhandled_input(event: InputEvent) -> void:
	
	# TEMP: in Player._unhandled_input, add a dev key: TODO
	if event.is_action_pressed("spawn_pickup_test"):
		_drop_block_as_pickup(BlockDB.BlockId.GRASS, global_position + -cam.global_transform.basis.z * 3.0, 37)

		# toggle inventory
	if event.is_action_pressed("toggle_inventory"):
		#print("Inventory pressed")
		if inventory_ui:
			inventory_ui.toggle()
		return

	# block look while inventory open
	if inventory_ui and inventory_ui.is_open():
		return
		
		
	# Recapture on any mouse button press (required by browsers)
	if event is InputEventMouseButton and event.pressed:
		_capture_mouse()

	# Optional: allow ESC to release the mouse
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		rotate_y(deg_to_rad(-event.relative.x * MOUSE_SENS))
		pitch = clamp(pitch - event.relative.y * MOUSE_SENS, -89, 89)
		cam.rotation_degrees.x = pitch
		
	if event.is_action_pressed("interact"):
		_open_chest_under_crosshair()

func _open_chest_under_crosshair() -> void:
	var hit := _camera_ray_hit(4.0)   # shorter reach for interact
	if hit.is_empty(): return
	var obj = hit.get("collider")
	if obj == null: return

	# chest could be collider or a child – climb to a Node in "chest" group
	var n := obj as Node
	while n and not n.is_in_group("chest"):
		n = n.get_parent()
	if n and n.is_in_group("chest"):
		var chest := n as Chest
		if inventory_ui:
			inventory_ui.open_with_chest(chest)    # new API below

func _notification(what: int) -> void:
	# If the tab regains focus, try to recapture next click
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		# no-op; next click will recapture via _unhandled_input()
		pass

func _capture_mouse() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _input(event):
	if inventory_ui and inventory_ui.is_open():
		return
	# prevent shooting while UI is up, etc. (skip for POC)
	if event.is_action_pressed("break_block"):
		_try_break_block()
	elif event.is_action_pressed("place_block"):
		_try_place_block()
	elif event.is_action_pressed("shoot"):
		_try_shoot()

func _camera_ray_hit(max_dist: float = INTERACT_DIST) -> Dictionary:
	var origin := cam.global_position
	var dir := -cam.global_transform.basis.z  # Camera forward
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * max_dist)
	query.exclude = [self]  # don't hit our own body
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit  # {} if nothing


func _block_would_intersect_player(block_world_pos: Vector3) -> bool:
	# Convert to the block's center (snap to integer center)
	var bx = floor(block_world_pos.x) + 0.5
	var by = floor(block_world_pos.y) + 0.5
	var bz = floor(block_world_pos.z) + 0.5
	var b := Vector3(bx, by, bz)

	# Player capsule ≈ cylinder check:
	var px := global_position.x
	var pz := global_position.z
	var py := global_position.y
	var half_h := PLAYER_HEIGHT * 0.5

	var horizontal := Vector2(b.x - px, b.z - pz).length()
	var vertical_overlap := (b.y + 0.5) > (py - half_h) and (b.y - 0.5) < (py + half_h)
	return horizontal < (PLAYER_RADIUS + 0.5) and vertical_overlap

func _physics_process(delta: float) -> void:
	# track time since we left the ground
	if is_on_floor():
		air_time = 0.0
	else:
		air_time += delta

	if mode == MoveMode.WALK:
		_physics_walk(delta)
		# only allow glide if we've been in the air for a moment (not the jump frame)
		if air_time > GLIDE_ENTER_GRACE and Input.is_action_just_pressed("jump"):
			_enter_glide()
	else: # GLIDE
		_physics_glide(delta)
		if is_on_floor():
			_exit_glide()

func _physics_walk(delta: float) -> void:
	var dir := Vector3.ZERO
	var forward := -global_transform.basis.z
	var right := global_transform.basis.x

	if Input.is_action_pressed("move_forward"): dir += forward
	if Input.is_action_pressed("move_back"):    dir -= forward
	if Input.is_action_pressed("move_left"):    dir -= right
	if Input.is_action_pressed("move_right"):   dir += right

	dir.y = 0
	dir = dir.normalized()

	var vel := velocity
	vel.x = dir.x * SPEED
	vel.z = dir.z * SPEED

	if not is_on_floor():
		vel.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * delta
	elif Input.is_action_just_pressed("jump"):
		vel.y = JUMP_VELOCITY

	velocity = vel
	move_and_slide()
	_apply_push_to_bodies()

func _physics_glide(delta: float) -> void:
	# Camera basis for steering
	var f := -cam.global_transform.basis.z  # forward
	var r :=  cam.global_transform.basis.x  # right

	# Forward push & steering (A/D)
	velocity += f * GLIDE_FORWARD_ACCEL * delta
	var steer := 0.0
	if Input.is_action_pressed("move_left"):  steer -= 1.0
	if Input.is_action_pressed("move_right"): steer += 1.0
	velocity += r * (steer * GLIDE_FORWARD_ACCEL * 0.6) * delta

	# Pitch-based lift (use camera pitch: f.y ≈ sin(pitch))
	var pitch_rad := asin(clamp(f.y, -0.99, 0.99))
	var lift := -pitch_rad * GLIDE_LIFT_COEFF   # nose down (negative pitch) => positive lift
	velocity.y += (lift - GLIDE_GRAVITY) * delta

	# Quadratic-ish drag
	var speed = max(velocity.length(), 0.001)
	velocity -= velocity * (GLIDE_DRAG * speed) * delta

	# Speed clamp
	speed = velocity.length()
	if speed > GLIDE_MAX_SPEED:
		velocity = velocity.normalized() * GLIDE_MAX_SPEED
	elif speed < GLIDE_MIN_SPEED:
		velocity = velocity.normalized() * GLIDE_MIN_SPEED

	# Move
	move_and_slide()
	_apply_push_to_bodies()

	# Manual exit (press jump again)
	if Input.is_action_just_pressed("jump"):
		_exit_glide()

func _enter_glide() -> void:
	mode = MoveMode.GLIDE
	# ensure we have forward speed when entering
	var f := -cam.global_transform.basis.z
	var min_dir := f * GLIDE_MIN_SPEED
	velocity = velocity.lerp(min_dir, 0.5)
	if velocity.length() < GLIDE_MIN_SPEED:
		velocity = min_dir

func _exit_glide() -> void:
	mode = MoveMode.WALK
	
func _try_shoot() -> void:
	#print("SHOOTING")
	var origin := cam.global_position
	var dir := -cam.global_transform.basis.z
	var params := PhysicsRayQueryParameters3D.create(origin, origin + dir * SHOOT_DIST)
	params.exclude = [self]
	params.collide_with_areas = true
	params.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(params)
	if hit.is_empty():
		return
	var col = hit.collider
	if col and col.has_method("hit"):
		col.hit(SHOOT_DAMAGE, dir, SHOOT_IMPULSE, hit.position)
		# tiny recoil for feel
		velocity -= dir * 0.5
		
func _drop_block_as_pickup(id: int, pos: Vector3, amount:int = 1) -> void:
	if id < 0 or id == BlockDB.BlockId.AIR or amount <= 0:
		return
	var scene := preload("res://src/Items/Pickups/pickup_3d.tscn")
	var p := scene.instantiate() as Pickup3D
	p.block_id = id
	p.count = amount
	p.transform.origin = world.to_local(pos) + Vector3(0, 0.4, 0)
	world.add_child(p)
	print("drop id=", id, "  is_notch=", BlockDB.is_notch(id))
