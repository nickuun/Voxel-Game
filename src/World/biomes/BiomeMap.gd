# res://src/World/biomes/BiomeMap.gd
class_name BiomeMap
extends RefCounted

var biomes: Array = []
var by_name: Dictionary = {}

var chooser := FastNoiseLite.new()
var micro   := FastNoiseLite.new()

func _init(seed:int) -> void:
	chooser.noise_type = FastNoiseLite.TYPE_SIMPLEX
	chooser.fractal_octaves = 2
	chooser.frequency = 0.0017
	chooser.seed = seed

	micro.noise_type = FastNoiseLite.TYPE_SIMPLEX
	micro.fractal_octaves = 1
	micro.frequency = 0.01
	micro.seed = seed ^ 0xABCD

func add_biome(biome) -> void:
	biomes.append(biome)
	by_name[biome.id()] = biome

func get_biome(name:String):
	return by_name.get(name, null)

func pick(wx:int, wz:int):
	var v := chooser.get_noise_2d(wx, wz)
	var b = null
	if v < -0.70:
		b = get_biome("desert") 
	elif v < -0.45:
		b = get_biome("black_desert")
	elif v < 0.15:
		b = get_biome("grass")
	elif v < 0.55:
		b = get_biome("hills")
	else:
		b = get_biome("peaks")

	# Safety fallback to first registered biome to avoid Nil
	if b == null and biomes.size() > 0:
		b = biomes[0]
	return b
