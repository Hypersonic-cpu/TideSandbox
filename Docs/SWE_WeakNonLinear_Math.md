# Weakly Nonlinear Shallow Water Equation: Mathematics and Simulation

## 1. Purpose and model scope

This document specifies a simple **weakly nonlinear shallow-water solver** intended for real-time sandbox water, shallow pools, terrain-driven flow, and an initial city-tide prototype.

The model retains the nonlinear mass flux $h\mathbf{u}$, so water can move between regions with different depths. It simplifies the momentum equation by omitting the nonlinear advection term $(\mathbf{u}\cdot\nabla)\mathbf{u}$. The resulting solver is substantially easier to implement than the full conservative shallow-water equations while preserving the most important behavior:

- water flows down the free-surface gradient;
- water volume is updated conservatively through face fluxes;
- waves propagate with characteristic speed approximately $\sqrt{gh}$;
- terrain enters through the free-surface elevation;
- damping, obstacles, interaction impulses, and simple wet/dry handling can be added directly.

This model is an intermediate step toward a finite-volume conservative SWE solver.

---

## 2. Variables and notation

The horizontal coordinates are $x$ and $y$, and time is $t$.

| Symbol | Meaning | Typical unit | Recommended code name |
|---|---|---:|---|
| $z_b(x,y)$ | Bed or terrain elevation | m | `bedElevation` |
| $\eta(x,y,t)$ | Free-surface elevation | m | `surfaceElevation` |
| $h(x,y,t)$ | Water depth | m | `waterDepth` |
| $u(x,y,t)$ | Depth-averaged velocity in the $x$ direction | m/s | `velX` |
| $v(x,y,t)$ | Depth-averaged velocity in the $y$ direction | m/s | `velY` |
| $\mathbf{u}=(u,v)$ | Horizontal depth-averaged velocity | m/s | `velocity` |
| $g$ | Gravitational acceleration | m/s² | `gravity` |
| $\gamma$ | Linear velocity damping coefficient | 1/s | `linearDamping` |
| $\nu$ | Optional horizontal viscosity | m²/s | `viscosity` |
| $q_x$ | Water-volume flux per unit width in the $x$ direction | m²/s | `fluxX` |
| $q_y$ | Water-volume flux per unit width in the $y$ direction | m²/s | `fluxY` |

The geometric relation is $h=\eta-z_b$, or equivalently $\eta=h+z_b$.

Water depth must satisfy $h\ge 0$.

### 2.1 Clarification of the common notation `hu` and `hv`

In shallow-water literature, $hu$ and $hv$ are widely used. They mean the products $h\,u$ and $h\,v$. In the full conservative SWE, these products are often treated as stored momentum variables.

Similarly, the expression $hu^2$ means $h\,u^2$, whereas $(hu)^2$ means $h^2u^2$. The first notation is standard but can be visually ambiguous in implementation documents.

This document therefore uses:

- $h,u,v$ as the primary state variables;
- $q_x=h\,u$ and $q_y=h\,v$ as water-volume fluxes;
- explicit multiplication in code, such as `waterDepth * velX`.

For the current weakly nonlinear solver, $q_x$ and $q_y$ are computed fluxes rather than independent state variables. In the future full conservative solver, they may become stored variables.

---

## 3. Modeling assumptions

The shallow-water approximation assumes that the typical water depth $H$ is much smaller than the horizontal length scale $L$, so $H/L\ll 1$.

The vertical pressure distribution is assumed hydrostatic. The velocity variables $u$ and $v$ are depth-averaged horizontal velocities.

For the weakly nonlinear model, the mass equation remains nonlinear, but the momentum advection term is neglected. In particular, the full term $(\mathbf{u}\cdot\nabla)\mathbf{u}$ is omitted.

The model is most appropriate when:

- the free surface remains single-valued;
- vertical acceleration is small;
- splashing, breaking waves, and overturning are unimportant;
- horizontal velocities are moderate;
- strongly supercritical flow and hydraulic jumps are not the primary target.

