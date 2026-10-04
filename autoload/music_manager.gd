extends Node
## 全局音乐管理（autoload: MusicManager）
## 曲目分配（用户指定）：
##   大厅（中间地图） / 标题界面        -> 1-27 Journey of the Prairie King (Overworld)
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
var _resume_after_focus := ""     ## 网页失焦时被停掉的曲子，场景树恢复后自动接回


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


func play_midmap() -> void:
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
	_resume_after_focus = ""
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
	_resume_after_focus = ""
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

## 网页（iframe 嵌入）失焦时停掉音乐：游戏被藏起来后音乐不能继续放给访客听。
## 场景树恢复（玩家点"继续游戏"）后自动把这首接回来。只在 web 平台生效，桌面端行为不变。
## ---------------- 与作品集站点的联动（仅 web） ----------------
## 父页面会把 window.__portfolioGameVisible 写成 true/false 表示游戏是否正在显示。
## 为什么不用失焦事件：实测把游戏层设成 visibility:hidden / display:none，
## iframe 内的 document.visibilityState 仍为 visible，Godot 不会知道自己被藏起来了。
const SITE_FLAG_JS := "typeof window.__portfolioGameVisible === 'undefined' ? '1' : (window.__portfolioGameVisible ? '1' : '0')"
const SITE_POLL_MS := 300

var _site_visible := true
var _frozen_by_site := false
var _time_scale_before_freeze := 1.0
var _next_site_poll_ms := 0


func _notification(what: int) -> void:
	if not OS.has_feature("web"):
		return
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_stop_and_remember("失焦")
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_resume_music("重新获得焦点")


## 轮询父页面写进来的界面状态。用真实时间而不是 delta ——
## 冻结期间 time_scale 为 0，delta 也是 0，靠 delta 计时就永远醒不过来了。
func _process(_delta: float) -> void:
	if not OS.has_feature("web"):
		return
	var now := Time.get_ticks_msec()
	if now < _next_site_poll_ms:
		return
	_next_site_poll_ms = now + SITE_POLL_MS
	var visible: bool = JavaScriptBridge.eval(SITE_FLAG_JS) != "0"   # eval 返回 Variant，必须显式标注类型
	if visible == _site_visible:
		return
	_site_visible = visible
	if visible:
		print("[Music] 站点重新显示游戏：解冻 + 接回音乐")
		_set_frozen_by_site(false)
		_resume_music("站点显示")
	else:
		print("[Music] 站点隐藏了游戏：冻结 + 停止音乐")
		_stop_and_remember("站点隐藏")
		_set_frozen_by_site(true)


## 冻结用 time_scale = 0（而不是 get_tree().paused）——
## 标题界面这类没有暂停菜单的场景一旦被 paused，玩家回来将无法操作。
## time_scale = 0 只让 delta 变 0，输入与 UI 仍然响应，是安全的冻结方式。
func _set_frozen_by_site(on: bool) -> void:
	if on == _frozen_by_site:
		return
	_frozen_by_site = on
	if on:
		_time_scale_before_freeze = Engine.time_scale
		Engine.time_scale = 0.0
	else:
		Engine.time_scale = _time_scale_before_freeze


## 停音乐并记住曲目，等重新显示时接回
func _stop_and_remember(why: String) -> void:
	if _current.is_empty():
		return
	var resume_path := _current
	stop()                                  # stop() 会清掉标记，所以要在它之后赋值
	_resume_after_focus = resume_path
	print("[Music] %s：停止音乐（%s）" % [why, resume_path.get_file()])


func _resume_music(why: String) -> void:
	if _resume_after_focus.is_empty():
		return
	var path := _resume_after_focus
	_resume_after_focus = ""
	play(path)
	print("[Music] %s：接回 %s" % [why, path.get_file()])

