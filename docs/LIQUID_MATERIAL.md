# Liquid material

The liquid material is built into the production design components. An
earlier prototype was an isolated demo; none of its GPU numbers count as
evidence for a device.

`HermesLiquid` owns the roles `header`, `dock`, `pill`, `overlay`, `notice`.
`HermesGlassStrip` owns rendering and filter allocation. `HermesLiquidSurface`
adapts one shape; `FrostedBackdrop(liquid: ...)` adapts its existing public API.
Existing callers that do not request liquid retain their glass contract.
There is no per-screen shader or second activity-state owner.

```dart
HermesGlassStrip(
  zone: FrostedZone.bottom,
  liquid: HermesLiquid.dock,
  child: Row(children: [/* HermesGlassPiece shapes */]),
)

HermesLiquidSurface(
  liquid: HermesLiquid.overlay,
  zone: FrostedZone.overlay,
  maxFilterArea: HermesLiquid.overlayFilterArea,
  shape: HermesFloatingSurface.rounded(),
  builder: (context, fill) => Material(color: fill, child: content),
)
```

A piece must use the inherited veil, keep its visible outline registered,
and avoid an extra repaint boundary between it and its band. Existing
`HermesFloatingSurface` and floating buttons do that for headers. A strip
has one retained filter layer for all shapes, sharing `top`, `bottom`, or
`overlay` with legacy glass. A strip of zone `none` is explicitly unshared.
Lists never create bands or filters in their item builders.

The default is existing glass plus an edge highlight on migrated surfaces.
Refraction, fusion and the adaptive fragment shader are wired to those same
surfaces but require `HERMES_LIQUID_GPU_VALIDATED=true`, a known high-end
platform report and engine support. That build switch is false until a
physical Fold measurement is accepted. It cannot override reduced motion,
high contrast, reduced transparency, battery saver, low RAM, disabled blur,
opaque dock preferences, or a zero-sigma surface. No shader is loaded for
these fallbacks. Shader loading starts only after eligible geometry paints.

During route push/pop and secondary transitions the band keeps its regular
veil. Wrap other moving ancestors (dock dismissal, modal drag) in
`HermesLiquidMotion(moving: ..., child: ...)`. Each scope depends on its
parent's effective veto and combines it with its local flag. A nested locally
still scope cannot clear a moving ancestor. Static rotation, scaling,
unsupported shapes, or more than five pieces fall back for the entire band;
the renderer restores the veil under every piece. Large modal frames use
opaque backing and a painted rim without a filter. Rounded rectangles retain
their actual corner radius in the shader; they are not approximated as pills.

The adaptive veil protects primary ink and the title badge's weaker ink at
4.5:1 over extreme backdrops. Highlight is restricted to the edge and the
shader suppresses a highlight that would break the modeled contrast.
Explicitly colored overlay text continues to use the existing `windowInk`
contract. No new fill, gradient or filter is added to individual list rows.

Physical GPU performance, first-use latency, GLES coordinates and thermal
behavior have **not been measured yet** on a physical Fold. Until they are,
`HERMES_LIQUID_GPU_VALIDATED` stays false and the default above applies.
