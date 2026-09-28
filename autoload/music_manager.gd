extends Node
## 全局音乐管理（autoload: MusicManager）
## 曲目分配（用户指定）：
##   大厅（Hub） / 标题界面        -> 1-27 Journey of the Prairie King (Overworld)
##   BOSS 战（第 5 / 10 层）       -> 1-29 Journey of the Prairie King (Final Boss & Ending)
##   其余（普通关 / 精英关 / 经典模式） -> 1-28 Journey of the Prairie King (The Outlaw)
##
## 两个 AudioStreamPlayer 轮流用，切歌时交叉淡出（FADE_TIME 秒），不会硬切。
## 用 autoload 而不是各场景自带的 BgmPlayer：跨场景不中断，同一首不会重播。

signal track_changed(path: String)

const TRACK_OVERWORLD := "res://resources/audio/1-27 Journey of the Prairie King (Overworld).mp3"
const TRACK_OUTLAW := "res://resources/audio/1-28 Journey of the Prairie King (The Outlaw).mp3"
const TRACK_FINAL_BOSS := "res://resources/audio/1-29 Journey of the Prairie King (Final Boss & Ending).mp3"

const VOLUME_DB := -6.0            ## 正常音量（比音效轻一点）
const SILENT_DB := -40.0           ## 淡出/淡入的静音端
const FADE_TIME := 0.6             ## 交叉淡出时长（秒）

var play_count := 0                ## 真正切歌的次数（自检用）
var _players: Array[AudioStreamPlayer] = []
var _active := 0
var _current := ""
var _tween: Tween = null


func _ready() -> void:
	# 结算弹窗会把 time_scale 设 0，音乐不该跟着停
	process_mode = Node.PROCESS_MODE_ALWAYS
	for index in range(2):
		var player := AudioStreamPlayer.new()
		player.name = "MusicPlayer%d" % index
		player.volume_db = SILENT_DB
		add_child(player)
		player.finished.connect(_on_player_finished.bind(player))
		_players.append(player)


func current_path() -> String:
	return _current


func is_playing() -> bool:
	for player in _players:
		if player.playing:
			return true
	return false


func play_hub() -> void:
	play(TRACK_OVERWORLD)


## 标题界面也放大厅那首（用户要求）
func play_title() -> void:
	play(TRACK_OVERWORLD)


func play_stage() -> void:
	play(TRACK_OUTLAW)


func play_boss() -> void:
	play(TRACK_FINAL_BOSS)


## 切歌；同一首正在放就直接返回（跨场景不重播的关键）
func play(path: String) -> void:
	if _players.is_empty():
		return
	if path.is_empty() or not ResourceLoader.exists(path):
		push_warning("[Music] 找不到音频: %s" % path)
		return
	if _current == path:
		return
	var stream := load(path) as AudioStream
	if stream == null:
		push_warning("[Music] 加载失败: %s" % path)
		return
	var copied := stream.duplicate() as AudioStream
	if copied is AudioStreamMP3:
		(copied as AudioStreamMP3).loop = true      # mp3 导入没勾循环，这里手动打开
	elif copied is AudioStreamWAV:
		(copied as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD

	var outgoing := _players[_active]
	_active = 1 - _active
	var incoming := _players[_active]
	if _tween != null and _tween.is_valid():
		_tween.kill()                                # 上一次淡入淡出还没完就切：直接接管
	incoming.stream = copied
	incoming.volume_db = SILENT_DB
	incoming.play()
	_current = path
	play_count += 1
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.tween_property(incoming, "volume_db", VOLUME_DB, FADE_TIME)
	if outgoing.playing:
		_tween.tween_property(outgoing, "volume_db", SILENT_DB, FADE_TIME)
		_tween.chain().tween_callback(outgoing.stop)
	print("[Music] 播放: %s（交叉淡出 %.1fs）" % [path.get_file(), FADE_TIME])
	track_changed.emit(path)


func stop() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	for player in _players:
		player.stop()
		player.volume_db = SILENT_DB
	_current = ""


func _on_player_finished(player: AudioStreamPlayer) -> void:
	# 兜底：万一哪首没循环成功，放完自动重来
	if _current != "" and player == _players[_active]:
		player.play()


# ---------------- 供 headless 自检调用 ----------------

func debug_active_index() -> int:
	return _active


func debug_volumes() -> Array:
	var vols: Array = []
	for player in _players:
		vols.append(snappedf(player.volume_db, 0.01))
	return vols


func debug_is_playing(index: int) -> bool:
	if index < 0 or index >= _players.size():
		return false
	return _players[index].playing
