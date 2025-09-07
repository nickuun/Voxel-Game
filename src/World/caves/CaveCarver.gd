extends RefCounted
class_name CaveCarver

# ------------------------------
# Config: feature scales & knobs
# ------------------------------
const FEATURE_STRIDE_XZ: int = 256
const FEATURE_STRIDE_Y: int = 128

const CAVERN_SPAWN_CHANCE: float = 0.65	# chance gate per feature cell (higher = fewer caverns)
const CAVERN_MIN_R: int = 18
const CAVERN_MAX_R: int = 45
const CAVERN_TAIL_R: int = 90

const PILLAR_CHANCE: float = 0.45
const PILLAR_MIN_R: int = 2
const PILLAR_MAX_R: int = 4

const SHAFT_CHANCE: float = 0.75
const SHAFT_MIN_R: int = 2
const SHAFT_MAX_R: int = 4
const SHAFT_MIN_LEN: int = 40

const TUNNEL_WORMS_MIN: int = 2
const TUNNEL_WORMS_MAX: int = 7
const TUNNEL_STEPS_MIN: int = 90
const TUNNEL_STEPS_MAX: int = 160
const TUNNEL_RADIUS_MIN: int = 1
const TUNNEL_RADIUS_MAX: int = 3
const TUNNEL_BRANCH_STEPS_MIN: int = 50
const TUNNEL_BRANCH_STEPS_MAX: int = 60
const WORM_BRANCHES_MIN: int = 2
const WORM_BRANCHES_MAX: int = 3
const LOOP_EVERY_MIN: int = 120
const LOOP_EVERY_MAX: int = 180

const MICRO_POCKET_CHANCE: float = 0.10
const MICRO_POCKET_MIN_R: int = 1
const MICRO_POCKET_MAX_R: int = 2

# Noise frequencies
const WARP_NOISE_FREQ: float = 0.02
const TUNNEL_DIR_NOISE_FREQ: float = 0.05
const MICRO_NOISE_FREQ: float = 0.12

# Carvable ids (terrain-ish; do not carve trees/logs/leaves)
static func _carvable(id: int) -> bool:
	if id == BlockDB.BlockId.DIRT:
		return true
	if id == BlockDB.BlockId.STONE:
		return true
	if id == BlockDB.BlockId.COBBLE:
		return true
	if id == BlockDB.BlockId.STONE_BRICKS:
		return true
	if id == BlockDB.BlockId.MOSSY_STONE_BRICKS:
		return true
	if id == BlockDB.BlockId.CLAY_TILE:
		return true
	if id == BlockDB.BlockId.SAND:
		return true
	if id == BlockDB.BlockId.CLAY_BRICKS:
		return true
	if id == BlockDB.BlockId.SNOW_DIRT:
		return true
	return false

# -----------------------------------
# Public entry: carve a single chunk
# -----------------------------------
static func carve_chunk(
		blocks: Array,
		heightmap: PackedInt32Array,
		base_x: int,
		base_z: int,
		cx: int,
		cy: int,
		cz: int,
		world_seed: int
	) -> PackedInt32Array:
	var hm: PackedInt32Array = heightmap
	var warp: FastNoiseLite = FastNoiseLite.new()
	warp.noise_type = FastNoiseLite.TYPE_SIMPLEX
	warp.fractal_octaves = 2
	warp.frequency = WARP_NOISE_FREQ
	warp.seed = world_seed * 1013904223 + 1

	var dir_noise: FastNoiseLite = FastNoiseLite.new()
	dir_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	dir_noise.fractal_octaves = 1
	dir_noise.frequency = TUNNEL_DIR_NOISE_FREQ
	dir_noise.seed = world_seed * 1664525 + 2

	var micro_noise: FastNoiseLite = FastNoiseLite.new()
	micro_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	micro_noise.fractal_octaves = 2
	micro_noise.frequency = MICRO_NOISE_FREQ
	micro_noise.seed = world_seed * 22695477 + 3

	# Macro: caverns, pillars, shafts
	_carve_macro_caverns(blocks, hm, base_x, base_z, cx, cy, cz, world_seed, warp)

	# Meso: tunnels (branching + occasional loops)
	_carve_tunnels(blocks, hm, base_x, base_z, cx, cy, cz, world_seed, dir_noise)

	# Micro: little pockets/seams
	_carve_micro_pockets(blocks, hm, base_x, base_z, cx, cy, cz, world_seed, micro_noise)

	# Recompute top solids after carving
	var new_hm: PackedInt32Array = _recompute_heightmap(blocks, cx, cy, cz)
	return new_hm

