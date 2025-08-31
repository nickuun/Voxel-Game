extends Node3D
class_name SelectionBox

func show_at_block(world_pos: Vector3) -> void:
	# Snap to integer cell, center on block
	var bx = floor(world_pos.x) + 0.5
	var by = floor(world_pos.y) + 0.5
	var bz = floor(world_pos.z) + 0.5
	global_position = Vector3(bx, by, bz)
	visible = true