---

## 4. Governing equations

### 4.1 Mass conservation

The water-depth equation is

$$
\frac{\partial h}{\partial t}+\nabla\cdot(h\mathbf{u})=0.
$$

In two-dimensional component form,

$$
\frac{\partial h}{\partial t}
+\frac{\partial (h u)}{\partial x}
+\frac{\partial (h v)}{\partial y}
=0.
$$

Using $q_x=h\,u$ and $q_y=h\,v$, this becomes

$$
\frac{\partial h}{\partial t}
+\frac{\partial q_x}{\partial x}
+\frac{\partial q_y}{\partial y}
=0.
$$

This equation is conservative: the water depth in a cell changes only because water crosses its boundaries.

### 4.2 Weakly nonlinear momentum equation

The simplified momentum equation is

$$
\frac{\partial \mathbf{u}}{\partial t}
=-g\nabla\eta-\gamma\mathbf{u}+\nu\nabla^2\mathbf{u}+\mathbf{f}_{\mathrm{ext}}.
$$

Because $\eta=h+z_b$, the gravitational term can also be written as $-g\nabla(h+z_b)$.

In component form,

$$
\frac{\partial u}{\partial t}
=-g\frac{\partial \eta}{\partial x}
-\gamma u
+\nu\nabla^2u
+f_x,
$$

$$
\frac{\partial v}{\partial t}
=-g\frac{\partial \eta}{\partial y}
-\gamma v
+\nu\nabla^2v
+f_y.
$$

The terms have the following meanings:

- $-g\nabla\eta$ accelerates water down the free-surface slope;
- $-\gamma\mathbf{u}$ removes energy gradually and suppresses endless oscillation;
- $\nu\nabla^2\mathbf{u}$ is optional smoothing or horizontal viscosity;
- $\mathbf{f}_{\mathrm{ext}}$ represents user interaction, wind-like forcing, pumps, or scripted effects.

The minimal recommended model sets $\nu=0$ initially and uses a small positive $\gamma$.

### 4.3 Complete weakly nonlinear system

The recommended initial solver is therefore

$$
\frac{\partial h}{\partial t}
+\nabla\cdot(h\mathbf{u})=0,
$$

$$
\frac{\partial \mathbf{u}}{\partial t}
=-g\nabla(h+z_b)-\gamma\mathbf{u}.
$$

The state variables are $h,u,v$. The terrain $z_b$ is fixed input data, and $\eta=h+z_b$ is derived each step.

---

## 5. Relation to the linearized shallow-water equations

Suppose the bed is flat and the water depth is close to a constant reference depth $H$. Write $h=H+\zeta$, where $|\zeta|\ll H$, and assume the velocity is small.

Then $h\mathbf{u}\approx H\mathbf{u}$, giving

$$
\frac{\partial \zeta}{\partial t}
+H\nabla\cdot\mathbf{u}=0,
$$

$$
\frac{\partial \mathbf{u}}{\partial t}
=-g\nabla\zeta-\gamma\mathbf{u}.
$$

Without damping, eliminating $\mathbf{u}$ gives

$$
\frac{\partial^2\zeta}{\partial t^2}
=gH\nabla^2\zeta.
$$

The small-amplitude wave speed is $c=\sqrt{gH}$.

The weakly nonlinear model differs by retaining the actual local depth inside the mass flux: $h\mathbf{u}$ instead of $H\mathbf{u}$. This allows water transport to depend on the current depth and makes terrain-driven redistribution more realistic.

---

## 6. Recommended numerical layout

A **staggered MAC-style grid** is recommended.

Store:

- $h_{i,j}$, $z_{b,i,j}$, and $\eta_{i,j}$ at cell centers;
- $u_{i+\frac12,j}$ on vertical cell faces;
- $v_{i,j+\frac12}$ on horizontal cell faces;
- $q_{x,i+\frac12,j}$ and $q_{y,i,j+\frac12}$ on the same faces as their velocities.