# -----------------------
# Macro: caverns layer
# -----------------------
static func _carve_macro_caverns(
		blocks: Array,
		hm: PackedInt32Array,
		base_x: int,
		base_z: int,
		cx: int,
		cy: int,
		cz: int,
		seed: int,
		warp: FastNoiseLite
	) -> void:
	var cell_x0: int = _floor_div(base_x, FEATURE_STRIDE_XZ)
	var cell_z0: int = _floor_div(base_z, FEATURE_STRIDE_XZ)

	var cx_end: int = base_x + cx - 1
	var cz_end: int = base_z + cz - 1
	var cell_x1: int = _floor_div(cx_end, FEATURE_STRIDE_XZ)
	var cell_z1: int = _floor_div(cz_end, FEATURE_STRIDE_XZ)

	var x_cell: int = cell_x0 - 1
	while x_cell <= cell_x1 + 1:
		var z_cell: int = cell_z0 - 1
		while z_cell <= cell_z1 + 1:
			var h: int = _hash3(x_cell, z_cell, seed + 17)
			var chance_num: int = (h & 1023)
			var chance: float = float(chance_num) / 1023.0
			if chance > CAVERN_SPAWN_CHANCE:
				var off_x: int = int(((h >> 10) & 255))
				var off_z: int = int(((h >> 18) & 255))
				var off_y_raw: int = int(((h >> 26) & 63))

				var center_x: int = x_cell * FEATURE_STRIDE_XZ + off_x
				var center_z: int = z_cell * FEATURE_STRIDE_XZ + off_z

				var min_y: int = cy / 16
				var max_y: int = cy * 3 / 4
				var center_y: int = min_y + int(_remap(off_y_raw, 0, 63, 0, max_y - min_y))
				if center_y < 2:
					center_y = 2
				if center_y > cy - 3:
					center_y = cy - 3

				var r_base: int = _pick_cavern_radius(h)
				var rx: int = r_base
				var ry: int = int(float(r_base) * (0.7 + 0.6 * _hash01(h + 91)))
				var rz: int = int(float(r_base) * (0.8 + 0.5 * _hash01(h + 131)))

				_carve_ellipsoid(blocks, base_x, base_z, cx, cy, cz, center_x, center_y, center_z, rx, ry, rz, warp)

				var do_pillar_gate: float = _hash01(h + 211)
				if do_pillar_gate < PILLAR_CHANCE:
					var pr: int = _rangei(PILLAR_MIN_R, PILLAR_MAX_R, h + 313)
					_carve_pillar(blocks, base_x, base_z, cx, cy, cz, center_x, center_y, center_z, pr)

				var shaft_gate: float = _hash01(h + 411)
				if shaft_gate < SHAFT_CHANCE:
					var sr: int = _rangei(SHAFT_MIN_R, SHAFT_MAX_R, h + 419)
					_carve_shaft_up(blocks, hm, base_x, base_z, cx, cy, cz, center_x, center_y, center_z, sr)

			z_cell += 1
		x_cell += 1

static func _pick_cavern_radius(h: int) -> int:
	var b: float = _hash01(h + 7)
	var core: int = int(_lerp(float(CAVERN_MIN_R), float(CAVERN_MAX_R), b))
	var tail_gate: float = _hash01(h + 13)
	if tail_gate > 0.94:
		var tail_k: float = _hash01(h + 19)
		var tail_r: float = _lerp(float(CAVERN_MAX_R), float(CAVERN_TAIL_R), tail_k)
		return int(tail_r)
	return core

