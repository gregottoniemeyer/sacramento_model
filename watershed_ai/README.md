# Water Council seasonal Watershed optimizer

This is a one-call OpenAI Agents SDK subsystem for the installation's exclusive
Watershed regime. It reads the current point in the 720-sample July 2025–June
2026 atmospheric-input year and proposes relative priorities for:

- salmon;
- connected floodplain water;
- agriculture;
- data centers;
- cities.

Deterministic local code—not the model—turns those priorities into a complete
water budget, enforces ecological and seasonal floors, closes the sum to 100%,
sets a smooth supply-dependent extraction target between 5% and 50%, keeps
hydropower and water-project extraction at zero, hashes the state, and sends
one screen-specific state to each of the seven Godot screens.

This is a speculative art model, not a biological, legal, agricultural,
municipal, tribal, cultural, flood-control, or water-operations system.

## Seasonal behavior

- Winter weights data-center activity upward while retaining salmon and wet
  floodplain floors.
- Spring stores conceptual surplus in an internal reservoir carryover signal.
- Summer releases that carryover and weights food production upward, while a
  data-center floor and the dynamically protected salmon share remain.
- Scarcity and heat increase the salmon floor. Missing temperature never
  invents thermal stress.
- Greater available supply permits greater sustainable extraction; scarce
  supply approaches the 5% minimum and extraction can never exceed 50%.
- Within each screen's extraction budget, cooler water favors data centers and
  warmer water favors agriculture/fields. Each screen uses its own input,
  release, storage, temperature, quality flags, and AI priorities.
- Hydropower and water-project extraction are fixed at `0.0` in this scenario.

The instantaneous accounting is:

```text
available supply = min(atmospheric input + reservoir release, 1)
extraction = agriculture + data centers + city
remaining river water = available supply × (1 − extraction)
salmon + floodplain + extraction = 1
```

Reservoir release is an internal time shift, not a second source of annual
water. Atmospheric input remains precipitation + delayed snowmelt +
humidity/dew + the morning fog baseline.

## OpenAI call and cost

The runtime uses one tool-free structured-output agent turn with
`gpt-5.6-luna`, `reasoning.effort="none"`, low verbosity, and a 1,600-token
output ceiling. The existing ignored `OPENAI_API_KEY` is loaded from the
repository root `.env.local`; the key is never printed or copied into a runlog.

Every new decision stores and prints:

- request count;
- input, cached-input, cache-write, output, and total tokens;
- an estimated USD cost using the pinned pricing snapshot;
- model, pricing date, and pricing source.

The August 23, 2026 GPT-5.6 Luna snapshot is $0.20/M uncached input tokens,
$0.02/M cached input tokens, and $1.20/M output tokens. Cache writes are
estimated at 1.25× the uncached input rate. See the
[official model page](https://developers.openai.com/api/docs/models/gpt-5.6-luna).
The Agents SDK exposes the measured run usage through
`result.context_wrapper.usage`; see the
[official usage guide](https://openai.github.io/openai-agents-python/usage/).

A saved-decision replay makes no API call and reports `$0.000000` for the replay;
the saved JSON retains the original generation cost for provenance.

## Runtime contract

Godot accepts only the `watershed-ai/2` control scope, only while Watershed is
the sole active regime (`active_indices == [6]`). Packets cannot contain actions,
geometry operations, wildcard targets, missing fields, extra fields, non-finite
numbers, unclosed budgets, or nonzero hydropower/water-project allocation.

Watershed is also exclusive at the live Godot state and fleet-controller
boundaries. If Watershed is selected with other chairs or regimes, every other
regime is cleared: optimize or bust. The fleet controller does not save or
replay that regime state.

The state drives:

- atmospheric input and post-extraction particle coverage;
- spring storage and summer reservoir release;
- explicit tan-hatched field rectangles;
- explicit white-hatched data-center rectangles;
- city repeller geometry;
- a Delta floodplain whose area follows its allocation.

No API output can address real infrastructure or issue general controller
commands.

## Install and test

From the repository root:

```sh
python3 -m venv watershed_ai/.venv
watershed_ai/.venv/bin/python -m pip install -e watershed_ai
watershed_ai/.venv/bin/python -m unittest discover -s watershed_ai/tests -v
watershed_ai/.venv/bin/python watershed_ai/evals/run_local.py
```

Generate a dry-run decision at a specific sample:

```sh
watershed_ai/.venv/bin/watercouncil-ai --project-root . --frame 420
```

Use the fleet's acknowledged current model phase and apply once:

```sh
watershed_ai/.venv/bin/watercouncil-ai --project-root . --current --live
```

Replay without spending another call:

```sh
watershed_ai/.venv/bin/watercouncil-ai \
  --project-root . \
  --decision watershed_ai/runlogs/latest-decision.json \
  --live
```

The fleet controller invokes the current-phase command once on a fresh
exclusive Watershed transition. Repeating Watershed does not call the model;
startup/restart replays `latest-decision.json` without a new call.
