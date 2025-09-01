extends Node3D
class_name Main

@export var player_path: NodePath
@export var chicken_scene: PackedScene = preload("res://src/enemies/Chicken/chicken.tscn")

@onready var player := get_node(player_path)

const SPAWN_RAY_DIST := 60.0

func _ready() -> void:
	# Optional: wire a UI button if present (UI/DevBar/SpawnChickenButton)
	var btn := get_node_or_null("UI/DevBar/SpawnChickenButton")
	if btn:
		btn.pressed.connect(spawn_chicken_at_crosshair)

	# Dev keybinding (Project > Project Settings > Input Map):
	# Add action "spawn_chicken" and bind to C (or whatever you like).
	if not InputMap.has_action("spawn_chicken"):
		InputMap.add_action("spawn_chicken")

func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("spawn_chicken"):
		spawn_chicken_at_crosshair()

# Main.gd — replace your spawn method with this
func spawn_chicken_at_crosshair() -> void:
	if player == null or chicken_scene == null:
		return

	var hit := {}
	# Use player's helper if available
	if player.has_method("_camera_ray_hit"):
		hit = player._camera_ray_hit(SPAWN_RAY_DIST)

	# Fallback: cast our own ray
	if hit.is_empty():
		var cam := player.get_node_or_null("Cam") as Camera3D
		if cam:
			var origin := cam.global_position
			var dir := -cam.global_transform.basis.z
			var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * SPAWN_RAY_DIST)
			q.exclude = [player]
			hit = get_world_3d().direct_space_state.intersect_ray(q)

	var spawn_pos: Vector3
	var initial_dir := Vector3.ZERO

	if not hit.is_empty():
		spawn_pos = hit.position + hit.normal * 0.6
		initial_dir = (spawn_pos - player.global_position).normalized()
		spawn_pos = _snap_above_block(spawn_pos, 0.6)
	else:
		var cam2 := player.get_node_or_null("Cam") as Camera3D
		if cam2 == null:
			return
		var dir2 := -cam2.global_transform.basis.z
		spawn_pos = cam2.global_position + dir2 * 6.0
		initial_dir = dir2

	# IMPORTANT: add to tree first, then set global_position
	var chicken := chicken_scene.instantiate()
	add_child(chicken)
	chicken.global_position = spawn_pos

	# Give it a little toss so it doesn’t overlap you
	if chicken is RigidBody3D:
		var toss := initial_dir * 6.0 + Vector3.UP * 4.0
		chicken.apply_central_impulse(toss)

func _snap_above_block(p: Vector3, up_epsilon := 0.6) -> Vector3:
	return Vector3(floor(p.x) + 0.5, floor(p.y) + up_epsilon, floor(p.z) + 0.5)
