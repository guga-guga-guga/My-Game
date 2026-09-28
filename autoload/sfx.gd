extends Node
## 全局音效（autoload: SfxPlayer）
## 复用现有素材（resources/audio/Cowboy_*.wav），给 UI / 商店 / 拾取 / 交互 补上反馈音。
## 用一个固定的小池子播放，避免连点时互相打断；音量比音乐略高一点。
##
## 注意：每个方法都是"没有素材也不报错"（素材缺失只打一条 warning 并静默跳过）。

const VOLUME_DB := -4.0
const POOL_SIZE := 4

const SFX_CLICK := "res://resources/audio/cowboy_gopher.wav"        ## 按钮/选项
const SFX_BUY := "res://resources/audio/Cowboy_Secret.wav"          ## 购买成功
const SFX_PICKUP := "res://resources/audio/cowboy_powerup.wav"      ## 拾取道具
const SFX_INTERACT := "res://resources/audio/Cowboy_Footstep.wav"   ## 开始交互/开门

var _pool: Array[AudioStreamPlayer] = []
var _next := 0
var _cache: Dictionary = {}
var play_count := 0            ## 供自检


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for index in range(POOL_SIZE):
		var player := AudioStreamPlayer.new()
		player.name = "SfxPlayer%d" % index
		player.volume_db = VOLUME_DB
		add_child(player)
		_pool.append(player)


func ui_click() -> void:
	play(SFX_CLICK)


func buy() -> void:
	play(SFX_BUY)


func pickup() -> void:
	play(SFX_PICKUP)


func interact() -> void:
	play(SFX_INTERACT)


## 直接播放一个音效文件（自动轮换播放器，连点不会互相掐断）
func play(path: String) -> void:
	if _pool.is_empty():
		return
	var stream := _stream_for(path)
	if stream == null:
		return
	var player := _pool[_next]
	_next = (_next + 1) % _pool.size()
	player.stream = stream
	player.play()
	play_count += 1


func _stream_for(path: String) -> AudioStream:
	if _cache.has(path):
		return _cache[path]
	var stream := load(path) as AudioStream
	if stream == null:
		push_warning("[Sfx] 找不到音效: %s" % path)
		_cache[path] = null
		return null
	_cache[path] = stream
	return stream


# ---------------- 供 headless 自检调用 ----------------

func debug_cached_count() -> int:
	return _cache.size()


func debug_paths() -> Array:
	return [SFX_CLICK, SFX_BUY, SFX_PICKUP, SFX_INTERACT]