This arrangement has several advantages:

- pressure gradients naturally update face velocities;
- face velocities naturally define cell-boundary fluxes;
- discrete divergence and gradient operators align;
- checkerboard pressure modes are less likely;
- solid-wall boundary conditions are straightforward.

A collocated grid can work, but it generally requires more stabilization and is not recommended for the first implementation.

---

## 7. Recommended time integration

Use an explicit **symplectic Euler** or kick-drift order:

1. compute the free surface $\eta^n=h^n+z_b$;
2. update face velocities from the free-surface gradient;
3. compute water-volume fluxes using the updated velocities;
4. update cell-centered water depth from flux divergence;
5. apply wet/dry cleanup and boundary conditions.

Updating velocity before depth is usually more stable for wave-like systems than updating both from the same old state.

---

## 8. Spatial discretization

Let the grid spacings be $\Delta x$ and $\Delta y$, and the time step be $\Delta t$.

### 8.1 Free-surface elevation

At each cell center,

$$
\eta_{i,j}=h_{i,j}+z_{b,i,j}.
$$

### 8.2 Velocity update

For an $x$-face between cells $(i,j)$ and $(i+1,j)$,

$$
u_{i+\frac12,j}^{*}
=
u_{i+\frac12,j}^{n}
-g\Delta t
\frac{\eta_{i+1,j}^{n}-\eta_{i,j}^{n}}{\Delta x}.
$$

For a $y$-face between cells $(i,j)$ and $(i,j+1)$,

$$
v_{i,j+\frac12}^{*}
=
v_{i,j+\frac12}^{n}
-g\Delta t
\frac{\eta_{i,j+1}^{n}-\eta_{i,j}^{n}}{\Delta y}.
$$

Apply linear damping using the exact decay factor

$$
u^{n+1}=e^{-\gamma\Delta t}u^{*},
\qquad
v^{n+1}=e^{-\gamma\Delta t}v^{*}.
$$

The exact exponential factor is preferable to $1-\gamma\Delta t$ because it remains nonnegative and stable for larger $\gamma\Delta t$.

If viscosity is enabled, add a separate diffusion step. For the first version, use $\nu=0$.

### 8.3 Face water depth

The flux requires a face depth. A robust first-order choice is upwinding.

For the $x$-face,

$$
h_{i+\frac12,j}^{\mathrm{up}}
=
\begin{cases}
h_{i,j}, & u_{i+\frac12,j}^{n+1}\ge 0,\\
h_{i+1,j}, & u_{i+\frac12,j}^{n+1}<0.
\end{cases}
$$

For the $y$-face,

$$
h_{i,j+\frac12}^{\mathrm{up}}
=
\begin{cases}
h_{i,j}, & v_{i,j+\frac12}^{n+1}\ge 0,\\
h_{i,j+1}, & v_{i,j+\frac12}^{n+1}<0.
\end{cases}
$$

Upwinding introduces some numerical diffusion, but it is stable, simple, and naturally respects flow direction. A centered average such as $(h_L+h_R)/2$ produces sharper waves but is more prone to oscillation and negative depths.

### 8.4 Face fluxes

The water-volume fluxes per unit width are

$$
q_{x,i+\frac12,j}
=
h_{i+\frac12,j}^{\mathrm{up}}
u_{i+\frac12,j}^{n+1},
$$

$$
q_{y,i,j+\frac12}
=
h_{i,j+\frac12}^{\mathrm{up}}
v_{i,j+\frac12}^{n+1}.
$$

Again, $q_x$ and $q_y$ are products, not additional physical fields with independent evolution equations.

### 8.5 Conservative depth update

Update the water depth using flux differences:

$$
h_{i,j}^{n+1}
=
h_{i,j}^{n}
-\frac{\Delta t}{\Delta x}
\left(
q_{x,i+\frac12,j}
-q_{x,i-\frac12,j}
\right)
-\frac{\Delta t}{\Delta y}
\left(
q_{y,i,j+\frac12}
-q_{y,i,j-\frac12}
\right).
$$

