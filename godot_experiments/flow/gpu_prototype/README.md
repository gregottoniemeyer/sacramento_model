# GPUParticles2D flow prototype

This isolated Godot 4.7 prototype runs two native 1920 x 1080 stage viewports
side by side. Each stage owns a head `GPUParticles2D` node with 300 allocated
flow-line slots and a child `GPUParticles2D` pool with 22,500 immutable segment
slots. `amount_ratio = 0.5` produces exactly 150 moving heads for the default
half-flow state. Simulation is render-paced under the project's 30 FPS cap,
with interpolation and 4x 2D MSAA. Heads emit stationary path segments that
fade for two seconds; native
particle trails are disabled. Press `G` to toggle both reservoir gates, `[` or
`]` to narrow or widen them, and Space to pause. Gate width changes both the
outlet geometry and retained-particle release probability. Probability is the
opening width divided by reservoir diameter: zero width releases none and a
diameter-wide opening commits every retained head to leave. Once selected, a
head begins travelling outward immediately rather than waiting for its trail
lifetime. The prototype gate control clamps at the reservoir radius, so its
widest setting is exactly the `1.0` hard drain.

This feasibility scene intentionally remains a single head/segment pool per
stage. The production `gpu_stage` wrapper uses the same shader's default-safe
global-identity controls to divide the palette into seven absolute Z layers,
which gives differently colored overlaps a stable stacking order. The
prototype's defaults (`stride = 1`, `offset = 0`, forced palette off) preserve
its original single-pool appearance and behavior.

## Required renderer

The project selects Mobile rendering. Godot 4.7 does not support the GPU
particle subemitters used here on the Compatibility renderer. Launch the
prototype with Mobile (or Forward+) explicitly:

```sh
/Applications/Godot.app/Contents/MacOS/Godot \
  --path . \
  --rendering-method mobile \
  --scene res://flow/gpu_prototype/gpu_flow_prototype.tscn
```

The smoke check is:

```sh
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless \
  --path . \
  --rendering-method mobile \
  --scene res://flow/gpu_prototype/gpu_flow_prototype.tscn \
  -- --gpu-flow-smoke
```

Headless mode validates GDScript, scene/resource wiring, head and segment-pool
counts, disabled native trails, render-paced timing, interpolation, segment-fade
settings, shader loading, and the default-safe empty 128 x 1 interaction-texture
binding with an interaction count of zero. It cannot provide meaningful GPU
frame timing or visual validation because Godot uses a dummy headless renderer
on this Mac.

## Immutable trail renderer

The particle-process shader completes all ordinary flow, wave, reservoir, gate,
interaction-polygon, and final position corrections before emitting a child
segment between its previous and current completed positions. The CanvasItem
draw shader is rendering-only: it applies width, color, antialiasing, and alpha
fade to those completed transforms. It never samples the interaction geometry
texture. The child segment stays where it was emitted and only ages and fades;
it never runs the head physics. Thus the visible tail is immutable history.
Later wave motion, reservoir forces, polygon interactions, or runtime parameter
changes can alter future head positions but cannot move, reconnect, or
disconnect existing tail segments.

Native trails are disabled on both particle systems. The required child pool is
calculated per stage as:

```text
ceil(particle_slots * 30 updates/second * trail_lifetime * 1.25)
```

The default is `ceil(300 * 30 * 2.0 * 1.25)`, or 22,500 segment slots. Each
segment fades over two seconds. A completed movement step longer than 96 pixels
emits no segment, creating a hard visible discontinuity gap rather than a long
line between unrelated positions.

Head positions are prewarmed before the scene is shown, but both reservoir
admission and segment recording remain disabled during that prewarm. Heads
which pass the reservoir during prewarm are permanently classified as bypasses,
so admission cannot retroactively fill the reservoir on the first visible
frame. The river therefore opens already distributed across the screen while
the reservoir opens empty. Holding segment recording avoids filling the child
pool with disconnected startup samples; visible tails grow to their full
two-second length immediately after launch.

## What the prototype proves

- Two independent stage simulations can coexist in one process: 600 allocated
  head slots, 300 active heads at the default half-flow state, and 45,000
  immutable segment slots. At the defaults, about 18,000 segments are live in
  steady state before the 25% capacity margin.
- The motion shader retains its own state between fixed steps and accepts a live `gate_open` uniform.
- Per-particle 1–5 px core width uses a one-pixel alpha feather and 4x MSAA to keep curves smooth; a solid nearest-filtered segment envelope avoids longitudinal seams while the shader handles width antialiasing. Palette color, velocity variation, and stable noise remain inexpensive.
- The circular reservoir can circulate/retain particles and gradually release them through a uniform-controlled gate.
- The shared particle-process shader can consume the production stage's bounded
  interaction texture: up to eight absorb/repel polygons with 12 vertices each,
  packed into a 128 x 1 `RGBAF` image. The prototype intentionally binds the
  empty form of that texture, while `gpu_stage` supplies and controls real
  polygon records.

## Deliberate limits

- **Fixed interaction budget:** the production geometry texture supports at
  most eight polygons and 12 vertices per polygon. Larger or unbounded geometry
  sets would still need a larger data representation, tiled field/SDF, or a
  lower-level compute solver. The two-up prototype is not a controller host and
  deliberately leaves its interaction count at zero.
- **Exact retained reservoir release:** `CUSTOM.w` retains one bit per particle, but particle shaders have no shared queue, atomic retained count, eviction order, or CPU-readable state. This cannot exactly reproduce the current bounded FIFO retention pool, oldest eviction, statistics, or trail-buffer transfer.
- **Particle separation:** invocations cannot read neighboring particle state. Use a precomputed density/force texture, remove separation, or move to a lower-level compute-buffer solver.
- **Variable line style:** color and width vary per path; all immutable segments
  still share one texture and CanvasItem material. Exact per-line cap, join,
  dash, and arbitrary style changes would require grouping into several
  particle systems or a custom renderer.
- **Two physical screens:** the scene already renders two independent native-resolution SubViewports. A 3840 x 1080 spanning window maps them 1:1. Separate OS windows need two `Window` nodes (or two processes), and target-hardware testing is still required for fill rate, display sync, and window-placement behavior.

This is a feasibility probe, not a drop-in replacement for `FlowModel2D` or the UDP control/schema layer.
