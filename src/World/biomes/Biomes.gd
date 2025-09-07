# res://biomes/Biomes.gd
class_name Biome
extends RefCounted

# Helper for weighted block variety via noise
static func pick_weighted(n01: float, pairs: Array) -> int:
	# pairs: [[block_id, weight], ...]
	var total = 0.0
	for p in pairs: total += float(p[1])
	var t = n01 * total
	var run = 0.0
	for p in pairs:
		run += float(p[1])
		if t <= run:
			return int(p[0])
	return int(pairs.back()[0])

# ------------ Base interface ------------
func id() -> String: return "base"

# Height must return a **top surface Y (inclusive)**.
func height(wx:int, wz:int, N:Dictionary, min_y:int, max_y:int) -> int:
	return min_y

# Fill the column [0..h] with blocks (surface/under/stone).
func fill_column(blocks:Array, x:int, z:int, h:int, wx:int, wz:int, N:Dictionary) -> void:
	# default: grass/dirt/stone
	for y in range(0, h):
		var id = 2 # DIRT
		if y == h - 1: id = 1 # GRASS
		elif y < h - 10: id = 3 # STONE
		blocks[x][y][z] = id

# Optional decoration (trees, spikes, extras). Return true if you changed blocks.
func decorate(blocks:Array, x:int, z:int, h:int, wx:int, wz:int, N:Dictionary) -> bool:
	return false


# ======================================================================
# Rolling Hills — your current vibe
# ======================================================================
class RollingHills extends Biome:
	func id() -> String: return "hills"

	func height(wx:int, wz:int, N:Dictionary, min_y:int, max_y:int) -> int:
		var n = N.height.get_noise_2d(wx, wz) # [-1..1]
		var h_f = remap(n, -1.0, 1.0, float(min_y), float(max_y))
		return clamp(int(round(h_f)), 1, N.CY - 2)

	func fill_column(blocks:Array, x:int, z:int, h:int, wx:int, wz:int, N:Dictionary) -> void:
		# A touch of variety in stone layer (stone/cobble/mossy)
		for y in range(0, h):
			var id = 2 # DIRT
			if y == h - 1:
				id = 1 # GRASS
				# Minor “dirt specks” on steep slopes
				var slope = abs(N.height.get_noise_2d(wx+1, wz) - N.height.get_noise_2d(wx-1, wz)) \
						  + abs(N.height.get_noise_2d(wx, wz+1) - N.height.get_noise_2d(wx, wz-1))
				if slope > 0.9 and N.variety.get_noise_2d(wx*2, wz*2) > 0.15:
					id = 2 # DIRT
			elif y < h - 12:
				id = Biome.pick_weighted(
					0.5 * (N.variety.get_noise_3d(wx, y, wz) + 1.0),
					[[3, 6], [11, 3], [12, 1]] # STONE, COBBLE, MOSSY_COBBLE
				)
			blocks[x][y][z] = id

	func decorate(blocks:Array, x:int, z:int, h:int, wx:int, wz:int, N:Dictionary) -> bool:
		# Trees, same density as you have now
		var p = 0.5 * (N.tree.get_noise_2d(wx, wz) + 1.0)
		if p <= 0.80: return false
		# height + 4..6
		var hvar = 0.5 * (N.tree.get_noise_2d(wx + 12345, wz - 54321) + 1.0)
		var t_h = 4 + int(round(hvar * 2.0))
		# must be GRASS
		if blocks[x][h-1][z] != 1: return false
		for i in t_h:
			var py = h + i
			if py >= N.CY: break
			blocks[x][py][z] = 8 # LOG (oak)
		var top_y = h + t_h
		for dx in range(-2, 3):
			for dy in range(-2, 2):
				for dz in range(-2, 3):
					var px = x + dx; var py = top_y + dy; var pz = z + dz
					if px<0 or px>=N.CX or py<0 or py>=N.CY or pz<0 or pz>=N.CZ: continue
					var dist = Vector3(abs(dx), abs(dy)*1.3, abs(dz)).length()
					if dist <= 2.6:
						var keep = 0.5 * (N.leaf.get_noise_3d(float(wx + dx * 97), float(top_y + dy * 57), float(wz + dz * 131)) + 1.0)
						if keep > 0.15 and blocks[px][py][pz] == 0:
							blocks[px][py][pz] = 5 # LEAVES
		return true


