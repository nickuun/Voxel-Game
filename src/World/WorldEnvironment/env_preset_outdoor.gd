# res://env_sunny_polish.gd
extends WorldEnvironment

@export var exposure: float = 1.08         # a hair brighter than neutral
@export var white_point: float = 6.0       # ACES sweet spot
@export var sky_brightness: float = 1.6    # slightly lower so sun matters

@export var ambient_energy: float = 0.60   # lower ambient => more sun/shadow contrast
@export var ambient_from_sky: float = 0.85 # 0..1, how much ambient comes from sky

# Subtle grounding shadows
@export var use_ssao := true
@export var ssao_intensity := 0.18
@export var ssao_radius := 0.18

# Light, sunny haze (not murk)
@export var use_fog := true
@export var fog_density := 0.00004
@export var fog_sky_affect := 0.2
@export var fog_aerial := 0.20
@export var fog_color: Color = Color(0.80, 0.90, 1.00) # soft blue

# A touch of bloom + vibrancy
@export var use_glow := true
@export var glow_intensity := 0.42
@export var glow_thresh := 1.18
@export var saturation := 1.14
@export var contrast := 1.06

func _ready() -> void:
	if environment == null:
		environment = Environment.new()

	# Sky
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var proc := ProceduralSkyMaterial.new()
	proc.sky_top_color = Color(0.11, 0.45, 0.97)
	proc.sky_horizon_color = Color(0.78, 0.92, 1.00)
	proc.ground_bottom_color = Color(0.82, 0.90, 0.98)
	sky.sky_material = proc
	environment.sky = sky
	environment.background_energy_multiplier = sky_brightness

	# Tonemap
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_exposure = exposure
	environment.tonemap_white = white_point

	# Ambient (dialed down for contrast)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_BG
	environment.ambient_light_sky_contribution = ambient_from_sky
	environment.ambient_light_energy = ambient_energy

	# SSAO (very light)
	environment.ssao_enabled = use_ssao
	environment.ssao_intensity = ssao_intensity
	environment.ssao_radius = ssao_radius
	environment.ssao_power = 1.0
	environment.ssao_detail = 0.6
	environment.ssao_light_affect = 0.0

	# Fog (super gentle)
	environment.fog_enabled = use_fog
	environment.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	environment.fog_density = fog_density
	environment.fog_light_color = fog_color
	environment.fog_sky_affect = fog_sky_affect
	environment.fog_aerial_perspective = fog_aerial

	# Bloom
	environment.glow_enabled = use_glow
	environment.glow_intensity = glow_intensity
	environment.glow_hdr_threshold = glow_thresh
	environment.glow_bloom = 0.05
	environment.glow_mix = 0.05

	# Slight color pop
	environment.adjustment_enabled = true
	environment.adjustment_saturation = saturation
	environment.adjustment_contrast = contrast

	self.environment = environment
