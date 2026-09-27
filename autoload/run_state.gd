extends Node
## 整局（Run）状态：跨场景常驻的单例（Autoload 名：RunState）。
## 这里的一"局"指一次完整闯关：标题 → 路线图 → 多场战斗 → 通关/失败。
## 单场战斗里的临时数据（本场击杀、本场倒计时）不放这里，放 Battle 自己身上。

signal run_started
signal run_finished(cleared: bool)
signal gold_changed(gold: int)
signal floor_changed(floor_index: int)

## 总层数（含最终 Boss 层）。后续 M3 会搬进关卡配置资源。
const MAX_FLOOR := 8

## 玩家基础数值：升级只加在"基础值"上，限时道具仍是独立倍率（三层数值，互不污染）
const BASE_MAX_HEALTH := 3
const BASE_MOVE_SPEED := 120.0
const BASE_FIRE_INTERVAL := 0.18

var is_active: bool = false          ## 是否处于一局进行中
var cleared: bool = false            ## 本局是否已通关
var floor_index: int = 1             ## 当前层（从 1 开始）
var gold: int = 0                    ## 金币（唯一来源：敌人掉落）
var total_kills: int = 0             ## 本局累计击杀
var run_elapsed: float = 0.0         ## 本局累计用时（秒）

# ---- 长效升级（M5 商店写入，Battle 开场读取）----
var bonus_max_health: int = 0
var move_speed_multiplier: float = 1.0
var fire_rate_multiplier: float = 1.0
var bonus_invincibility: float = 0.0

## 本层路线图（M3 由 RunMap 填充），M0 阶段留空
var route: Array = []


## 开始新的一局：把全部进度清零。
func reset() -> void:
	is_active = true
	cleared = false
	floor_index = 1
	gold = 0
	total_kills = 0
	run_elapsed = 0.0
	bonus_max_health = 0
	move_speed_multiplier = 1.0
	fire_rate_multiplier = 1.0
	bonus_invincibility = 0.0
	route.clear()
	run_started.emit()
	floor_changed.emit(floor_index)
	gold_changed.emit(gold)


# ---- 金币 ----
func add_gold(amount: int) -> void:
	if amount <= 0:
		return
	gold += amount
	gold_changed.emit(gold)


func try_spend_gold(amount: int) -> bool:
	if amount <= 0 or gold < amount:
		return false
	gold -= amount
	gold_changed.emit(gold)
	return true


# ---- 层数推进 ----
func advance_floor() -> void:
	floor_index += 1
	floor_changed.emit(floor_index)


func is_final_floor() -> bool:
	return floor_index >= MAX_FLOOR


# ---- 供 Player 取用的最终数值（基础值 × 升级）----
func get_player_max_health() -> int:
	return BASE_MAX_HEALTH + bonus_max_health


func get_player_move_speed() -> float:
	return BASE_MOVE_SPEED * move_speed_multiplier


func get_player_fire_interval() -> float:
	return BASE_FIRE_INTERVAL / maxf(fire_rate_multiplier, 0.01)


func finish_run(did_clear: bool) -> void:
	cleared = did_clear
	is_active = false
	run_finished.emit(did_clear)