static func _carve_ellipsoid(
		blocks: Array,
		base_x: int,
		base_z: int,
		cx: int,
		cy: int,
		cz: int,
		cxw: int,
		cyw: int,
		czw: int,
		rx: int,
		ry: int,
		rz: int,
		warp: FastNoiseLite
	) -> void:
	var lx0: int = cxw - rx - base_x
	var lz0: int = czw - rz - base_z
	var lx1: int = cxw + rx - base_x
	var lz1: int = czw + rz - base_z
	var ly0: int = cyw - ry
	var ly1: int = cyw + ry

	if lx0 < 0:
		lx0 = 0
	if ly0 < 0:
		ly0 = 0
	if lz0 < 0:
		lz0 = 0
	if lx1 > cx - 1:
		lx1 = cx - 1
	if ly1 > cy - 1:
		ly1 = cy - 1
	if lz1 > cz - 1:
		lz1 = cz - 1

	var inv_rx2: float = 1.0 / float(rx * rx)
	var inv_ry2: float = 1.0 / float(ry * ry)
	var inv_rz2: float = 1.0 / float(rz * rz)

	var x: int = lx0
	while x <= lx1:
		var z: int = lz0
		while z <= lz1:
			var y: int = ly0
			while y <= ly1:
				var id: int = int((blocks[x] as Array)[y][z])
				if id != BlockDB.BlockId.AIR and _carvable(id):
					var dx: float = float(base_x + x - cxw)
					var dy: float = float(y - cyw)
					var dz: float = float(base_z + z - czw)
					var dw: float = warp.get_noise_3d(float(base_x + x), float(y), float(base_z + z)) * 0.3
					var v: float = (dx * dx) * inv_rx2 + (dy * dy) * inv_ry2 + (dz * dz) * inv_rz2 + dw
					if v <= 1.0:
						(blocks[x] as Array)[y][z] = BlockDB.BlockId.AIR
				y += 1
			z += 1
		x += 1

static func _carve_pillar(
		blocks: Array,
		base_x: int,
		base_z: int,
		cx: int,
		cy: int,
		cz: int,
		cxw: int,
		cyw: int,
		czw: int,
		r: int
	) -> void:
	var lx: int = cxw - base_x
	var lz: int = czw - base_z
	if lx < 0 or lx >= cx or lz < 0 or lz >= cz:
		return

	var r2: int = r * r
	var y: int = 0
	while y < cy:
		var x0: int = max(0, lx - r)
		var x1: int = min(cx - 1, lx + r)
		var z0: int = max(0, lz - r)
		var z1: int = min(cz - 1, lz + r)
		var x: int = x0
		while x <= x1:
			var z: int = z0
			while z <= z1:
				var dx: int = x - lx
				var dz: int = z - lz
				var d2: int = dx * dx + dz * dz
				if d2 <= r2:
					var id: int = int((blocks[x] as Array)[y][z])
					if id != BlockDB.BlockId.AIR and _carvable(id):
						(blocks[x] as Array)[y][z] = BlockDB.BlockId.AIR
				z += 1
			x += 1
		y += 1

static func _carve_shaft_up(
		blocks: Array,
		hm: PackedInt32Array,
		base_x: int,
		base_z: int,
		cx: int,
		cy: int,
		cz: int,
		cxw: int,
		cyw: int,
		czw: int,
		r: int
	) -> void:
	var lx: int = cxw - base_x
	var lz: int = czw - base_z
	if lx < 0 or lx >= cx or lz < 0 or lz >= cz:
		return

	var shaft_end_y: int = cy - 2
	var col_top: int = _hm_get(hm, cx, cz, lx, lz)
	if col_top >= 0:
		shaft_end_y = col_top
	if shaft_end_y - cyw < SHAFT_MIN_LEN:
		shaft_end_y = min(cy - 2, cyw + SHAFT_MIN_LEN)

	var r2: int = r * r
	var y: int = cyw
	while y <= shaft_end_y:
		var x0: int = max(0, lx - r)
		var x1: int = min(cx - 1, lx + r)
		var z0: int = max(0, lz - r)
		var z1: int = min(cz - 1, lz + r)
		var x: int = x0
		while x <= x1:
			var z: int = z0
			while z <= z1:
				var dx: int = x - lx
				var dz: int = z - lz
				var d2: int = dx * dx + dz * dz
				if d2 <= r2:
					var id: int = int((blocks[x] as Array)[y][z])
					if id != BlockDB.BlockId.AIR and _carvable(id):
						(blocks[x] as Array)[y][z] = BlockDB.BlockId.AIR
				z += 1
			x += 1
		y += 1

