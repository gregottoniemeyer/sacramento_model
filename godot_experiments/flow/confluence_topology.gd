class_name ConfluenceTopology
extends RefCounted

## Fixed installation topology for the Water Council particle confluence.
##
## Packet payloads identify stages symbolically.  Pixel coordinates and host
## ownership stay local so a malformed or stale network packet cannot move an
## inlet or route a stage through an arbitrary machine.

const PROTOCOL := "water-council-confluence/1"
const ACK_PROTOCOL := "water-council-confluence/1-ack"
const UDP_PORT := 5007
const BIND_ADDRESS := "0.0.0.0"

const DELTA_SCREEN := "delta"
const DELTA_HOST := "196.168.50.11"

const SCREEN_HOSTS := {
	"mount_shasta": "196.168.50.21",
	"mccloud_pit": "196.168.50.21",
	"cottonwood_creek": "196.168.50.31",
	"mill_creek": "196.168.50.31",
	"feather_river": "196.168.50.41",
	"american_river": "196.168.50.41",
	DELTA_SCREEN: DELTA_HOST,
}

const HOST_SCREENS := {
	"196.168.50.11": [DELTA_SCREEN],
	"196.168.50.21": ["mount_shasta", "mccloud_pit"],
	"196.168.50.31": ["cottonwood_creek", "mill_creek"],
	"196.168.50.41": ["feather_river", "american_river"],
}

const UPSTREAM_SCREENS: Array[String] = [
	"mount_shasta",
	"mccloud_pit",
	"cottonwood_creek",
	"mill_creek",
	"feather_river",
	"american_river",
]

## Grid-line numbers are one-based. The renderer resolves them against its
## current grid spacing; network packets never carry mutable inlet positions.
const DELTA_INLETS := {
	"mill_creek": {"edge": "bottom", "gridline": 3},
	"cottonwood_creek": {"edge": "bottom", "gridline": 10},
	"mount_shasta": {"edge": "left", "gridline": 8},
	"mccloud_pit": {"edge": "left", "gridline": 2},
	"feather_river": {"edge": "top", "gridline": 5},
	"american_river": {"edge": "top", "gridline": 12},
}


static func is_known_screen(screen_id: String) -> bool:
	return SCREEN_HOSTS.has(screen_id)


static func is_upstream_screen(screen_id: String) -> bool:
	return screen_id in UPSTREAM_SCREENS


static func host_for_screen(screen_id: String) -> String:
	return String(SCREEN_HOSTS.get(screen_id, ""))


static func screens_for_host(host: String) -> Array[String]:
	var result: Array[String] = []
	var values: Variant = HOST_SCREENS.get(host, [])
	if values is Array:
		for value: Variant in values:
			result.append(String(value))
	return result


static func inlet_for_screen(screen_id: String) -> Dictionary:
	var inlet: Variant = DELTA_INLETS.get(screen_id, {})
	return Dictionary(inlet).duplicate(true) if inlet is Dictionary else {}


static func is_local_sender(sender_ip: String) -> bool:
	return sender_ip in ["local", "127.0.0.1", "::1"]


static func sender_owns_screen(sender_ip: String, screen_id: String) -> bool:
	if not is_known_screen(screen_id):
		return false
	return is_local_sender(sender_ip) or host_for_screen(screen_id) == sender_ip


static func valid_water_route(
	source_screen: String,
	target_screen: String,
) -> bool:
	return is_upstream_screen(source_screen) and target_screen == DELTA_SCREEN


static func valid_particle_route(
	source_screen: String,
	particle_type: String,
	target_screens: Array[String],
) -> bool:
	if target_screens.is_empty():
		return false
	var normalized_type := particle_type.strip_edges().to_lower()
	if normalized_type in ["leaf", "pollution"]:
		return (
			is_upstream_screen(source_screen)
			and target_screens == [DELTA_SCREEN]
		)
	if normalized_type == "salmon":
		return (
			source_screen == DELTA_SCREEN
			and target_screens.size() == 1
			and is_upstream_screen(target_screens[0])
		)
	return false


static func targets_belong_to_one_host(target_screens: Array[String]) -> bool:
	if target_screens.is_empty():
		return false
	var expected_host := host_for_screen(target_screens[0])
	if expected_host.is_empty():
		return false
	for target_screen: String in target_screens:
		if host_for_screen(target_screen) != expected_host:
			return false
	return true
