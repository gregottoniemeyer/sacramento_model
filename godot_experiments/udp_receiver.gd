extends Node
## UDPReceiver — Sacramento Model
## Receives state packets from controller.py and drives speed_controlled nodes.

@export var udp_port: int = 5005
@export var speed_step_px: float = 20.0

var _server: UDPServer
var _peer: PacketPeerUDP


func _ready() -> void:
	_server = UDPServer.new()
	var err := _server.listen(udp_port, "127.0.0.1")
	if err == OK:
		print("UDPReceiver: listening on port ", udp_port)
	else:
		push_error("UDPReceiver: failed to listen on port %d (error %d)" % [udp_port, err])


func _process(_delta: float) -> void:
	if not _server:
		return

	# Poll for new connections
	_server.poll()

	# Accept new peer if one connected
	if _server.is_connection_available():
		_peer = _server.take_connection()
		print("UDPReceiver: connected to ", _peer.get_packet_ip())

	# Read all available packets, keep only the latest
	if _peer and _peer.get_available_packet_count() > 0:
		var latest: Dictionary = {}
		while _peer.get_available_packet_count() > 0:
			var raw := _peer.get_packet()
			var text := raw.get_string_from_utf8()
			var parsed = JSON.parse_string(text)
			if parsed is Dictionary:
				latest = parsed

		if not latest.is_empty():
			_apply_state(latest)


func _apply_state(state: Dictionary) -> void:
	print("UDP received: ", state.get("regime_name", "?"), " speed:", state.get("speed", "?"))
	var speed_int: int = clampi(int(state.get("speed", 5)), 0, 9)
	var speed_px: float = speed_int * speed_step_px

	for node in get_tree().get_nodes_in_group("speed_controlled"):
		if node.has_method("set_target_speed"):
			node.set_target_speed(speed_px)


func _exit_tree() -> void:
	if _peer:
		_peer.close()
	if _server:
		_server.stop()
