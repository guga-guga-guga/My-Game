extends Node
## 全局音乐管理（autoload: MusicManager）
## 三个场景三种曲子（用户指定）：
##   大厅（Hub 中间地图）-> 1-27 Journey of the Prairie King (Overworld)
##   BOSS 战            -> 1-29 Journey of the Prairie King (Final Boss & Ending)
##   其余（普通关/精英关/经典模式/标题）-> 1-28 Journey of the Prairie King (The Outlaw)
##
## 用 autoload 而不是各场景自带的 BgmPlayer，好处是**跨场景不会中断**：
## 连续打两关普通关时曲子继续放，而不会每关从头重播。
## 曲目在导入设置里没勾循环，所以这里 duplicate() 后手动打开 loop。

const TRACK_HUB := "res://resources/audio/1-27 Journey of the Prairie King (Overworld).mp3"
const TRACK_STAGE := "res://resources/audio/1-28 Journey of the Prairie King (The Outlaw).mp3"
const TRACK_BOSS := "res://resources/audio/1-29 Journey of the Prairie King (Final Boss & Ending).mp3"

## 音量：比音效轻一点，避免盖住枪声/爆炸
const VOLUME_DB := -6.0

var play_count := 0            ## 真正切歌的次数（自检用）
var _player: AudioStreamPlayer = null
var _current := ""


func _ready() -> void:
	# 场景树暂停（结算弹窗会把 time_scale 设 0）时音乐不该跟着停
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = AudioStreamPlayer.new()
	_player.name = "MusicPlayer"
	_player.volume_db = VOLUME_DB
	add_child(_player)
	_player.finished.connect(_on_finished)


func current_path() -> String:
	return _current


func is_playing() -> bool:
	return _player != null and _player.playing


func play_hub() -> void:
	play(TRACK_HUB)


func play_stage() -> void:
	play(TRACK_STAGE)


func play_boss() -> void:
	play(TRACK_BOSS)


## 切歌；同一首正在放就不动它（跨场景不重播的关键）
func play(path: String) -> void:
	if _player == null:
		return
	if path.is_empty() or not ResourceLoader.exists(path):
		push_warning("[Music] 找不到音频: %s" % path)
		return
	if _current == path:
		return                            # 同一首在放（或刚放完由 _on_finished 续上）就不重播
	var stream := load(path) as AudioStream
	if stream == null:
		push_warning("[Music] 加载失败: %s" % path)
		return
	var copied := stream.duplicate() as AudioStream
	if copied is AudioStreamMP3:
		(copied as AudioStreamMP3).loop = true
	elif copied is AudioStreamWAV:
		(copied as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	_current = path
	_player.stream = copied
	_player.play()
	play_count += 1
	print("[Music] 播放: %s" % path.get_file())


func stop() -> void:
	if _player != null:
		_player.stop()
	_current = ""


func _on_finished() -> void:
	# 兜底：万一哪首没循环成功，放完自动重来
	if _current != "" and _player != null:
		_player.play()
