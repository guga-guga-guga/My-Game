extends Node
## 整局 Run 状态:跨场景常驻的单例 Autoload 名:RunState 
## 这里的一"局"指一次完整闯关:标题 到 路线图 到 多场战斗 到 通关/失败
## 单场战斗里的临时数据 本场击杀，本场倒计时 不放这里，放 Battle 自己身上

signal run_started
signal run_finished(cleared: bool)
signal gold_changed(gold: int)
signal floor_changed(floor_index: int)

## 总层数 含最终 Boss 层 后续 M3 会搬进关卡配置资源
const MAX_FLOOR := 8

## 玩家基础数值:升级只加在"基础值"上，限时道具仍是独立倍率 三层数值，互不污染 
const BASE_MAX_HEALTH := 3
const BASE_MOVE_SPEED := 120.0
const BASE_FIRE_INTERVAL := 0.18

var is_active: bool = false          ## 是否处于一局进行中
var cleared: bool = false            ## 本局是否已通关
var floor_index: int = 1             ## 当前层 从 1 开始 
var gold: int = 0                    ## 金币 唯一来源:敌人掉落 
var total_kills: int = 0             ## 本局累计击杀
var run_elapsed: float = 0.0         ## 本局累计用时 秒 

# ---- 长效升级 M5 商店写入，Battle 开场读取 ----
# ---- 局内成长（Hub 商店写入，Battle 开场读取；新开一局重置）----
## 生命值：跨关卡保留（上一关剩多少，下一关就带多少）
var max_health: int = BASE_MAX_HEALTH
var current_health: int = BASE_MAX_HEALTH
## 子弹伤害（基础 1，商店每级 +1）
var player_damage: int = 1
## 射速等级（每级 +10%）
var fire_rate_level: int = 0
## 移速等级（预留）
var speed_level: int = 0
# ---- 旧字段（保留兼容）----
var bonus_max_health: int = 0
var move_speed_multiplier: float = 1.0
var fire_rate_multiplier: float = 1.0
var bonus_invincibility: float = 0.0

## 本层路线图 M3 由 RunMap 填充 ，M0 阶段留空
var route: Array = []


## 开始新的一局:把全部进度清零
func reset() -> void:
	is_active = true
	cleared = false
	floor_index = 1
	gold = 0
	total_kills = 0
	run_elapsed = 0.0
	max_health = BASE_MAX_HEALTH
	current_health = BASE_MAX_HEALTH
	player_damage = 1
	fire_rate_level = 0
	speed_level = 0
	bonus_max_health = 0
	move_speed_multiplier = 1.0
	fire_rate_multiplier = 1.0
	bonus_invincibility = 0.0
	route.clear()
	shop_buy_count.clear()
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


# ---- 供 Player 取用的最终数值 基础值 × 升级 ----
func get_player_max_health() -> int:
	return maxi(max_health, 1)


## 子弹伤害（商店升级驱动）
func get_player_damage() -> int:
	return maxi(player_damage, 1)


## 战斗结束时把这一场的血量写回整局状态（跨关卡保留的关键）
func set_health(current: int, maximum: int) -> void:
	max_health = maxi(maximum, 1)
	current_health = clampi(current, 1, max_health)


## 商店: +1 生命（上限与当前生命一起 +1）
func buy_max_health() -> void:
	max_health += 1
	current_health += 1


## 商店: 射速 +10%
func buy_fire_rate() -> void:
	fire_rate_level += 1


## 商店: 子弹伤害 +1
func buy_damage() -> void:
	player_damage += 1


func get_player_move_speed() -> float:
	return BASE_MOVE_SPEED * move_speed_multiplier


func get_player_fire_interval() -> float:
	return BASE_FIRE_INTERVAL / (maxf(fire_rate_multiplier, 0.01) * (1.0 + 0.1 * float(fire_rate_level)))


# ---- 商店（Hub，本局内有效；新开一局重置）----
const SHOP_KEYS: Array[String] = ["health", "fire_rate", "damage"]
const SHOP_PRICE_HEALTH := 15        ## 生命上限 +1 的初始价
const SHOP_PRICE_FIRE_RATE := 25     ## 射速 +10% 的初始价
const SHOP_PRICE_DAMAGE := 40        ## 子弹伤害 +1 的初始价
const SHOP_PRICE_GROWTH := 0.5       ## 每买一次涨价 = 初始价的 50%

## 本局各商品已买次数 key -> int 
var shop_buy_count: Dictionary = {}


## 当前价格 = 初始价 + 初始价的一半 * 已买次数
func shop_price(key: String) -> int:
	var base := 0
	match key:
		"health":
			base = SHOP_PRICE_HEALTH
		"fire_rate":
			base = SHOP_PRICE_FIRE_RATE
		"damage":
			base = SHOP_PRICE_DAMAGE
		_:
			return 0
	var bought: int = int(shop_buy_count.get(key, 0))
	return base + int(float(base) * SHOP_PRICE_GROWTH) * bought


## 买一件：钱不够返回 false（不扣钱也不加属性）
func shop_buy(key: String) -> bool:
	if not SHOP_KEYS.has(key):
		return false
	if not try_spend_gold(shop_price(key)):
		return false
	match key:
		"health":
			buy_max_health()
		"fire_rate":
			buy_fire_rate()
		"damage":
			buy_damage()
	shop_buy_count[key] = int(shop_buy_count.get(key, 0)) + 1
	return true


## 该商品已升了几级（商店显示用）
func shop_level(key: String) -> int:
	match key:
		"health":
			return maxi(max_health - BASE_MAX_HEALTH, 0)
		"fire_rate":
			return fire_rate_level
		"damage":
			return maxi(player_damage - 1, 0)
	return 0


func finish_run(did_clear: bool) -> void:
	cleared = did_clear
	is_active = false
	run_finished.emit(did_clear)