# -----------------------
# Meso: tunnel worms
# -----------------------
static func _carve_tunnels(
		blocks: Array,
		hm: PackedInt32Array,
		base_x: int,
		base_z: int,
		cx: int,
		cy: int,
		cz: int,
		seed: int,
		dir_noise: FastNoiseLite
	) -> void:
	var worms: int = _rangei(TUNNEL_WORMS_MIN, TUNNEL_WORMS_MAX, seed + 101)
	var i: int = 0
	while i < worms:
		var sh: int = _hash3(i, seed, 271)
		var start_x: int = base_x + _rangei(0, cx - 1, sh + 11)
		var start_z: int = base_z + _rangei(0, cz - 1, sh + 17)
		var col_top: int = _hm_get(hm, cx, cz, start_x - base_x, start_z - base_z)
		if col_top < 0:
			col_top = cy / 2
		var start_y: int = _rangei(max(4, col_top - 60), max(8, col_top - 10), sh + 23)
		if start_y < 3:
			start_y = 3
		if start_y > cy - 4:
			start_y = cy - 4

		var steps: int = _rangei(TUNNEL_STEPS_MIN, TUNNEL_STEPS_MAX, sh + 29)
		var branch_every: int = _rangei(TUNNEL_BRANCH_STEPS_MIN, TUNNEL_BRANCH_STEPS_MAX, sh + 31)
		var loop_every: int = _rangei(LOOP_EVERY_MIN, LOOP_EVERY_MAX, sh + 37)
		_worm(blocks, base_x, base_z, cx, cy, cz, Vector3(start_x, start_y, start_z), steps, branch_every, loop_every, seed + 31337, dir_noise)
		i += 1

static func _worm(
		blocks: Array,
		base_x: int,
		base_z: int,
		cx: int,
		cy: int,
		cz: int,
		start_pos: Vector3,
		steps: int,
		branch_every: int,
		loop_every: int,
		seed: int,
		dir_noise: FastNoiseLite
	) -> void:
	var pos: Vector3 = start_pos
	var dir: Vector3 = Vector3(1.0, 0.0, 0.0)
	var t: int = 0
	var anchors: Array = []
	var last_loop_at: int = 0

	while t < steps:
		var nx: float = dir_noise.get_noise_3d(pos.x * 0.1, pos.y * 0.1, pos.z * 0.1)
		var ny: float = dir_noise.get_noise_3d(pos.x * 0.1 + 77.0, pos.y * 0.1 + 33.0, pos.z * 0.1 - 19.0)
		var nz: float = dir_noise.get_noise_3d(pos.x * 0.1 - 55.0, pos.y * 0.1 + 61.0, pos.z * 0.1 + 7.0)
		dir = Vector3(nx, ny * 0.6, nz).normalized()
		pos = pos + dir

		var lx: int = int(pos.x) - base_x
		var ly: int = int(pos.y)
		var lz: int = int(pos.z) - base_z
		if lx >= 1 and lx < cx - 1 and ly >= 2 and ly < cy - 2 and lz >= 1 and lz < cz - 1:
			var rid: int = _rangei(TUNNEL_RADIUS_MIN, TUNNEL_RADIUS_MAX, seed + t * 13)
			_brush_sphere(blocks, cx, cy, cz, lx, ly, lz, rid)

		if t % 24 == 0:
			anchors.append(Vector3(pos.x, pos.y, pos.z))

		if branch_every > 0 and t % branch_every == 0 and t > 0:
			var branches: int = _rangei(WORM_BRANCHES_MIN, WORM_BRANCHES_MAX, seed + t * 29)
			var b: int = 0
			while b < branches:
				var off: Vector3 = Vector3(-dir.z, dir.y, dir.x).normalized()
				var side: int = (seed + t * 31 + b) & 1
				if side == 0:
					off = -off
				var child_pos: Vector3 = pos + off * 5.0
				_worm(blocks, base_x, base_z, cx, cy, cz, child_pos, int(float(steps) * 0.5), branch_every, loop_every, seed + b * 9973, dir_noise)
				b += 1

		if loop_every > 0 and (t - last_loop_at) >= loop_every and anchors.size() > 0:
			last_loop_at = t
			var idx: int = int((seed + t * 43) % anchors.size())
			var target: Vector3 = anchors[idx]
			_carve_line(blocks, base_x, base_z, cx, cy, cz, pos, target, _rangei(TUNNEL_RADIUS_MIN, TUNNEL_RADIUS_MAX, seed + t * 47))

		t += 1

static func _brush_sphere(blocks: Array, cx: int, cy: int, cz: int, lx: int, ly: int, lz: int, r: int) -> void:
	var r2: int = r * r
	var x0: int = max(0, lx - r)
	var x1: int = min(cx - 1, lx + r)
	var y0: int = max(0, ly - r)
	var y1: int = min(cy - 1, ly + r)
	var z0: int = max(0, lz - r)
	var z1: int = min(cz - 1, lz + r)
	var x: int = x0
	while x <= x1:
		var y: int = y0
		while y <= y1:
			var z: int = z0
			while z <= z1:
				var dx: int = x - lx
				var dy: int = y - ly
				var dz: int = z - lz
				var d2: int = dx * dx + dy * dy + dz * dz
				if d2 <= r2:
					var id: int = int((blocks[x] as Array)[y][z])
					if id != BlockDB.BlockId.AIR and _carvable(id):
						(blocks[x] as Array)[y][z] = BlockDB.BlockId.AIR
				z += 1
			y += 1
		x += 1