If all interior face fluxes are shared consistently by adjacent cells, this update conserves total water volume up to boundary fluxes and floating-point error.

---

## 9. Positivity and wet/dry handling

A naive depth update can produce a small negative $h$ if a cell exports more water than it contains.

### 9.1 Minimal prototype handling

For an initial decorative prototype, use a small threshold $h_{\min}$:

- if $h<h_{\min}$, set $h=0$;
- set all adjacent face velocities that would draw water from the dry cell to zero;
- set momentum-like diagnostic values to zero in dry regions.

A final clamp such as $h\leftarrow\max(h,0)$ is acceptable as a safety net, but frequent clamping indicates that the time step or flux treatment is inadequate.

### 9.2 Recommended outgoing-flux limiter

For each cell, estimate the depth that would leave during the step:

$$
\Delta h_{\mathrm{out}}
=
\frac{\Delta t}{\Delta x}
\left[
\max(q_{x,i+\frac12,j},0)
+
\max(-q_{x,i-\frac12,j},0)
\right]
+
\frac{\Delta t}{\Delta y}
\left[
\max(q_{y,i,j+\frac12},0)
+
\max(-q_{y,i,j-\frac12},0)
\right].
$$

Define

$$
\theta_{i,j}
=
\min\left(
1,
\frac{h_{i,j}^{n}}{\Delta h_{\mathrm{out}}+\varepsilon}
\right).
$$

Multiply every flux leaving cell $(i,j)$ by $\theta_{i,j}$. This prevents the cell from exporting more water than it owns while preserving a conservative face-flux update.

For a shared face, use the limiter of the donor cell because the donor is the cell from which the upwind flux originates.

---

## 10. Stability and time-step selection

The local gravity-wave speed is approximately $c=\sqrt{gh}$.

A practical two-dimensional CFL restriction is

$$
\Delta t
\le
C_{\mathrm{CFL}}
\left[
\frac{\max(|u|+\sqrt{gh})}{\Delta x}
+
\frac{\max(|v|+\sqrt{gh})}{\Delta y}
\right]^{-1}.
$$

Use $C_{\mathrm{CFL}}$ between $0.2$ and $0.5$ initially. A value near $0.3$ is a conservative starting point.

For a fixed rendering frame time, divide each frame into multiple physics substeps whenever the CFL condition requires a smaller $\Delta t$.

Also enforce reasonable safety bounds on:

- maximum water depth;
- maximum face speed;
- maximum number of substeps per frame;
- minimum wet depth $h_{\min}$.

Velocity clipping should be a debugging safety mechanism rather than the primary stability method.

---

## 11. Boundary conditions

### 11.1 Reflective solid wall

For a wall, set the normal velocity to zero:

- at a vertical wall, set $u=0$ on the wall face;
- at a horizontal wall, set $v=0$ on the wall face.

Tangential velocity may be preserved for free-slip behavior or damped for a more viscous-looking wall.

The normal water flux is then zero.

### 11.2 Periodic boundary

Copy state and face velocities across opposite boundaries. This is useful for testing mass conservation and wave propagation.

### 11.3 Open or tidal boundary

For a tide boundary, prescribe the surface elevation as a function of time, for example $\eta_{\mathrm{bc}}(t)=\eta_0+A\sin(\omega t+\phi)$.

Use the prescribed $\eta_{\mathrm{bc}}$ in the boundary pressure gradient. Extrapolate the normal velocity from the interior or apply a simple radiation condition later.

A fully robust open boundary is a separate numerical topic. The initial version should use slowly varying tidal forcing and avoid strong reflections by adding a sponge damping zone near the boundary.

### 11.4 Obstacles and terrain

A solid obstacle can be represented by marking blocked cells and forcing all normal face fluxes across the obstacle boundary to zero.

Terrain itself is represented continuously through $z_b$. A cell is dry whenever $\eta\le z_b+h_{\min}$.

