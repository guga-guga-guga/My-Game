extends Node
## 全局调试日志开关（autoload: DebugLog）
##
## 平常完全静默（发布版也一样），只有"打开开关"之后才会打印。
## 打开方式有两条：
##   1) 启动参数：游戏.exe -- --log          （export 版也能用）
##   2) 游戏里按 ` 键（键盘左上角那个波浪号键）唤出一个命令输入框，输入：
##        log on      打开打印
##        log off     关闭打印
##        log         查看当前状态
##
## 代码里统一写 DebugLog.log_line("...")，不要直接 print。

signal log_enabled_changed(enabled: bool)

const FONT_ROW := 20
const COLOR_HINT := Color(0.70, 0.85, 1.0)

var enabled := false
var _input_layer: CanvasLayer = null
var _edit: LineEdit = null
var _hint: Label = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for arg in OS.get_cmdline_user_args():
		if arg == "--log" or arg == "--debug-log":
			enabled = true
			print("[DebugLog] 启动参数开启了打印")
	_build_input_ui()


## 代码里所有调试打印都走这里
func log_line(text) -> void:
	if enabled:
		print(text)


func set_enabled(value: bool) -> void:
	if enabled == value:
		return
	enabled = value
	log_enabled_changed.emit(enabled)
	if enabled:
		print("[DebugLog] 打印已开启（输入 log off 关闭）")
	else:
		print("[DebugLog] 打印已关闭")


func toggle() -> void:
	set_enabled(not enabled)


# ---------------- 命令输入框（按 ` 唤出）----------------

func _build_input_ui() -> void:
	_input_layer = CanvasLayer.new()
	_input_layer.name = "DebugLogLayer"
	_input_layer.layer = 100
	add_child(_input_layer)

	var box := HBoxContainer.new()
	box.name = "DebugLogInput"
	box.set_anchors_preset(Control.PRESET_TOP_LEFT)
	box.position = Vector2(16, 16)
	_input_layer.add_child(box)

	_edit = LineEdit.new()
	_edit.custom_minimum_size = Vector2(320, 30)
	_edit.placeholder_text = "输入 log on / log off / log"
	_edit.add_theme_font_size_override("font_size", FONT_ROW)
	_edit.text_submitted.connect(_on_command_submitted)
	box.add_child(_edit)

	_hint = Label.new()
	_hint.text = " "
	_hint.add_theme_font_size_override("font_size", FONT_ROW)
	_hint.add_theme_color_override("font_color", COLOR_HINT)
	box.add_child(_hint)
	_input_layer.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	var is_backtick := key.keycode == KEY_QUOTELEFT or key.physical_keycode == KEY_QUOTELEFT
	var is_f2 := key.keycode == KEY_F2 or key.physical_keycode == KEY_F2
	if is_backtick or is_f2:                    # ` 键或 F2：开关输入框
		_input_layer.visible = not _input_layer.visible
		if _input_layer.visible:
			_edit.text = ""
			_edit.visible = true
			_edit.grab_focus()
		else:
			_edit.release_focus()
		var viewport := get_viewport()
		if viewport != null:
			viewport.set_input_as_handled()


func _on_command_submitted(text: String) -> void:
	var command := text.strip_edges().to_lower()
	match command:
		"log on":
			set_enabled(true)
			_hint.text = "打印已开启"
		"log off":
			set_enabled(false)
			_hint.text = "打印已关闭"
		"log":
			_hint.text = "当前打印：%s" % ("开启" if enabled else "关闭")
		_:
			_hint.text = "未知指令：%s（可用：log on / log off / log）" % text
	_edit.text = ""
	_edit.release_focus()
	_input_layer.visible = false
