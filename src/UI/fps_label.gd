extends Label
class_name FpsLabel

@export_range(0.1, 60.0, 0.1)
var average_window_seconds: float = 5.0

var _sample_times: Array[float] = []
var _sample_fps: Array[float] = []
var _sum_fps: float = 0.0
var _elapsed: float = 0.0

func _ready() -> void:
	text = "0 (0)"

func _process(delta: float) -> void:
	_elapsed += delta

	var fps_now: float = Engine.get_frames_per_second()
	_sample_times.push_back(_elapsed)
	_sample_fps.push_back(fps_now)
	_sum_fps += fps_now

	var cutoff: float = _elapsed - average_window_seconds
	while _sample_times.size() > 0 and _sample_times[0] < cutoff:
		_sum_fps -= _sample_fps[0]
		_sample_times.pop_front()
		_sample_fps.pop_front()

	var count: int = _sample_fps.size()
	var avg_fps: float = fps_now
	if count > 0:
		avg_fps = _sum_fps / float(count)

	var current_i: int = roundi(fps_now)
	var average_i: int = roundi(avg_fps)
	text ="FPS:" + str(current_i) + " (" + str(average_i) + ")"

func set_average_window_seconds(seconds: float) -> void:
	if seconds < 0.1:
		seconds = 0.1
	average_window_seconds = seconds

	var cutoff: float = _elapsed - average_window_seconds
	while _sample_times.size() > 0 and _sample_times[0] < cutoff:
		_sum_fps -= _sample_fps[0]
		_sample_times.pop_front()
		_sample_fps.pop_front()

func reset_average() -> void:
	_sample_times.clear()
	_sample_fps.clear()
	_sum_fps = 0.0
