extends AnimatableBody2D
## 推车关的箱子：沿警戒线（push_path）一格一格往前挪
##
## 规则（用户定）：
##   1) 箱子自己走，玩家待在箱子 8 格方格范围内就行
##   2) 基础每格 3 秒；每多 1 名存活临时友方快 0.5 秒，最多快 1 秒（最快 2 秒/格）
##   3) 有敌人在范围内时箱子停下
##   4) 玩家连续 20 秒不在范围内，箱子以半速沿警戒线后退
##   5) 起点/终点各是 3x3 区域，箱子走到终点就通关

signal progress_changed(moved: int, total: int)
signal arrived()
signal status_changed(status: String)

const TILE := 16
const STATUS_IDLE := "idle"
const STATUS_FORWARD := "forward"
const STATUS_BLOCKED := "blocked"
const STATUS_ABANDONED := "abandoned"
const STATUS_ARRIVED := "arrived"

@export var base_step_seconds: float = 3.0
@export var ally_bonus_seconds: float = 0.5
@export var ally_bonus_max: float = 1.0
@export var player_near_cells: int = 8
@export var enemy_near_cells: int = 8
@export var abandon_seconds: float = 20.0
@export var back_speed_ratio: float = 0.5

var path: Array[Vector2i] = []
var ally_count: int = 0
var status: String = STATUS_IDLE
var arrived_flag: bool = false

var player_ref: Node2D = null
var enemy_container: Node = null

## 当前位置用"浮点格号"表示：3.5 = 第 3 格走到一半
var _progress: float = 0.0
var _idle_time: float = 0.0
var _last_index: int = 0


func setup(cells: Array[Vector2i], player: Node2D, enemies: Node) -> void:
	path = cells
	player_ref = player
	enemy_container = enemies
	_progress = 0.0
	_idle_time = 0.0
	_last_index = 0
	arrived_flag = false
	status = STATUS_IDLE
	_sync_position()
	if not path.is_empty():
		progress_changed.emit(0, total_cells())


func total_cells() -> int:
	return maxi(path.size() - 1, 0)


func moved_cells() -> int:
	return clampi(int(floor(_progress)), 0, total_cells())


## 当前每格需要几秒（含友方加速）
func step_seconds() -> float:
	var bonus := minf(ally_bonus_seconds * float(maxi(ally_count, 0)), ally_bonus_max)
	return maxf(base_step_seconds - bonus, 0.5)


func progress_ratio() -> float:
	var total := total_cells()
	if total <= 0:
		return 1.0
	return clampf(_progress / float(total), 0.0, 1.0)


func _process(delta: float) -> void:
	advance(delta)


## 推进一帧（测试里也直接调这个，才能稳定复现）
func advance(delta: float) -> void:
	if path.size() < 2 or arrived_flag:
		return
	var next_status := STATUS_FORWARD
	if _enemy_near():
		# 敌人在范围内：箱子停住，但玩家计时照常走
		next_status = STATUS_BLOCKED
		_update_idle(delta)
	elif not _player_near():
		_update_idle(delta)
		if _idle_time >= abandon_seconds:
			next_status = STATUS_ABANDONED
			# 后退速度 = 前进的一半 => 每格耗时翻倍
			_progress -= delta * back_speed_ratio / step_seconds()
		else:
			next_status = STATUS_IDLE
	else:
		_idle_time = 0.0
		_progress += delta / step_seconds()

	_progress = clampf(_progress, 0.0, float(total_cells()))
	_sync_position()
	_emit_progress()
	if next_status != status:
		status = next_status
		status_changed.emit(status)
	if _progress >= float(total_cells()) and not arrived_flag:
		arrived_flag = true
		status = STATUS_ARRIVED
		status_changed.emit(status)
		arrived.emit()


func _update_idle(delta: float) -> void:
	_idle_time += delta


func _emit_progress() -> void:
	var current := moved_cells()
	if current != _last_index:
		_last_index = current
		progress_changed.emit(current, total_cells())


func _sync_position() -> void:
	if path.is_empty():
		return
	var index := clampi(int(floor(_progress)), 0, path.size() - 1)
	var frac := clampf(_progress - float(index), 0.0, 1.0)
	var from := _cell_center(path[index])
	var to := from
	if index + 1 < path.size():
		to = _cell_center(path[index + 1])
	global_position = from.lerp(to, frac)


func _cell_center(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * TILE + TILE * 0.5, cell.y * TILE + TILE * 0.5)


func _player_near() -> bool:
	if player_ref == null or not is_instance_valid(player_ref):
		return false
	return _cell_distance(global_position, player_ref.global_position) <= float(player_near_cells)


func _enemy_near() -> bool:
	if enemy_container == null or not is_instance_valid(enemy_container):
		return false
	for child in enemy_container.get_children():
		if not (child is Node2D) or not is_instance_valid(child):
			continue
		if child is Enemy and bool((child as Enemy).is_dead):
			continue
		if _cell_distance(global_position, (child as Node2D).global_position) <= float(enemy_near_cells):
			return true
	return false


## 方格距离（横竖斜都算一格）
func _cell_distance(a: Vector2, b: Vector2) -> float:
	var dx := absf(a.x - b.x) / float(TILE)
	var dy := absf(a.y - b.y) / float(TILE)
	return maxf(dx, dy)
