extends Node
## 对话系统（Autoload 名：DialogueManager）—— M0 只搭骨架，M4 补全。
## 目标：地图上的 NPC 靠近按 E 触发 → 底部对话框 + 打字机 + 选项分支。
## 对话期间只锁玩家输入，不用 get_tree().paused（否则会把对话 UI 一起冻住）。

signal dialogue_started(data)
# M4 才会用到；先用 @warning_ignore 消掉"声明但未使用"的启动告警
@warning_ignore("unused_signal")
signal dialogue_line_changed(index: int, line: Dictionary)
signal dialogue_finished

var is_active: bool = false


func start_dialogue(data) -> void:
	# TODO(M4)：实例化 DialogueBox、按行推进打字机、处理选项分支
	push_warning("DialogueManager.start_dialogue() 尚未实现（计划在 M4 落地）")
	is_active = true
	dialogue_started.emit(data)


func finish() -> void:
	if not is_active:
		return
	is_active = false
	dialogue_finished.emit()
