extends Node
## 全局设置（autoload: GameSettings）
##
## 存档位置：user://settings.cfg
## 和玩家存档（user://run_save.json）在同一个应用数据目录里：
##   Windows: %APPDATA%\Godot\app_userdata\唯时代尔\
##
## 三项设置：
##   1) 窗口分辨率（列表里还带一个"全屏"选项）
##   2) 背景音量（0~100%，默认 85% ≈ 原来的 -6 dB）
##   3) 射击操作模式（键盘方向键射击 / 鼠标左键射击，严格二选一）

signal changed                    ## 任意设置被改动
signal window_focus_lost          ## 窗口失去焦点（按 Win / Alt+Tab）

const SETTINGS_PATH := "user://settings.cfg"
## 分辨率选项（"全屏"不是单独一项，它和当前分辨率组合使用）
const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1152, 648),
	Vector2i(1280, 720),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
]
const DEFAULT_RESOLUTION_INDEX := 0
const VOLUME_STEP := 5
const DEFAULT_VOLUME_PERCENT := 85
const SHOOT_MODE_KEYBOARD := "keyboard"
const SHOOT_MODE_MOUSE := "mouse"

var resolution_index := DEFAULT_RESOLUTION_INDEX
var fullscreen := false
var volume_percent := DEFAULT_VOLUME_PERCENT
var shoot_mode := SHOOT_MODE_KEYBOARD


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS      # 暂停时也要能响应失焦通知
	load_settings()
	apply_window()
	apply_volume()


# ---------------- 取值 ----------------

func resolution() -> Vector2i:
	return RESOLUTIONS[clampi(resolution_index, 0, RESOLUTIONS.size() - 1)]


func resolution_text(index: int = -1) -> String:
	var i := clampi(index if index >= 0 else resolution_index, 0, RESOLUTIONS.size() - 1)
	var size := RESOLUTIONS[i]
	return "%d x %d" % [size.x, size.y]


## 折叠状态下显示的文字：全屏时前面带"全屏"
func display_text() -> String:
	return ("全屏  %s" % resolution_text()) if fullscreen else resolution_text()


func is_mouse_shoot() -> bool:
	return shoot_mode == SHOOT_MODE_MOUSE


func shoot_mode_text() -> String:
	return "鼠标射击" if is_mouse_shoot() else "键盘射击"


# ---------------- 改值（改完立刻生效并存盘）----------------

func set_resolution_index(index: int) -> void:
	resolution_index = clampi(index, 0, RESOLUTIONS.size() - 1)
	apply_window()
	save_settings()
	changed.emit()


func set_fullscreen(value: bool) -> void:
	if fullscreen == value:
		return
	fullscreen = value
	apply_window()
	save_settings()
	changed.emit()


func set_volume_percent(value: int) -> void:
	var clamped := clampi(value, 0, 100)
	if clamped == volume_percent:
		return
	volume_percent = clamped
	apply_volume()
	save_settings()
	changed.emit()


func set_shoot_mode(mode: String) -> void:
	var normal := SHOOT_MODE_MOUSE if mode == SHOOT_MODE_MOUSE else SHOOT_MODE_KEYBOARD
	if normal == shoot_mode:
		return
	shoot_mode = normal
	save_settings()
	changed.emit()


## 鼠标射击换成自定义准星；键盘射击恢复系统指针
func apply_cursor(want_custom: bool) -> void:
	if not want_custom:
		Input.set_custom_mouse_cursor(null)
		return
	Input.set_custom_mouse_cursor(_make_aim_cursor(), Input.CURSOR_ARROW, Vector2(1, 1))


## 准星就是 3x2 像素的倒三角，像素块之间不留空隙：
##   第一排：白 红 白      第二排：透明 白 透明（尖朝下）
## hotspot 取尖角那个像素，鼠标点击的位置就是三角尖
func _make_aim_cursor() -> Texture2D:
	var white := Color(1.0, 1.0, 1.0, 1.0)
	var red := Color(1.0, 0.0, 0.0, 1.0)
	var clear := Color(0.0, 0.0, 0.0, 0.0)
	var image := Image.create(3, 2, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, white)
	image.set_pixel(1, 0, red)
	image.set_pixel(2, 0, white)
	image.set_pixel(0, 1, clear)
	image.set_pixel(1, 1, white)
	image.set_pixel(2, 1, clear)
	return ImageTexture.create_from_image(image)


# ---------------- 应用 ----------------

func apply_window() -> void:
	if DisplayServer.get_name() == "headless":
		return                                    # 自检环境没有真实窗口
	var size := resolution()
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(size)
		_center_window()
	DisplayServer.window_set_size(size)           # 全屏时也要把渲染尺寸设对


func _center_window() -> void:
	var screen := DisplayServer.screen_get_size()
	var window_size := DisplayServer.window_get_size()
	if screen.x > 0 and screen.y > 0:
		DisplayServer.window_set_position(Vector2i(
			maxi((screen.x - window_size.x) / 2, 0), maxi((screen.y - window_size.y) / 2, 0)))


func apply_volume() -> void:
	MusicManager.set_volume_percent(volume_percent)


# ---------------- 读写 ----------------

func load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return
	resolution_index = clampi(int(config.get_value("window", "resolution_index", DEFAULT_RESOLUTION_INDEX)),
		0, RESOLUTIONS.size() - 1)
	fullscreen = bool(config.get_value("window", "fullscreen", false))
	volume_percent = clampi(int(config.get_value("audio", "volume_percent", DEFAULT_VOLUME_PERCENT)), 0, 100)
	shoot_mode = String(config.get_value("input", "shoot_mode", SHOOT_MODE_KEYBOARD))
	if shoot_mode != SHOOT_MODE_MOUSE:
		shoot_mode = SHOOT_MODE_KEYBOARD


func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("window", "resolution_index", resolution_index)
	config.set_value("window", "fullscreen", fullscreen)
	config.set_value("audio", "volume_percent", volume_percent)
	config.set_value("input", "shoot_mode", shoot_mode)
	var err := config.save(SETTINGS_PATH)
	if err != OK:
		push_warning("[GameSettings] 设置写入失败: %s" % SETTINGS_PATH)


# ---------------- 失焦 ----------------

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_on_focus_lost()


## 按 Win / Alt+Tab：全屏先退回窗口化（这样能看到桌面），再通知场景暂停
func _on_focus_lost() -> void:
	if fullscreen:
		set_fullscreen(false)
	window_focus_lost.emit()
