# How these work: Saaketh Ramoju's propulsion stack, eVTOLSizer, and how Ibrido compares

Reviewed 2026-10-01 from full clones of all 17 public repos at
`github.com/saakethramoju`, plus `github.com/Vinay25112001/eVTOLSizer` (the
source behind evtolsizer.live, which deploys from that repo's `main` branch).
Everything below comes from reading the code and running it, not from the
READMEs alone. The numbers marked *ran it* were produced in this session.

---

## 1. Saaketh's stack in one picture

```
            ThermoProp  ──────────────►  property calls (ρ, h, s, μ, k, γ, a …)
  (fluids, propellants, CEA equilibrium,           │
   materials)                                      ▼
                                   FullFlow  (network solver: States + Components
                                              + Balances → steady / transient)
                                                   │            ▲
                                       HDF5 results│            │HDF5 maps (pump, turbine,
                                                   ▼            │ equilibrium, property grids)
                                            FullPlot  (inspect, plot, trace math,
                                                       redlines, map generation)

  Applications:  Raptor (FFSC engine model)  ·  Throttle-Valve-Closed-Loop-Control (HETS stand)
  Ancestors:     ROCETS-DEV → rocketflow → FluidWrapper → FullFlow / ThermoProp
  Teaching:      Engine-Design-Guide, Contour-Generator, TCA bootcamp, chamber optimizer,
                 Fluid-Network lecture (MATLAB), Engine-Data-Analysis
```

All three libraries are on PyPI, GPL-3.0, Python ≥ 3.11:
FullFlow 2.0.2 (~37k lines), ThermoProp 2.1.2 (~29k lines), FullPlot 0.1.1 (~6k lines).

---

## 2. FullFlow: how it works

FullFlow is a **lumped-parameter network solver** in the lineage of NASA ROCETS and
GFSSP. It is not CFD: every pipe, volume or turbomachine is a 0-D or 1-D element,
and the solver closes the algebraic and differential equations that connect them.

### 2.1 The three core objects

| Object | What it is | Key detail |
|---|---|---|
| `State` | A scalar value holder for every pressure, temperature, flow, command or output | Arithmetic on States builds a **live expression graph**: `v = mdot/(rho*A)` stays linked, so when the solver changes `mdot`, `v.value` updates. `<<=` wires a placeholder later. States carry `bounds` that go straight to the nonlinear solver. |
| `Component` | A physical element or correlation (a pipe, pump, PID loop, Bartz heat-transfer coefficient …) | The constructor calls `self.setup()`, which wraps plain floats in States and registers the component with its network. Equations come out through three hooks: `evaluate_states()` (explicit outputs), `balances` (algebraic `(variable, residual)` pairs), and `dynamics` (`(state, derivative)`, or `(solve_var, stored_qty, derivative)` when you iterate on P but conserve mass). |
| `Network` | The container: components, user `Balance`s, `Model` options, tracked states | `Balance(name, net, variable=x, function=expr)` adds one closure equation without writing a class. `Model` / `ModelOption` swap component variants (e.g. a constant-Cd orifice vs a map). |

### 2.2 The solvers

**Steady state** (`Solvers/steady_state/solver.py`)

- The iteration vector is all balance variables plus all dynamic states.
- Residuals are the balance errors plus the time derivatives (d/dt → 0).
- Solved with `scipy.optimize.least_squares` (TRF), using a **3-point
  finite-difference Jacobian**.
- Before each residual evaluation, derived States are settled by repeated passes
  (`state_max_passes`, `state_tolerance`).
- When a property backend throws on an unphysical trial point (CoolProp outside
  its domain, say), the solver returns a *directional penalty residual* scaled by
  the distance from the last valid point, instead of a flat 1e12 wall. That gives
  TRF a usable gradient back toward the valid region, which is a nice detail.

**Transient** (`Solvers/transient/solver.py`)

- Fixed-step **implicit backward Euler**: each step solves
  `x_new − x_old − dt·f(x_new) = 0` together with all algebraic balances, again
  with `least_squares`.
- A step that fails is retried at half the step size, down to `minimum_dt`.
- Steps snap to output times, sequence breakpoints and abort times.
- Histories export to HDF5.

**Test-stand tooling**

- `Sequence` / `SequenceCommand`: command schedules.
- `Sensor` / `SensorCondition`: redlines, aborts and events.
- `Actuator`, `PID`, `Lookup` (wraps any callable or class, ThermoProp included)
  and `Map` (an HDF5 grid made by FullPlot).

### 2.3 Component catalogue (52 classes)

| Group | Components |
|---|---|
| Flow | `DarcyWeisbach`, `DischargeCoefficient`, `CavitatingVenturi`, `SeriesCdA`/`ParallelCdA`, Poiseuille ducts, `FlowTube`, `AdiabaticFlow` |
| Compressible flow | `CompressibleOrifice`, `IsentropicNozzle`, `IsentropicDiffuser` |
| Friction | Colebrook, Churchill, Petukhov |
| Heat transfer | Gnielinski, Dittus-Boelter, Sieder-Tate, Petukhov, Miropolskii, **Bartz**, Churchill-Chu; conduction, radiation, adiabatic-wall and Eckert reference temperature |
| Nodes | `Volume` (mass and energy storage, or an algebraic junction), `Solid` (thermal mass) |
| Turbomachinery | `ConstantDensityPump`, `PolytropicPump`, `GasTurbine`, `Rotor` (shaft dynamics) |
| Rocket performance | `SpecificImpulse`, `IdealCharacteristicVelocity` |
| Composition | `Composition` (mixing and splitting) |

There are 48 worked examples (`examples/`), from a single pipe up to an engine
startup, water hammer, a shock tube, COPV blowdown and PID throttling.

### 2.4 Raptor: FullFlow at full scale

`Raptor/raptor.py` builds a full-flow staged-combustion CH4/LOX engine:

- two turbopump shafts;
- a fuel-rich and an oxygen-rich preburner;
- a regenerative circuit (chamber branch, plus nozzle downflow, turnaround and upflow);
- a copper-wall thermal network;
- a choked equilibrium nozzle.

The only boundary conditions are the tank pressures and temperatures and ambient
pressure. Everything else is solved, including shaft speeds, preburner mixture
ratios, coolant enthalpies, wall temperatures and thrust.

The pump and turbine maps and the pressure-enthalpy equilibrium maps are
precomputed into `raptor.h5` by FullPlot's map generator, because each map cell
needs an equilibrium solve inside a temperature root-find.

**Ran it:** it converged (cost 8.8e-14) in about 22 s, giving **2.355 MN** of
thrust, a throat hot-wall temperature of 2237 K, and a throat heat flux of
203 MW/m².

---

## 3. ThermoProp: how it works

ThermoProp puts one property-style API (`water.density`, `gas.speed_of_sound`) in
front of several backends:

| Wrapper | Backend |
|---|---|
| `Fluid` | CoolProp (real fluids and mixtures) |
| `IdealGas` | PYroMat |
| `Propellant` | RocketProps (RP-1, LOX, …) |
| `CombustionGas` | NASA CEA thermo and transport polynomials, packed as `.npz` |
| `Material` | Built-in curves for isotropic engineering materials |
| `SpeciesDatabase`, `MaterialDatabase` | Alias resolution across all of the above |

The interesting part is `CEAEquilibrium/`, about 11k lines. It is a
**reimplementation of NASA RP-1311 (Gordon & McBride)**, not a wrapper around
the CEA binary:

- **Method:** Gibbs-energy minimisation by the element-potential (Lagrange
  multiplier) method. Each Newton iteration assembles a reduced linear system for
  element potentials, condensed-phase corrections and Δln n (`matrix.py`).
- **Solvers:** TP, HP and SP (`hp_solver.py`, `sp_solver.py`).
- **Extras:** condensed-species handling, and transport properties (`transport.py`).
- **`Rocket`:** CEA-style rocket performance, covering infinite- and finite-area
  combustors (contraction ratio), shifting or frozen expansion, and freezing at
  the chamber, the throat or a chosen area ratio.

`Reactants(fuels, oxidizers, mixture_ratio)` → `Equilibrium(mode="hp")` → `Rocket(...)`
is the workflow. Raptor uses it to build its equilibrium maps.

## 4. FullPlot: how it works

FullPlot is a thin layer over h5py and matplotlib:

- `fplt.open("run.h5")` returns an `H5File` handle that resolves dataset
  selectors by absolute path, relative path or unique short name. It raises on
  ambiguity rather than guessing.
- `Trace` and `TimeAxis` objects support filtering, resampling, derivatives,
  windowing, scaling and offsets, plus redline/blueline overlays. Several traces
  can share one time axis that is shifted or windowed together.
- `generate_map(axes, evaluate)` writes rectangular-grid maps to HDF5 and can
  *resume* a partly built map. That is how Raptor's expensive equilibrium maps
  are built incrementally.

## 5. The smaller repos

| Repo | What it is |
|---|---|
| **Throttle-Valve-Closed-Loop-Control** (~11k lines) | Physics and PID model of the throttle valves on YJSP's HETS test stand. Has single and dual throttle, second-order valve dynamics, CdA maps (`*.parquet`) and filters. A precursor to FullFlow's `PID`, `Actuator` and `Sequence`. |
| **rocketflow** / **ROCETS-DEV** / **FluidWrapper** | Earlier generations of FullFlow and ThermoProp. ROCETS-DEV used YAML configuration (the "Vespula" engine); FullFlow replaced that with plain Python. |
| **Contour-Generator** | Single-page HTML tool for thrust-chamber and nozzle contours (live on GitHub Pages). |
| **Engine-Design-Guide** | Jupyter guide to contours, c* and Cf efficiencies. |
| **TCA-Design-Part-1-Bootcamp**, **Combustion-Chamber-Optimizer** | RP-1/LOX equilibrium and chamber-geometry optimisation scripts. |
| **Engine-Data-Analysis** | Back-solves the mixture ratio from measured Pc and thrust. |
| **Fluid-Network-Analysis-Lecture** | MATLAB live scripts and slides. |
| **saakethramoju.github.io** | MkDocs notes: equilibrium, Fanno flow, PID, Laplace, and FullFlow component docs. |
| **Light-Switch** | MicroPython hobby project. |

---

## 6. eVTOLSizer (evtolsizer.live): how it works

### 6.1 What it is

- **Author and stack:** Wright State University; Apache-2.0; React + Vite front
  end with a pure-JS engine (~78k lines).
- **Sizing modes:** conceptual sizing of six eVTOL layouts, from multicopter to
  tiltrotor, with a battery or turboelectric powertrain. A second engine sizes
  fixed-wing aircraft (trainer, turboprop, business jet, airliner).
- **Other ways to run it:** a Node API (`size()`) and an `evtol-size` command.
- **Optional services:** Supabase accounts, a Groq-powered assistant, and EmailJS
  one-time passwords.

### 6.2 The sizing loop (`src/engine.js` → `runSizingCore`)

1. **Mission basis and sizing day.** Set the hover times, reserve (20 min by
   default), headwind and ISA deviation.
2. **Round 1.** Find the fixed point of `MTOW = payload + ewf·MTOW + bf·MTOW`,
   where the battery fraction is
   `bf = g·R/(L/D · η · e_cell)`, a Breguet-style electric-range relation.
   This seeds the take-off weight.
3. **Round 2.** A coupled loop to closure on MTOW, at most 600 passes. Each pass:
   - **Hover power** comes from momentum theory with figure of merit and download:
     `T = W/(1−k)`.
     - For tiltrotors, `k = 0.1469`, which is the **XV-15's measured download**.
       It is zero for the other layouts, which the tool flags as a gap.
   - **Climb, cruise, descent and reserve power** come from a drag build-up.
     Rotor-borne cruise L/De is calibrated to NASA's published values.
   - **Mission energy.** Battery efficiency is charged only against
     vertical-flight energy, following NASA RVLT practice.
   - **Battery mass** is `max(energy-sized, power-sized)`, at 300 Wh/kg cell,
     19 % minimum state of charge and a 4C power limit, plus BMS, thermal-management
     and mount masses.
   - **Empty weight** is either a fraction model or an NDARC/AFDD component
     build-up (rotor, drive, motors, structure, systems, flight controls).
   - **Solver step.** The closure residual `f = payload + W_empty + W_bat (+fuel) − MTOW`
     is driven by a **hybrid solver**: a fixed-point step, switching to secant
     within 5 %, with bisection fallback inside a sign-change bracket and a
     stall guard (after Ugwueze et al., *Aerospace* 2023). The tolerance is
     `0.01·W·10⁻⁶` (NDARC §5-1.2).
4. **Post-loop analyses** on the converged aircraft:
   - wing and tail sizing, static margin and neutral point;
   - V-n diagram and gust loads;
   - one-engine-inoperative (OEI) controllability via the ACAI index;
   - whirl flutter against the XV-15 boundary measured by Acree;
   - autorotation index, drive-system failure;
   - acoustics (hover only), battery thermal and economics.
5. **Checks and warnings.** About 43 pass/fail checks run against SC-VTOL, FAA
   and NASA criteria. NASA-STD-7009B warnings and uncertainty statements are
   attached to every result.

### 6.3 Turboelectric option (`src/engine/turboelectric.js`)

- **Architecture:** series turboelectric. A turboshaft drives a generator that
  carries every mission segment.
- **Engine model:** NDARC's referred-parameter turboshaft. Power lapses as
  `δ√θ`, sfc is constant, and specific weight and sfc come from NASA's
  100–4000 hp UAM engine table.
- **Battery:** sized only for a 2-minute engine-out hover at ≤ 14C.

### 6.4 Accuracy and validation (its own `VALIDATION.md`)

- **NASA concept aircraft:** the quadrotor is within 0.3 % on MTOW; the
  side-by-side is −11.5 %; the lift+cruise is −23.8 % (rotor group −46.7 %).
- **Overall:** 39 comparisons, mean error 14.5 %. Commercial brochure aircraft
  have a mean error of 13.8 % with the component build-up.
- The tool states that **no referent is a built, flown and weighed aircraft**.
  That caps its NASA-STD-7009B validation credibility level at 2.
- **Ran it:** all 62 `npm test` gates pass on Node 24 once Python `lxml` is
  installed. On Node 22 the golden master fails with 9 diffs:
  - `governs_pitch` flips, because it is a `>=` tie between pitch- and yaw-sized
    tail panels;
  - an OEI margin moves by 1e-3.

  `package.json` and the README claim Node ≥ 20, so the results depend on the
  Node version.

---

## 7. Ibrido (our XV-15 hybrid) vs eVTOLSizer: parallels and differences

Ibrido facts are taken from the portfolio (`kkalaa16/kkalaa16`, `redesign` branch):

- VFS Student Design Competition entry.
- MATLAB mission-analysis framework covering rotor performance, gearbox
  circulating power, battery sizing, a fuel-optimal per-segment RPM search, and
  TEEM motor logic for nacelle conversion.
- The conventional baseline was validated against NASA XV-15 flight test
  (SP-2000-4517).
- Four hybrid topologies were traded; parallel won (1.3 % conversion loss vs 13 %
  for series).
- The feasible window is engine-downsizing α = 0.83–0.84, at 306 nmi with
  1,203 kg payload.
- The hybrid reaches 348 KTAS at 10k ft, where the baseline tops out at 278 KTAS.

### 7.1 What is the same

| Aspect | Ibrido | eVTOLSizer |
|---|---|---|
| Core loop | Mission segments → power → energy → battery/fuel → weight closure | The same structure (round 1 seed, then round 2 closure) |
| Hover physics | Momentum theory | Momentum theory with FM and the XV-15's 14.69 % download |
| Battery sizing | Energy and power constraints | `max(W_E, W_P)` with SOC window, C-rate and pack systems |
| XV-15 as a reference | Flight-test validation of the baseline | Download fraction, whirl-flutter boundary and aircraft database all cite the XV-15 |
| Validation mindset | "Validated the sizing code against real NASA XV-15 data before trusting the hybrid result" | NASA-STD-7009B: every output tagged validated, sourced, derived, calibrated or unverified |
| Turboshaft lapse | Altitude-dependent available power (it sets the envelope) | Referred-parameter `δ√θ` model |

### 7.2 Where they differ, and where Ibrido is ahead

1. **Powertrain.**
   - eVTOLSizer has battery or *series* turboelectric only. The README says
     outright that "parallel hybrids and pure turboshaft drive are not modelled".
   - Ibrido's winning architecture is **parallel**, and its baseline is a
     **conventional turboshaft**.
   - eVTOLSizer can represent neither Ibrido's answer nor its reference aircraft.
2. **Tiltrotor flight mechanics.**
   - eVTOLSizer treats every layout as an eVTOL controlled by differential thrust.
   - *Ran it:* an XV-15-class 2-rotor tiltrotor fails the check "Rotors: even & ≥ 4 … ≥ 4 needed because this layout controls attitude by differential thrust".
   - The real XV-15 uses cyclic and collective through swashplates.
3. **Proprotor cruise.**
   - *Ran it:* we sized an Ibrido-like mission (2 × 7.62 m rotors, 1,203 kg
     payload, 156 m/s ≈ 303 KTAS at 3,048 m, turboelectric). The tool's tiltrotor
     cruise L/D came out at **4.3 vs its own 8.5 target**.
   - Its cruise efficiency is calibrated, not predicted; NDARC's profile-power
     function is not implemented.
   - Ibrido computes rotor performance and searches RPM per segment, which is
     exactly the physics missing here.
4. **Conversion (transition).** eVTOLSizer's mission has vertical segments and
   wing-borne segments but no nacelle-conversion segment. Ibrido has TEEM logic
   for the conversion transients and showed that transition-timing optimisation
   is worth less than 1 %.
5. **Weight class.**
   - The XV-15 (about 6,000 kg MTOW) sits above eVTOLSizer's 5,700 kg cap:
     both the hard-coded round-1 limit and the SC-VTOL certification check.
   - *Ran it:* turboelectric gave MTOW 5,845 kg at 100 km, 6,891 kg at 300 km
     and 10,987 kg at 567 km (306 nmi). The last one carried 10 error-level
     warnings (MTOW limit, Mach 0.475, L/D, tyre load, solidity clamp 0.414 → 0.40,
     disk loading 28.9 lb/ft², climb gradient).
   - The battery-only cases did not converge at any range.
6. **Flight envelope.** Ibrido produces an altitude–speed envelope against flight
   test. eVTOLSizer reports point performance plus a V-n diagram, but has no
   power-available vs power-required envelope.
7. **Engine model fidelity.** eVTOLSizer's turboshaft has constant sfc and a
   `√θ` term that gives *more* power on a hot day (it says so itself).
   Ibrido's fuel-optimal RPM search needs part-power sfc. Your gas-turbine cycle
   project (variable γ(T), NASA polynomials) is the missing piece.

**Bottom line:** eVTOLSizer is broader (six layouts, loads, stability,
certification checks, exports, provenance bookkeeping). Ibrido is deeper exactly
where eVTOLSizer is weakest: hybrid powertrains, proprotor performance,
conversion, and validation against a real flown aircraft.

---

## 8. Gaps we can contribute to

Ordered by value to the upstream project and fit with our skills: CFD,
combustion, propulsion cycles, OpenMDAO, ML surrogates, and hybrid-electric
sizing.

### 8.1 eVTOLSizer (Apache-2.0, actively maintained, CI-gated; PRs are realistic)

1. **Parallel-hybrid powertrain module (port Ibrido).**
   - Add `powertrain: "parallelHybrid"` with α (engine downsizing),
     electric-fraction floor, gearbox circulating power and per-segment power split.
   - Add `powertrain: "turboshaft"` for conventional baselines.
   - It fills a gap the README names, and comes with our validation.
2. **XV-15 as the first "Real World System" referent.**
   - Their credibility is capped at level 2 because every referent is a model or
     a brochure.
   - The XV-15 is a built, flown and weighed tiltrotor with public flight-test
     data, which we have already digitised and matched.
   - A `validation/xv15.mjs` gate scoring weights, hover power and the envelope
     against SP-2000-4517 would be a big credibility gain for the tiltrotor path.
3. **Cyclic-controlled tiltrotor layout.** Add a control-mechanism flag so
   two-rotor swashplate tiltrotors (XV-15, V-22, V-280 class) are not failed by the
   differential-thrust "≥ 4 rotors" rule, and the ACAI/OEI checks branch correctly.
4. **Proprotor cruise model.** Replace the calibrated L/De for tiltrotors with a
   proprotor axial-flight model (BEMT or momentum with profile power), using an
   RPM schedule (Ibrido's per-segment RPM search). This fixes the L/D 4.3
   result above.
5. **Conversion segment.** Add a nacelle-conversion mission segment (time,
   power, energy) to `mission.js`.
6. **Turboshaft engine deck.**
   - Part-power sfc and the correct hot-day lapse, both listed as known omissions.
   - Source: our 1-D gas-turbine cycle code with variable γ(T). It could ship as a
     small generated deck table.
7. **CFD for hover download** (the `[GAP]` entries).
   - Download is zero for lift+cruise, multicopter and side-by-side because "no
     published value exists".
   - OpenFOAM actuator-disk RANS on the NASA lift+cruise geometry (they already
     export OpenVSP) would provide that number: a direct CFD contribution.
8. **Flight envelope output.** Power available vs required in altitude–speed
   space, like Ibrido's envelope figure.
9. **Small correctness fix.**
   - The golden master depends on the Node version (Node 22 fails,
     Node 24 passes).
   - Either make the `governs_pitch` tie-break tolerance-based or pin
     `"engines": {"node": ">=24"}`.
   - Also document the `lxml` requirement for local `npm test`.

### 8.2 FullFlow, ThermoProp, FullPlot (GPL-3.0, single maintainer)

1. **Test suites.**
   - FullFlow and FullPlot have one import-only test each; ThermoProp has none.
   - Add regression tests against analytic and reference solutions:
     - FullFlow: Joukowsky water hammer, Fanno flow, isentropic blowdown,
       shock tube.
     - ThermoProp: NASA CEA outputs (Tc, c*, Isp, species) for RP-1/LOX,
       CH4/LOX and H2/LOX.

     The examples folder already contains most of these cases.
2. **Sparse Jacobian.** Both solvers use a dense 3-point finite-difference
   Jacobian, and no `jac_sparsity` is passed to `least_squares` anywhere. The
   component-to-State graph is known, so building the sparsity pattern from it
   should cut solve times sharply (Raptor takes about 22 s).
3. **Higher-order and adaptive transient integration.** Backward Euler is
   first-order and numerically diffusive (water hammer and shock-tube fronts
   smear). Add BDF2 or TR-BDF2 with local error control and adaptive `dt`.
4. **ML surrogates for equilibrium maps.** Raptor's pressure–enthalpy
   equilibrium maps are "expensive" (an equilibrium solve per cell). A trained
   surrogate (an MLP or FNO-style operator on (P, h, MR) → T, γ, M, μ, k) fits
   behind `Lookup`, and builds on our FNO and surrogate work.
5. **Combustion depth.**
   - ThermoProp is equilibrium-only.
   - Add finite-rate or flamelet options (a Cantera-backed `Kinetics` lookup;
     FGM tables like our Baker Hughes work) for preburner and gas-generator
     temperature prediction.
   - Add film and transpiration cooling components next to `Bartz`.
6. **OpenMDAO bridge.** Wrap a FullFlow `Network` as an OpenMDAO
   `ImplicitComponent`, so cycle and feed-system optimisation can use gradient
   drivers. We have OpenMDAO and NPSS experience (AFRL project).
7. **Raptor fix.** The README references a `requirements.txt` that doesn't exist.
   Also add a comparison table against public Raptor 2 figures.

### 8.3 Bridging ideas

- **Ibrido thermal and fuel systems in FullFlow.** The hybrid's battery thermal
  loop, oil/gearbox cooling and fuel feed are exactly FullFlow's domain. A FullFlow
  "hybrid tiltrotor thermal management" example would be new for FullFlow and
  useful for the VFS report.
- **eVTOLSizer → FullFlow handoff.** eVTOLSizer's Node API emits power, energy
  and heat loads per segment, which could drive a FullFlow transient
  battery-thermal model. That would be a cross-project demo.

---

## 9. Getting copies into our GitHub

The session's GitHub integration can't create repositories in the account
(`403 Resource not accessible by integration`), so the copies have to be made
from a machine where `gh` is logged in as kkalaa16:

```bash
bash scripts/copy-repos-to-github.sh                      # 18 private copies, full history
VISIBILITY=public bash scripts/copy-repos-to-github.sh    # or public
```

- **Licences.** FullFlow, FullPlot and ThermoProp are GPL-3.0 and eVTOLSizer is
  Apache-2.0, so public copies are fine. The other 14 repos have **no licence**,
  so keep them private unless Saaketh agrees.
- **Upstream PRs.** For the contributions above, use a real GitHub **fork**,
  because a copy cannot open pull requests upstream.