# ======================================================================
# Grasslands — flatter, dense trees, dirt “pools”
# ======================================================================
class Grasslands extends Biome:
	func id() -> String: return "grass"

	func height(wx:int, wz:int, N:Dictionary, min_y:int, max_y:int) -> int:
		# much flatter; add small ripples
		var base = float(min_y) + 6.0
		var n1 = N.height.get_noise_2d(wx, wz) * 8.0
		var n2 = N.detail.get_noise_2d(wx*2, wz*2) * 4.0
		var h_f = base + n1 + n2
		return clamp(int(round(h_f)), 1, N.CY - 2)

	func fill_column(blocks:Array, x:int, z:int, h:int, wx:int, wz:int, N:Dictionary) -> void:
		# grass/dirt/stone baseline
		for y in range(0, h):
			var id = 2
			if y == h - 1:
				id = 1
				# Dirt pools: big soft blobs without killing the vibe
				var blob = 0.5*(N.patch.get_noise_2d(wx, wz)+1.0)
				if blob > 0.70:
					id = 2
			elif y < h - 10:
				id = 3
			blocks[x][y][z] = id

	func decorate(blocks:Array, x:int, z:int, h:int, wx:int, wz:int, N:Dictionary) -> bool:
		# Slightly more condensed than hills
		var p = 0.5 * (N.tree.get_noise_2d(wx, wz) + 1.0)
		if p <= 0.72: return false
		if blocks[x][h-1][z] != 1: return false
		var hvar = 0.5 * (N.tree.get_noise_2d(wx + 12345, wz - 54321) + 1.0)
		var t_h = 4 + int(round(hvar * 2.0))
		for i in t_h:
			var py = h + i
			if py >= N.CY: break
			blocks[x][py][z] = 21 # LOG_BIRCH
		var top_y = h + t_h
		for dx in range(-2, 3):
			for dy in range(-2, 2):
				for dz in range(-2, 3):
					var px = x + dx; var py = top_y + dy; var pz = z + dz
					if px<0 or px>=N.CX or py<0 or py>=N.CY or pz<0 or pz>=N.CZ: continue
					var dist = Vector3(abs(dx), abs(dy)*1.3, abs(dz)).length()
					if dist <= 2.5 and blocks[px][py][pz] == 0:
						var keep = 0.5 * (N.leaf.get_noise_3d(float(wx + dx * 97), float(top_y + dy * 57), float(wz + dz * 131)) + 1.0)
						if keep > 0.10:
							blocks[px][py][pz] = 5
		return true


# ======================================================================
# Desert — sandy with stone “pools”
# ======================================================================
class Desert extends Biome:
	func id() -> String: return "desert"

	func height(wx:int, wz:int, N:Dictionary, min_y:int, max_y:int) -> int:
		# dunes: gentle amplitude; a tiny bit of long-wave tilt
		var base = float(min_y) + 4.0
		var dunes = N.height.get_noise_2d(wx, wz) * 6.0
		var long = N.detail.get_noise_2d(wx*1, wz*1) * 2.0
		var h_f = base + dunes + long
		return clamp(int(round(h_f)), 1, N.CY - 2)

	func fill_column(blocks:Array, x:int, z:int, h:int, wx:int, wz:int, N:Dictionary) -> void:
		for y in range(0, h):
			var id = 6 # SAND
			if y < h - 12:
				# deeper mixes: stone etc
				id = Biome.pick_weighted(
					0.5*(N.variety.get_noise_3d(wx, y, wz)+1.0),
					[[6, 5], [3, 3], [11, 2]] # SAND, STONE, COBBLE
				)
			blocks[x][y][z] = id

		# Stone pools: overwrite surface to stone in roundish spots
		var pool = 0.5*(N.patch.get_noise_2d(wx, wz)+1.0)
		if pool > 0.75:
			blocks[x][h-1][z] = 3 # STONE

	func decorate(blocks:Array, x:int, z:int, h:int, wx:int, wz:int, N:Dictionary) -> bool:
		# Rare acacia
		var p = 0.5*(N.tree.get_noise_2d(wx, wz)+1.0)
		if p <= 0.90: return false
		if blocks[x][h-1][z] == 6:
			var hvar = 0.5*(N.tree.get_noise_2d(wx+7777, wz-2222)+1.0)
			var t_h = 3 + int(round(hvar*2.0))
			for i in t_h:
				var py = h + i; if py >= N.CY: break
				blocks[x][py][z] = 29 # LOG_ACACIA
			var top_y = h + t_h
			for dx in range(-2, 3):
				for dy in range(-1, 2):
					for dz in range(-2, 3):
						var px = x + dx; var py = top_y + dy; var pz = z + dz
						if px<0 or px>=N.CX or py<0 or py>=N.CY or pz<0 or pz>=N.CZ: continue
						if Vector3(dx,dy*1.5,dz).length() <= 2.2 and blocks[px][py][pz]==0:
							blocks[px][py][pz] = 5
			return true
		return false