---

## 12. Interaction and forcing

### 12.1 Adding water

Add a nonnegative source $R(x,y,t)$ to the mass equation:

$$
\frac{\partial h}{\partial t}
+\nabla\cdot(h\mathbf{u})
=R.
$$

In a discrete cell, use $h^{n+1}\leftarrow h^{n+1}+\Delta t\,R$.

This is appropriate for rain, a faucet, or a user adding water.

### 12.2 Removing water

Use a sink $I(x,y,t)\ge 0$:

$$
\frac{\partial h}{\partial t}
+\nabla\cdot(h\mathbf{u})
=R-I.
$$

Limit removal so that the cell depth cannot become negative.

### 12.3 Splash-like impulse without vertical simulation

The model has no explicit vertical velocity. A click or object interaction can instead modify the free surface and horizontal velocity:

- add a localized bump to $h$;
- add a radial impulse to nearby face velocities;
- apply equal positive and negative depth perturbations if total volume should remain unchanged.

A volume-neutral disturbance can use a narrow positive center and a broader negative ring whose discrete sum is zero.

---

## 13. Recommended simulation loop

```text
initialize waterDepth, bedElevation, velX, velY

for each rendered frame:
    remainingTime = frameDeltaTime

    while remainingTime > 0:
        compute stableDt from CFL
        dt = min(remainingTime, stableDt)

        # 1. Derived free surface
        surfaceElevation = waterDepth + bedElevation

        # 2. Pressure-gradient velocity update
        update velX on x-faces from surfaceElevation gradient
        update velY on y-faces from surfaceElevation gradient

        # 3. Damping and boundary velocities
        velX *= exp(-linearDamping * dt)
        velY *= exp(-linearDamping * dt)
        enforce solid-wall and obstacle boundary conditions

        # 4. Upwind face depths and volume fluxes
        fluxX = upwindDepthX * velX
        fluxY = upwindDepthY * velY

        # 5. Positivity limiter
        limit outgoing fluxes by donor-cell available water

        # 6. Conservative water-depth update
        waterDepth -= dt * divergence(fluxX, fluxY)

        # 7. Sources and dry-cell cleanup
        apply rain, drains, user interaction, or tide forcing
        clamp only tiny roundoff negatives
        zero inappropriate velocities around dry cells

        remainingTime -= dt
```

Use double buffering for $h$ if the implementation updates cells in parallel. Face fluxes should be computed once and reused by both neighboring cells to maintain conservation.

---

## 14. Initialization

For a desired initial free-surface level $\eta_0$, initialize

$$
h(x,y,0)=\max(\eta_0-z_b(x,y),0).
$$

Set $u=v=0$ unless an initial current is required.

This represents a level lake at rest. Because the velocity update uses $\nabla\eta$, a spatially constant $\eta$ produces zero acceleration even over uneven terrain. This is the main well-balanced advantage of updating from the free-surface gradient directly.

---

## 15. Diagnostics

Track at least the following quantities:

- total water volume $V=\sum_{i,j}h_{i,j}\Delta x\Delta y$;
- minimum water depth;
- maximum $|u|$ and $|v|$;
- maximum local wave speed $\sqrt{gh}$;
- selected CFL time step;
- amount of water added or removed through sources and boundaries;
- amount of correction introduced by negative-depth clamping.

For closed boundaries and no sources, total volume should remain nearly constant. A persistent volume drift usually indicates inconsistent face fluxes, incorrect boundary handling, or excessive post-update clamping.

A useful diagnostic energy density is

$$
E
=
\frac12 h(u^2+v^2)
+\frac12 gh^2
+ghz_b.
$$

The weakly nonlinear model does not exactly conserve the full nonlinear SWE energy, especially with damping and upwinding. The energy should nevertheless remain bounded and should decay when $\gamma>0$.

---

## 16. Suggested initial parameter strategy

Use consistent SI-like units whenever possible.

