extends RefCounted
class_name SkyIslands

# =========================================================
# Multi-scale sky islands: macro (continents), meso (chains),
# micro (debris/fins). Pure additive fill (AIR-only).
# Safe to run inside your async gen worker.
# =========================================================

# -------------------- Tweakable knobs --------------------

# How far apart (world X/Z) we try rare macro "continent" centers.
# Larger => rarer macro islands, smaller => more frequent.
const FEATURE_STRIDE_XZ: int = 420

# Vertical band where sky islands may appear (fractions of CY).
# LOWER THESE to bring islands closer to the ground.
const SKY_MIN_FRAC: float = 0.18    # default ~42% of CY
const SKY_MAX_FRAC: float = 0.30    # default ~70% of CY

# Minimum vertical gap above HIGHEST terrain in the chunk.
# Increase to keep islands further off the ground.
const SKY_CLEARANCE_OVER_TERRAIN: int = 8

# Macro "continents" (big, blobby bases)
const MACRO_SPAWN_CHANCE: float = 0.82  # higher => fewer macro spawns
const MACRO_R_MIN: int = 20             # horizontal base radius (min)
const MACRO_R_MAX: int = 42             # horizontal base radius (max)
const MACRO_R_TAIL: int = 72            # rare supersized
const MACRO_Y_THICK_MIN: float = 0.30   # vertical thickness = radius * k (min)
const MACRO_Y_THICK_MAX: float = 0.55   # vertical thickness = radius * k (max)

# Meso chains (beads & bridges you can walk)
const CHAIN_SPAWN_CHANCE: float = 0.85
const CHAIN_STEP_MIN: int = 22          # link spacing (min)
const CHAIN_STEP_MAX: int = 36          # link spacing (max)
const CHAIN_NODES_MIN: int = 6          # links (min)
const CHAIN_NODES_MAX: int = 12         # links (max)
const CHAIN_R_MIN: int = 6              # bead radius (min)
const CHAIN_R_MAX: int = 12             # bead radius (max)
const BRIDGE_RADIUS_MIN: int = 2        # cylinder bridge radius (min)
const BRIDGE_RADIUS_MAX: int = 4        # cylinder bridge radius (max)

# Micro debris/fins (small scatter that makes midair choices)
const MICRO_DENSITY: float = 0.06
const MICRO_R_MIN: int = 3
const MICRO_R_MAX: int = 6
const FIN_CHANCE: float = 0.25          # chance to place thin plate instead of ball

# Decorative spires under islands
const SPIRE_CHANCE: float = 0.35
const SPIRE_LEN_MIN: int = 10
const SPIRE_LEN_MAX: int = 28
const SPIRE_R_MIN: int = 1
const SPIRE_R_MAX: int = 3

# Noises
const WARP_FREQ: float = 0.018          # surface wobble for blobs
const DIR_FREQ: float = 0.035           # vector field for chain direction
const MICRO_FREQ: float = 0.11          # micro scatter gate

# ==================== Small helpers ======================

static func _hm_max(hm: PackedInt32Array, cx: int, cz: int) -> int:
	var best: int = -1
	var x: int = 0
	while x < cx:
		var z: int = 0
		while z < cz:
			var v: int = hm[x * cz + z]
			if v > best:
				best = v
			z += 1
		x += 1
	return best

static func _pick_center_y(cy: int, hm: PackedInt32Array, cx: int, cz: int, salt: int) -> int:
	var band_min: int = int(float(cy) * SKY_MIN_FRAC)
	var band_max: int = int(float(cy) * SKY_MAX_FRAC)
	var max_terrain: int = _hm_max(hm, cx, cz)

	var min_y: int = band_min
	if max_terrain + SKY_CLEARANCE_OVER_TERRAIN > min_y:
		min_y = max_terrain + SKY_CLEARANCE_OVER_TERRAIN

	var max_y: int = band_max
	if min_y > max_y:
		min_y = max_y

	return _rangei(min_y, max_y, salt)

# =================== Public entry point ==================