# ======================================================================
# Peaks — jagged “farlands” spikes + occasional winding ledges
# ======================================================================
class Peaks extends Biome:
	func id() -> String: return "peaks"

	func height(wx:int, wz:int, N:Dictionary, min_y:int, max_y:int) -> int:
		# Ridged noise builds tall, spiky towers
		var ridged = abs(N.height.get_noise_2d(wx, wz)) # [0..1]
		var base = float(min_y) + 12.0
		var span = float(max_y) - base
		var spikes = pow(ridged, 2.5) * span
		var h = int(round(base + spikes))

		# Winding “worm” ledges (noise zero-crossings) that force a walkway height
		var line = N.ridge.get_noise_2d(wx, wz) # [-1..1]
		if abs(line) < 0.08:
			h = max(h, int(round(base + 0.65*span)))

		return clamp(h, 1, N.CY - 2)

	func fill_column(blocks:Array, x:int, z:int, h:int, wx:int, wz:int, N:Dictionary) -> void:
		# Tough stone palette with bricks & moss sprinkled
		for y in range(0, h):
			var id = Biome.pick_weighted(
				0.5*(N.variety.get_noise_3d(wx, y, wz)+1.0),
				[[3, 6], [11, 3], [12, 2], [13, 1], [14, 1]] # STONE, COBBLE, MOSSY_COBBLE, STONE_BRICKS, MOSSY_STONE_BRICKS
			)
			blocks[x][y][z] = id

		# Optional snow cap if very high
		if h >= min(N.CY-4, max(0, int(N.snow_line))):
			blocks[x][h-1][z] = 20 # SNOW_DIRT

	func decorate(blocks:Array, x:int, z:int, h:int, wx:int, wz:int, N:Dictionary) -> bool:
		# Spruce only on shelves: require flat-ish local slope and stone
		if blocks[x][h-1][z] == 3 or blocks[x][h-1][z] == 11:
			var slope = abs(N.height.get_noise_2d(wx+1, wz)-N.height.get_noise_2d(wx-1, wz)) \
					  + abs(N.height.get_noise_2d(wx, wz+1)-N.height.get_noise_2d(wx, wz-1))
			if slope < 0.7 and 0.5*(N.tree.get_noise_2d(wx, wz)+1.0) > 0.86:
				var t_h = 5
				for i in t_h:
					var py = h + i; if py >= N.CY: break
					blocks[x][py][z] = 25 # LOG_SPRUCE
				var top_y = h + t_h
				for dx in range(-2, 3):
					for dy in range(-2, 2):
						for dz in range(-2, 3):
							var px = x + dx; var py = top_y + dy; var pz = z + dz
							if px<0 or px>=N.CX or py<0 or py>=N.CY or pz<0 or pz>=N.CZ: continue
							if Vector3(abs(dx), abs(dy)*1.4, abs(dz)).length() <= 2.7 and blocks[px][py][pz]==0:
								var keep = 0.5*(N.leaf.get_noise_3d(float(wx + dx * 97), float(top_y + dy * 57), float(wz + dz * 131)) + 1.0)
								if keep > 0.12:
									blocks[px][py][pz] = 5
				return true
		return false


# ======================================================================