- Set $g=9.81$ for physical scale, or use a smaller effective value for slower decorative waves.
- Choose $\Delta x$ and $\Delta y$ according to the world-space size represented by one cell.
- Start with $C_{\mathrm{CFL}}=0.3$.
- Choose $\gamma$ so visible waves decay over the desired time scale. Since velocity decays as $e^{-\gamma t}$, a half-life $T_{1/2}$ corresponds to $\gamma=\ln 2/T_{1/2}$.
- Set $h_{\min}$ to a small fraction of the typical water depth.
- Begin without viscosity; introduce a small $\nu$ only if grid-scale velocity noise remains.

Avoid tuning parameters solely in grid units. Keeping a clear relationship between physical length, depth, gravity, and time makes later migration to the full SWE much easier.

---

## 17. Limitations of this weakly nonlinear model

The omitted acceleration term is

$$
(\mathbf{u}\cdot\nabla)\mathbf{u}
=
\left(
u\frac{\partial u}{\partial x}
+v\frac{\partial u}{\partial y},
\;
u\frac{\partial v}{\partial x}
+v\frac{\partial v}{\partial y}
\right).
$$

Without it, the model cannot accurately reproduce:

- strong momentum transport by the flow itself;
- hydraulic jumps and shock-like fronts;
- strongly supercritical flows;
- accurate dam-break dynamics;
- nonlinear wave steepening;
- high-speed flow around obstacles.

The model is still useful for moderate-speed terrain flow and interactive shallow-water visuals.

---

## 18. Upgrade path to the full conservative SWE

The future full solver should store the conservative state

$$
\mathbf{U}
=
\begin{bmatrix}
h\\
q_x\\
q_y
\end{bmatrix},
$$

where $q_x=h\,u$ and $q_y=h\,v$ are then stored momentum-like variables.

The full two-dimensional conservative SWE is

$$
\frac{\partial \mathbf{U}}{\partial t}
+
\frac{\partial \mathbf{F}(\mathbf{U})}{\partial x}
+
\frac{\partial \mathbf{G}(\mathbf{U})}{\partial y}
=
\mathbf{S}.
$$

Using $u=q_x/h$ and $v=q_y/h$, the fluxes are

$$
\mathbf{F}
=
\begin{bmatrix}
q_x\\
q_xu+\frac12gh^2\\
q_xv
\end{bmatrix},
\qquad
\mathbf{G}
=
\begin{bmatrix}
q_y\\
q_yu\\
q_yv+\frac12gh^2
\end{bmatrix}.
$$

This notation avoids expressions such as $hu^2$: the same term is written as $q_xu$, which explicitly means $(h\,u)u=h\,u^2$.

The current weakly nonlinear implementation can be prepared for this upgrade by:

- using conservative face-based mass fluxes now;
- separating state storage, derived quantities, flux computation, sources, and boundaries;
- keeping all terrain forcing based on $\eta=h+z_b$;
- using CFL-based substepping;
- centralizing wet/dry logic;
- naming $q_x$ and $q_y$ consistently even while they remain temporary fluxes.

---

## 19. Final recommended equation set

For the first implementation, use

$$
\frac{\partial h}{\partial t}
+\frac{\partial q_x}{\partial x}
+\frac{\partial q_y}{\partial y}
=0,
$$

with $q_x=h\,u$ and $q_y=h\,v$, together with

$$
\frac{\partial u}{\partial t}
=-g\frac{\partial (h+z_b)}{\partial x}
-\gamma u,
$$

$$
\frac{\partial v}{\partial t}
=-g\frac{\partial (h+z_b)}{\partial y}
-\gamma v.
$$

Store $h,u,v$. Derive $\eta=h+z_b$. Compute $q_x$ and $q_y$ on faces using upwind face depths and updated face velocities. Update $h$ conservatively using flux divergence.

This provides a compact, understandable solver that supports terrain, waves, moderate water redistribution, interaction, and a clean later migration to the full finite-volume shallow-water equations.