static func _carve_line(
		blocks: Array,
		base_x: int,
		base_z: int,
		cx: int,
		cy: int,
		cz: int,
		a: Vector3,
		b: Vector3,
		r: int
	) -> void:
	var steps: int = int(a.distance_to(b))
	if steps < 1:
		steps = 1
	var i: int = 0
	while i <= steps:
		var t: float = float(i) / float(steps)
		var p: Vector3 = a.lerp(b, t)
		var lx: int = int(p.x) - base_x
		var ly: int = int(p.y)
		var lz: int = int(p.z) - base_z
		if lx >= 1 and lx < cx - 1 and ly >= 2 and ly < cy - 2 and lz >= 1 and lz < cz - 1:
			_brush_sphere(blocks, cx, cy, cz, lx, ly, lz, r)
		i += 1

# -----------------------
# Micro: pockets / seams
# -----------------------
static func _carve_micro_pockets(
		blocks: Array,
		hm: PackedInt32Array,
		base_x: int,
		base_z: int,
		cx: int,
		cy: int,
		cz: int,
		seed: int,
		micro_noise: FastNoiseLite
	) -> void:
	var x: int = 0
	while x < cx:
		var z: int = 0
		while z < cz:
			var top: int = _hm_get(hm, cx, cz, x, z)
			if top >= 0:
				var y0: int = max(2, top - 30)
				var y1: int = max(3, top - 4)
				var y: int = y0
				while y <= y1:
					var n: float = micro_noise.get_noise_3d(float(base_x + x), float(y), float(base_z + z))
					if n > 0.62:
						var gate: float = _hash01(seed + x * 928371 + y * 523 + z * 19349663)
						if gate < MICRO_POCKET_CHANCE:
							var r: int = _rangei(MICRO_POCKET_MIN_R, MICRO_POCKET_MAX_R, seed + x * 131 + y * 37 + z * 17)
							_brush_sphere(blocks, cx, cy, cz, x, y, z, r)
					y += 1
			z += 1
		x += 1

# -----------------------
# Heightmap recompute
# -----------------------
static func _recompute_heightmap(blocks: Array, cx: int, cy: int, cz: int) -> PackedInt32Array:
	var hm: PackedInt32Array = PackedInt32Array()
	hm.resize(cx * cz)
	var x: int = 0
	while x < cx:
		var z: int = 0
		while z < cz:
			var top: int = -1
			var y: int = cy - 1
			while y >= 0:
				var id: int = int((blocks[x] as Array)[y][z])
				if id != BlockDB.BlockId.AIR:
					top = y
					y = -1
				else:
					y -= 1
			hm[x * cz + z] = top
			z += 1
		x += 1
	return hm

# -----------------------
# Utility helpers
# -----------------------
static func _hm_get(hm: PackedInt32Array, cx: int, cz: int, lx: int, lz: int) -> int:
	var idx: int = lx * cz + lz
	if idx >= 0 and idx < hm.size():
		return hm[idx]
	return -1

static func _floor_div(a: int, b: int) -> int:
	if a >= 0:
		return a / b
	var q: int = ((a + 1) / b) - 1
	return q

static func _hash3(a: int, b: int, c: int) -> int:
	var x: int = a * 73856093 ^ b * 19349663 ^ c * 83492791
	x = (x << 13) ^ x
	return x * (x * x * 15731 + 789221) + 1376312589

static func _hash01(x: int) -> float:
	var u: int = _hash3(x, x >> 2, x << 2)
	var v: int = (u & 0x7fffffff)
	return float(v) / 2147483647.0

static func _rangei(a: int, b: int, salt: int) -> int:
	if b <= a:
		return a
	var t: float = _hash01(salt)
	var f: float = _lerp(float(a), float(b), t)
	return int(f)

static func _remap(v: int, a0: int, a1: int, b0: int, b1: int) -> int:
	var t: float = 0.0
	if a1 != a0:
		t = float(v - a0) / float(a1 - a0)
	var f: float = _lerp(float(b0), float(b1), t)
	return int(f)

static func _lerp(a: float, b: float, t: float) -> float:
	return a + (b - a) * t
