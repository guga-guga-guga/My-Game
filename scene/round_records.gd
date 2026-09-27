extends RefCounted
class_name RoundRecords

## 单局战绩读写工具：只提供“读全部”和“追加一条”，供开始界面和主场景共用。
## 存档是纯文本 JSON，位置在 user://round_records.json。
## Windows 下实际路径：%APPDATA%\Godot\app_userdata\唯时代尔\round_records.json

const SAVE_PATH := "user://round_records.json"
#最多保留多少局战绩
const MAX_RECORDS := 10


## 读取全部战绩，返回 { "total_rounds": int, "records": Array }。
## 文件不存在、读不了、格式不对时统一返回空记录，保证调用方不用做异常分支。
static func load_data() -> Dictionary:
	var empty_data := {"total_rounds": 0, "records": []}
	
	if not FileAccess.file_exists(SAVE_PATH):
		return empty_data
	
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		push_warning("RoundRecords: 打不开存档 %s" % SAVE_PATH)
		return empty_data
	
	var text := file.get_as_text()
	file.close()
	
	if text.strip_edges().is_empty():
		return empty_data
	
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("RoundRecords: 存档格式异常，已忽略 %s" % SAVE_PATH)
		return empty_data
	
	#做基本校验：旧档或被手改过的档不能让游戏崩掉
	var parsed_data: Dictionary = parsed
	if not parsed_data.has("total_rounds"):
		return empty_data
	if typeof(parsed_data.get("records")) != TYPE_ARRAY:
		return empty_data
	
	return parsed_data


## 追加一条战绩。elapsed 是存活秒数，kills 是击杀数，won 表示是否撑满全场。
## 新记录插到最前面，超出 MAX_RECORDS 的从末尾丢掉。
static func add_record(elapsed: float, kills: int, won: bool) -> void:
	var data := load_data()
	var next_index := int(data.get("total_rounds", 0)) + 1
	var records: Array = data.get("records", [])
	
	records.insert(0, {
		"index": next_index,
		"elapsed": snappedf(maxf(elapsed, 0.0), 0.1),
		"kills": maxi(kills, 0),
		"won": won,
	})
	while records.size() > MAX_RECORDS:
		records.pop_back()
	
	data["total_rounds"] = next_index
	data["records"] = records
	_save(data)


static func _save(data: Dictionary) -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("RoundRecords: 写不进存档 %s" % SAVE_PATH)
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
