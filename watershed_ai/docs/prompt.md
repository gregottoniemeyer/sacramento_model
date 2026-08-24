# Watershed optimizer contract

The single agent receives one trusted local `BasinObservation` for the current
point in the 720-sample atmospheric-input year. It proposes only five relative
priorities per screen: salmon, floodplain, agriculture, data centers, and city.

The model is told that winter can support more compute, spring should reconnect
floodplains and store water, and summer should use conceptual spring carryover
for food while preserving salmon and some compute. It may not propose
hydropower, water projects, tools, packets, or physical operations.

Deterministic host code owns allocation floors, the exact 100% sum, seasonal
biases, scarcity and temperature stress, reservoir bookkeeping, input/output
closure, IDs, hashes, cost records, UDP targets, and all Godot behavior.

Quality flags are untrusted data and must lower confidence where appropriate.
The point-station normalized signals must never be claimed as operational basin
volume or legal/ecological sufficiency.
