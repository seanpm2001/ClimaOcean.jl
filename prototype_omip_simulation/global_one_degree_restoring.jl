using Printf
using Oceananigans
using Oceananigans.Units
using ClimaOcean
using OrthogonalSphericalShellGrids
using Oceananigans
using Oceananigans: architecture
using ClimaOcean
using Oceananigans.TurbulenceClosures.CATKEVerticalDiffusivities: CATKEVerticalDiffusivity
using Oceananigans.Coriolis: ActiveCellEnstrophyConserving
using Oceananigans.Units
using ClimaOcean.OceanSimulations
using ClimaOcean.OceanSeaIceModels
using ClimaOcean.OceanSeaIceModels.CrossRealmFluxes: Radiation, SimilarityTheoryTurbulentFluxes, simplified_bulk_coefficients
using ClimaOcean.VerticalGrids: exponential_z_faces
using ClimaOcean.JRA55
using ClimaOcean.ECCO
using ClimaOcean.JRA55: JRA55NetCDFBackend, JRA55_prescribed_atmosphere
using ClimaOcean.ECCO: ECCO_restoring_forcing, ECCO4Monthly, ECCO2Daily, ECCOMetadata
using ClimaOcean.Bathymetry

using CFTime
using Dates

include("tripolar_specific_methods.jl")
# include("xin_kai_vertical_diffusivity.jl")

#####
##### Global Ocean at 1/6th of a degree
#####

bathymetry_file = nothing # "bathymetry_tmp.jld2"

# 60 vertical levels
z_faces = exponential_z_faces(Nz=20, depth=6000)

Nx = 360
Ny = 180
Nz = length(z_faces) - 1

arch = CPU() 

grid = TripolarGrid(arch; 
                    size = (Nx, Ny, Nz), 
                    halo = (7, 7, 7), 
                    z = z_faces, 
                    north_poles_latitude = 55,
                    first_pole_longitude = 75)

bottom_height = retrieve_bathymetry(grid, bathymetry_file; 
                                    minimum_depth = 10,
                                    dir = "./",
                                    interpolation_passes = 20,
                                    connected_regions_allowed = 0)
 
grid = ImmersedBoundaryGrid(grid, GridFittedBottom(bottom_height); active_cells_map = true) 

#####
##### The Ocean component
#####                             

const Lz = grid.Lz
const  h = Nz / 4.5

@inline exponential_profile(z; Lz, h) = (exp(z / h) - exp( - Lz / h)) / (1 - exp( - Lz / h))
@inline νz(x, y, z, t) = 1e-4 + (5e-3 - 1e-4) * exponential_profile(z; Lz, h)

free_surface = SplitExplicitFreeSurface(grid; substeps = 75)
vertical_diffusivity = VerticalScalarDiffusivity(VerticallyImplicitTimeDiscretization(), κ = 5e-5, ν = νz)

closure = (RiBasedVerticalDiffusivity(), vertical_diffusivity) # 

#####
##### Add restoring to ECCO fields for temperature and salinity in the artic and antarctic
#####

# Build a mask that goes from 0 to 1 as a cubic function of φ between
# 70 degrees and 90 degrees and zero derivatives at 70 and 90.
x₁ = 70
x₂ = 90
y₁ = 0
y₂ = 1

A⁺ = [ x₁^3   x₁^2  x₁ 1
       x₂^3   x₂^2  x₂ 1
       3*x₁^2 2*x₁  1  0
       3*x₂^2 2*x₂  1  0]
           
b⁺ = [y₁, y₂, 0, 0]
 
const c⁺ = A⁺ \ b⁺

x₁ = - 70
x₂ = - 90
y₁ = 0
y₂ = 1

A⁻ = [ x₁^3   x₁^2  x₁ 1
       x₂^3   x₂^2  x₂ 1
       3*x₁^2 2*x₁  1  0
       3*x₂^2 2*x₂  1  0]
           
b⁻ = [y₁, y₂, 0, 0]
 
const c⁻ = A⁻ \ b⁻

@inline mask(λ, φ, z, t) = ifelse(φ >=  70, c⁺[1] * φ^3 + c⁺[2] * φ^2 + c⁺[3] * φ + c⁺[4],
                           ifelse(φ <= -70, c⁻[1] * φ^3 + c⁻[2] * φ^2 + c⁻[3] * φ + c⁻[4], 0))

dates = DateTimeProlepticGregorian(1993, 1, 1) : Month(1) : DateTimeProlepticGregorian(1993, 12, 1)