# Adds islands into 'blocks' and returns updated heightmap.
static func add_to_chunk(
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

	# Resolve the usable Y band for this chunk with terrain clearance.
	var band_min: int = int(float(cy) * SKY_MIN_FRAC)
	var band_max: int = int(float(cy) * SKY_MAX_FRAC)
	var highest_ground: int = _hm_max(hm, cx, cz)

	var y_min: int = band_min
	if highest_ground + SKY_CLEARANCE_OVER_TERRAIN > y_min:
		y_min = highest_ground + SKY_CLEARANCE_OVER_TERRAIN
	if y_min < 2:
		y_min = 2

	var y_max: int = band_max
	if y_max > cy - 3:
		y_max = cy - 3
	if y_max <= y_min:
		y_max = y_min + 1

	# Noises (thread-safe per worker)
	var warp: FastNoiseLite = FastNoiseLite.new()
	warp.noise_type = FastNoiseLite.TYPE_SIMPLEX
	warp.fractal_octaves = 2
	warp.frequency = WARP_FREQ
	warp.seed = world_seed * 1103515245 + 12345

	var dir_noise: FastNoiseLite = FastNoiseLite.new()
	dir_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	dir_noise.fractal_octaves = 1
	dir_noise.frequency = DIR_FREQ
	dir_noise.seed = world_seed * 1664525 + 101

	var micro_noise: FastNoiseLite = FastNoiseLite.new()
	micro_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	micro_noise.fractal_octaves = 2
	micro_noise.frequency = MICRO_FREQ
	micro_noise.seed = world_seed * 22695477 + 303

	# Touched markers: which (x,z) columns we wrote, and the highest y in each.
	var touched: PackedByteArray = PackedByteArray()
	touched.resize(cx * cz)
	var i0: int = 0
	while i0 < touched.size():
		touched[i0] = 0
		i0 += 1

	var touched_top: PackedInt32Array = PackedInt32Array()
	touched_top.resize(cx * cz)
	var i1: int = 0
	while i1 < touched_top.size():
		touched_top[i1] = -1
		i1 += 1

	# ---- MACRO continents from lattice ----
	_macro_continents(blocks, touched, touched_top, hm, base_x, base_z, cx, cy, cz, world_seed, warp)

	# ---- MESO chains + bridges (routes) ----
	_meso_chains(blocks, touched, touched_top, hm, base_x, base_z, cx, cy, cz, y_min, y_max, world_seed, dir_noise)

	# ---- MICRO debris & fins ----
	_micro_debris(blocks, touched, touched_top, base_x, base_z, cx, cy, cz, y_min, y_max, world_seed, micro_noise)

	# ---- Decorative spires hanging from islands ----
	_option_spires(blocks, touched, touched_top, base_x, base_z, cx, cy, cz, y_min, y_max, world_seed)

	# ---- Skin only around island tops + update heightmap ----
	_skin_and_update_hm(blocks, touched, touched_top, cx, cy, cz, hm)

	return hm

# ====================== MACRO ===========================

static func _macro_continents(
		blocks: Array,
		touched: PackedByteArray,
		touched_top: PackedInt32Array,
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
			var h: int = _hash3(x_cell, z_cell, seed + 777)
			var gate_num: int = (h & 1023)
			var gate: float = float(gate_num) / 1023.0
			if gate > MACRO_SPAWN_CHANCE:
				var off_x: int = int((h >> 10) & 255)
				var off_z: int = int((h >> 18) & 255)
				var center_x: int = x_cell * FEATURE_STRIDE_XZ + off_x
				var center_z: int = z_cell * FEATURE_STRIDE_XZ + off_z
				var center_y: int = _pick_center_y(cy, hm, cx, cz, h + 33)

				var r_base: int = _pick_radius(h, MACRO_R_MIN, MACRO_R_MAX, MACRO_R_TAIL)
				var rx: int = int(float(r_base) * (0.9 + 0.4 * _hash01(h + 11)))
				var rz: int = int(float(r_base) * (0.9 + 0.4 * _hash01(h + 13)))
				var thick_k: float = _lerpf(MACRO_Y_THICK_MIN, MACRO_Y_THICK_MAX, _hash01(h + 17))
				var ry: int = int(float(r_base) * thick_k)
				if ry < 3:
					ry = 3

				_fill_ellipsoid(blocks, touched, touched_top, base_x, base_z, cx, cy, cz, center_x, center_y, center_z, rx, ry, rz, warp)
			z_cell += 1
		x_cell += 1

# ====================== MESO ============================

static func _meso_chains(
		blocks: Array,
		touched: PackedByteArray,
		touched_top: PackedInt32Array,
		hm: PackedInt32Array,
		base_x: int,
		base_z: int,
		cx: int,
		cy: int,
		cz: int,
		y_min: int,
		y_max: int,
		seed: int,
		dir_noise: FastNoiseLite
	) -> void:

	var h: int = _hash3(base_x, base_z, seed + 1901)
	var gate: float = _hash01(h)
	if gate > CHAIN_SPAWN_CHANCE:
		return

	# Start within this chunk at a valid sky Y (with clearance)
	var start_x: int = base_x + _rangei(0, cx - 1, h + 7)
	var start_z: int = base_z + _rangei(0, cz - 1, h + 13)
	var start_y: int = _pick_center_y(cy, hm, cx, cz, h + 19)
	if start_y < y_min:
		start_y = y_min
	if start_y > y_max:
		start_y = y_max

	var steps: int = _rangei(CHAIN_NODES_MIN, CHAIN_NODES_MAX, h + 23)
	var step_len: int = _rangei(CHAIN_STEP_MIN, CHAIN_STEP_MAX, h + 29)

	var prev_px: int = start_x
	var prev_py: int = start_y
	var prev_pz: int = start_z
	var k: int = 0
	while k < steps:
		var dxn: float = dir_noise.get_noise_3d(float(prev_px) * 0.1, float(prev_py) * 0.1, float(prev_pz) * 0.1)
		var dyn: float = dir_noise.get_noise_3d(float(prev_px) * 0.1 + 31.0, float(prev_py) * 0.1 - 17.0, float(prev_pz) * 0.1 + 7.0)
		var dzn: float = dir_noise.get_noise_3d(float(prev_px) * 0.1 - 19.0, float(prev_py) * 0.1 + 11.0, float(prev_pz) * 0.1 - 23.0)
		var dir: Vector3 = Vector3(dxn, dyn * 0.4, dzn).normalized()

		var px: int = prev_px + int(dir.x * float(step_len))
		var py: int = prev_py + int(dir.y * float(step_len))
		var pz: int = prev_pz + int(dir.z * float(step_len))

		if py < y_min:
			py = y_min
		if py > y_max:
			py = y_max

		var rr: int = _rangei(CHAIN_R_MIN, CHAIN_R_MAX, h + 41 + k * 5)
		_fill_ball(blocks, touched, touched_top, base_x, base_z, cx, cy, cz, px, py, pz, rr)

		# bridge between nodes for navigable routes
		var br: int = _rangei(BRIDGE_RADIUS_MIN, BRIDGE_RADIUS_MAX, h + 53 + k * 3)
		_fill_line(blocks, touched, touched_top, base_x, base_z, cx, cy, cz, Vector3(prev_px, prev_py, prev_pz), Vector3(px, py, pz), br)

		prev_px = px
		prev_py = py
		prev_pz = pz
		k += 1

# ====================== MICRO ===========================

static func _micro_debris(
		blocks: Array,
		touched: PackedByteArray,
		touched_top: PackedInt32Array,
		base_x: int,
		base_z: int,
		cx: int,
		cy: int,
		cz: int,
		y_min: int,
		y_max: int,
		seed: int,
		micro_noise: FastNoiseLite
	) -> void:

	var x: int = 0
	while x < cx:
		var z: int = 0
		while z < cz:
			var y: int = y_min
			while y <= y_max:
				var n: float = micro_noise.get_noise_3d(float(base_x + x), float(y), float(base_z + z))
				if n > 0.58:
					var gate: float = _hash01(seed + (base_x + x) * 928371 + y * 523 + (base_z + z) * 19349663)
					if gate < MICRO_DENSITY:
						var rr: int = _rangei(MICRO_R_MIN, MICRO_R_MAX, seed + x * 131 + y * 37 + z * 17)
						var fin_gate: float = _hash01(seed + x * 17 + y * 29 + z * 31)
						if fin_gate < FIN_CHANCE:
							_fill_plate(blocks, touched, touched_top, cx, cy, cz, x, y, z, rr)
						else:
							_fill_ball_local(blocks, touched, touched_top, cx, cy, cz, x, y, z, rr)
				y += 3
			z += 3
		x += 3

# ====================== SPIRES ==========================

static func _option_spires(
		blocks: Array,
		touched: PackedByteArray,
		touched_top: PackedInt32Array,
		base_x: int,
		base_z: int,
		cx: int,
		cy: int,
		cz: int,
		y_min: int,
		y_max: int,
		seed: int
	) -> void:

	var tries: int = 5
	var i: int = 0
	while i < tries:
		var h: int = _hash3(seed, base_x + i * 17, base_z + i * 31)
		var gate: float = _hash01(h + 7)
		if gate < SPIRE_CHANCE:
			var lx: int = _rangei(2, cx - 3, h + 11)
			var lz: int = _rangei(2, cz - 3, h + 13)
			var y_scan: int = y_max
			var found: bool = false
			while y_scan >= y_min:
				var id: int = int((blocks[lx] as Array)[y_scan][lz])
				if id != BlockDB.BlockId.AIR:
					found = true
					break
				y_scan -= 1
			if found:
				var sp_len: int = _rangei(SPIRE_LEN_MIN, SPIRE_LEN_MAX, h + 19)
				var sp_r0: int = _rangei(SPIRE_R_MIN, SPIRE_R_MAX, h + 23)
				var yy: int = 0
				while yy < sp_len and (y_scan - yy) >= 2:
					var r_here: int = sp_r0 - (yy / 3)
					if r_here < 1:
						r_here = 1
					_fill_disc_local(blocks, touched, touched_top, cx, cy, cz, lx, y_scan - yy, lz, r_here)
					yy += 1
		i += 1

# ========== Post-process: skin near island tops + HM =====

static func _skin_and_update_hm(
		blocks: Array,
		touched: PackedByteArray,
		touched_top: PackedInt32Array,
		cx: int,
		cy: int,
		cz: int,
		hm: PackedInt32Array
	) -> void:

	var x: int = 0
	while x < cx:
		var z: int = 0
		while z < cz:
			var idx: int = x * cz + z
			if touched[idx] != 0:
				var y_top_island: int = touched_top[idx]
				if y_top_island >= 0:
					# Only touch a small vertical window around the island top,
					# so ground columns below are never modified.
					var y_start: int = y_top_island + 3
					if y_start > cy - 2:
						y_start = cy - 2
					var y_stop: int = y_top_island - 6
					if y_stop < 1:
						y_stop = 1

					var y: int = y_start
					var new_top: int = -1
					while y >= y_stop:
						var id: int = int((blocks[x] as Array)[y][z])
						if id != BlockDB.BlockId.AIR:
							if new_top == -1:
								(blocks[x] as Array)[y][z] = BlockDB.BlockId.GRASS
								new_top = y
								var d1: int = y - 1
								var d2: int = y - 2
								var d3: int = y - 3
								if d1 >= 0 and int((blocks[x] as Array)[d1][z]) != BlockDB.BlockId.AIR:
									(blocks[x] as Array)[d1][z] = BlockDB.BlockId.DIRT
								if d2 >= 0 and int((blocks[x] as Array)[d2][z]) != BlockDB.BlockId.AIR:
									(blocks[x] as Array)[d2][z] = BlockDB.BlockId.DIRT
								if d3 >= 0 and int((blocks[x] as Array)[d3][z]) != BlockDB.BlockId.AIR:
									(blocks[x] as Array)[d3][z] = BlockDB.BlockId.DIRT
						y -= 1

					if new_top > hm[idx]:
						hm[idx] = new_top
			z += 1
		x += 1

# ============== Solid fill primitives ====================

static func _fill_ellipsoid(
		blocks: Array,
		touched: PackedByteArray,
		touched_top: PackedInt32Array,
		base_x: int,
		base_z: int,
		cx: int,
		cy: int,
		cz: int,
		wx: int,
		wy: int,
		wz: int,
		rx: int,
		ry: int,
		rz: int,
		warp: FastNoiseLite
	) -> void:

	var lx0: int = wx - rx - base_x
	var lz0: int = wz - rz - base_z
	var lx1: int = wx + rx - base_x
	var lz1: int = wz + rz - base_z
	var ly0: int = wy - ry
	var ly1: int = wy + ry

	if lx0 < 0:
		lx0 = 0
	if lz0 < 0:
		lz0 = 0
	if ly0 < 0:
		ly0 = 0
	if lx1 > cx - 1:
		lx1 = cx - 1
	if lz1 > cz - 1:
		lz1 = cz - 1
	if ly1 > cy - 1:
		ly1 = cy - 1

	var inv_rx2: float = 1.0 / float(rx * rx)
	var inv_ry2: float = 1.0 / float(ry * ry)
	var inv_rz2: float = 1.0 / float(rz * rz)

	var x: int = lx0
	while x <= lx1:
		var z: int = lz0
		while z <= lz1:
			var y: int = ly0
			while y <= ly1:
				var dx: float = float(base_x + x - wx)
				var dy: float = float(y - wy)
				var dz: float = float(base_z + z - wz)
				var dw: float = warp.get_noise_3d(float(base_x + x), float(y), float(base_z + z)) * 0.25
				var v: float = (dx * dx) * inv_rx2 + (dy * dy) * inv_ry2 + (dz * dz) * inv_rz2 + dw
				if v <= 1.0:
					_set_stone_if_air(blocks, touched, touched_top, cx, cy, cz, x, y, z)
				y += 1
			z += 1
		x += 1

static func _fill_ball(
		blocks: Array,
		touched: PackedByteArray,
		touched_top: PackedInt32Array,
		base_x: int,
		base_z: int,
		cx: int,
		cy: int,
		cz: int,
		wx: int,
		wy: int,
		wz: int,
		r: int
	) -> void:
	_fill_ball_local(blocks, touched, touched_top, cx, cy, cz, wx - base_x, wy, wz - base_z, r)

static func _fill_ball_local(
		blocks: Array,
		touched: PackedByteArray,
		touched_top: PackedInt32Array,
		cx: int,
		cy: int,
		cz: int,
		lx: int,
		ly: int,
		lz: int,
		r: int
	) -> void:

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
					_set_stone_if_air(blocks, touched, touched_top, cx, cy, cz, x, y, z)
				z += 1
			y += 1
		x += 1

static func _fill_disc_local(
		blocks: Array,
		touched: PackedByteArray,
		touched_top: PackedInt32Array,
		cx: int,
		cy: int,
		cz: int,
		lx: int,
		ly: int,
		lz: int,
		r: int
	) -> void:

	var r2: int = r * r
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
				_set_stone_if_air(blocks, touched, touched_top, cx, cy, cz, x, ly, z)
			z += 1
		x += 1

static func _fill_plate(
		blocks: Array,
		touched: PackedByteArray,
		touched_top: PackedInt32Array,
		cx: int,
		cy: int,
		cz: int,
		lx: int,
		ly: int,
		lz: int,
		r: int
	) -> void:

	# thin fin: stack a couple of offset discs
	var layers: int = 2
	var i: int = 0
	while i < layers:
		_fill_disc_local(blocks, touched, touched_top, cx, cy, cz, lx, ly + i, lz, r)
		i += 1

static func _fill_line(
		blocks: Array,
		touched: PackedByteArray,
		touched_top: PackedInt32Array,
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
		if lx >= 0 and lx < cx and ly >= 0 and ly < cy and lz >= 0 and lz < cz:
			_fill_ball_local(blocks, touched, touched_top, cx, cy, cz, lx, ly, lz, r)
		i += 1

static func _set_stone_if_air(
		blocks: Array,
		touched: PackedByteArray,
		touched_top: PackedInt32Array,
		cx: int,
		cy: int,
		cz: int,
		lx: int,
		ly: int,
		lz: int
	) -> void:

	if lx < 0 or lx >= cx:
		return
	if ly < 0 or ly >= cy:
		return
	if lz < 0 or lz >= cz:
		return

	var id: int = int((blocks[lx] as Array)[ly][lz])
	if id == BlockDB.BlockId.AIR:
		(blocks[lx] as Array)[ly][lz] = BlockDB.BlockId.STONE
		var idx: int = lx * cz + lz
		if idx >= 0 and idx < touched.size():
			touched[idx] = 1
			if ly > touched_top[idx]:
				touched_top[idx] = ly

# ================= math + rng ============================

static func _pick_radius(h: int, rmin: int, rmax: int, rtail: int) -> int:
	var base_t: float = _hash01(h + 5)
	var core: int = int(_lerpf(float(rmin), float(rmax), base_t))
	var tail: float = _hash01(h + 9)
	if tail > 0.94:
		var k: float = _hash01(h + 13)
		var big: float = _lerpf(float(rmax), float(rtail), k)
		return int(big)
	return core

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
	var u: int = _hash3(x, x >> 1, x << 1)
	var v: int = (u & 0x7fffffff)
	return float(v) / 2147483647.0

static func _rangei(a: int, b: int, salt: int) -> int:
	if b <= a:
		return a
	var t: float = _hash01(salt)
	var f: float = _lerpf(float(a), float(b), t)
	return int(f)

static func _remap(v: int, a0: int, a1: int, b0: int, b1: int) -> int:
	var t: float = 0.0
	if a1 != a0:
		t = float(v - a0) / float(a1 - a0)
	var f: float = _lerpf(float(b0), float(b1), t)
	return int(f)

static func _lerpf(a: float, b: float, t: float) -> float:
	return a + (b - a) * t