temperature = ECCOMetadata(:temperature, dates, ECCO4Monthly())
salinity    = ECCOMetadata(:salinity,    dates, ECCO4Monthly())

FT = ECCO_restoring_forcing(temperature; grid, mask, architecture = arch, timescale = 20days)
FS = ECCO_restoring_forcing(salinity;    grid, mask, architecture = arch, timescale = 20days)

forcing = (; T = FT, S = FS)

tracer_advection = WENO()
momentum_advection = VectorInvariant(vorticity_scheme = WENO(),
                                     divergence_scheme = WENO())

ocean = ocean_simulation(grid; free_surface, 
                               closure, 
                               forcing, 
                               momentum_advection,
                               tracer_advection) 
model = ocean.model

set!(model, 
     T = ECCOMetadata(:temperature, DateTimeProlepticGregorian(1992, 1, 2), ECCO2Daily()),
     S = ECCOMetadata(:salinity,    DateTimeProlepticGregorian(1992, 1, 2), ECCO2Daily()))

#####
##### The atmosphere
#####

backend    = JRA55NetCDFBackend(4) 
atmosphere = JRA55_prescribed_atmosphere(arch; backend)
radiation  = Radiation(arch)

sea_ice = ClimaOcean.OceanSeaIceModels.MinimumTemperatureSeaIce()

similarity_theory = SimilarityTheoryTurbulentFluxes(grid; bulk_coefficients = simplified_bulk_coefficients)

coupled_model = OceanSeaIceModel(ocean, sea_ice; atmosphere, similarity_theory, radiation)

wall_time = [time_ns()]

function progress(sim) 
    u, v, w = sim.model.velocities  
    T, S = sim.model.tracers

    Tmax = maximum(interior(T))
    Tmin = minimum(interior(T))
    umax = maximum(interior(u)), maximum(interior(v)), maximum(interior(w))
    step_time = 1e-9 * (time_ns() - wall_time[1])

    @info @sprintf("Time: %s, Iteration %d, Δt %s, max(vel): (%.2e, %.2e, %.2e), max(trac): %.2f, %.2f, wtime: %s \n",
                   prettytime(sim.model.clock.time),
                   sim.model.clock.iteration,
                   prettytime(sim.Δt),
                   umax..., Tmax, Tmin, prettytime(step_time))

     wall_time[1] = time_ns()
end

ocean.callbacks[:progress] = Callback(progress, IterationInterval(10))

fluxes = (u = model.velocities.u.boundary_conditions.top.condition,
          v = model.velocities.v.boundary_conditions.top.condition,
          T = model.tracers.T.boundary_conditions.top.condition,
          S = model.tracers.S.boundary_conditions.top.condition)

ocean.output_writers[:fluxes] = JLD2OutputWriter(model, fluxes,
                                                  schedule = TimeInterval(0.5days),
                                                  overwrite_existing = true,
                                                  array_type = Array{Float32},
                                                  filename = "surface_fluxes")

ocean.output_writers[:surface] = JLD2OutputWriter(model, merge(model.tracers, model.velocities),
                                                  schedule = TimeInterval(0.5days),
                                                  overwrite_existing = true,
                                                  array_type = Array{Float32},
                                                  filename = "surface",
                                                  indices = (:, :, grid.Nz))

ocean.output_writers[:snapshots] = JLD2OutputWriter(model, merge(model.tracers, model.velocities),
                                                    schedule = TimeInterval(10days),
                                                    overwrite_existing = true,
                                                    array_type = Array{Float32},
                                                    filename = "snapshots")

ocean.output_writers[:checkpoint] = Checkpointer(model, 
                                                 schedule = TimeInterval(60days),
                                                 overwrite_existing = true,
                                                 prefix = "checkpoint")

# Simulation warm up!
ocean.Δt = 10
ocean.stop_iteration = Inf
wizard = TimeStepWizard(; cfl = 0.3, max_Δt = 1200, max_change = 1.1)
ocean.callbacks[:wizard] = Callback(wizard, IterationInterval(1))

stop_time = 30days

coupled_simulation = Simulation(coupled_model; Δt=1, stop_time)

run!(coupled_simulation)

wizard = TimeStepWizard(; cfl = 0.4, max_Δt = 800, max_change = 1.1)
ocean.callbacks[:wizard] = Callback(wizard, IterationInterval(10))

# Let's reset the maximum number of iterations
coupled_model.ocean.stop_time = 7200days
coupled_simulation.stop_time = 7200days
coupled_model.ocean.stop_iteration = Inf
coupled_simulation.stop_iteration = Inf

run!(coupled_simulation)