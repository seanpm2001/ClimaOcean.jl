using Printf
using Oceananigans
using Oceananigans.Units
using ClimaOcean
using ClimaSeaIce
using OrthogonalSphericalShellGrids
using Oceananigans
using Oceananigans: architecture
using Oceananigans.Grids: on_architecture
using Oceananigans.Coriolis: ActiveCellEnstrophyConserving
using Oceananigans.Units
using ClimaOcean
using ClimaOcean.OceanSimulations
using ClimaOcean.OceanSeaIceModels
using ClimaOcean.OceanSeaIceModels.CrossRealmFluxes: Radiation, SimilarityTheoryTurbulentFluxes
using ClimaOcean.VerticalGrids: exponential_z_faces
using ClimaOcean.JRA55
using ClimaOcean.ECCO
using ClimaOcean.JRA55: JRA55NetCDFBackend, JRA55_prescribed_atmosphere
using ClimaOcean.ECCO: ECCO_restoring_forcing, ECCO4Monthly, ECCO2Daily, ECCOMetadata
using ClimaOcean.Bathymetry
using ClimaOcean.OceanSeaIceModels.CrossRealmFluxes: LatitudeDependentAlbedo
using ClimaSeaIce.SeaIceDynamics: ExplicitMomentumSolver
using CairoMakie
using CFTime
using Dates

include("restoring_mask.jl")

#####
##### Global Ocean at 1/6th of a degree
#####

bathymetry_file = nothing # "bathymetry_tmp.jld2"

# 60 vertical levels
z_faces = exponential_z_faces(Nz=20, depth=4000)

Nx = 1000
Ny = 800
Nz = length(z_faces) - 1

arch = GPU() 

grid = TripolarGrid(arch; 
                    size = (Nx, Ny, Nz), 
                    halo = (7, 7, 7), 
                    z = z_faces, 
                    north_poles_latitude = 55,
                    first_pole_longitude = 75,
                    southermost_latitude = 40)

sea_ice_grid = TripolarGrid(arch; 
                            size = (Nx, Ny, 1), 
                            halo = (7, 7, 7), 
                            z = (-1, 0), 
                            north_poles_latitude = 55,
                            first_pole_longitude = 75,
                            southermost_latitude = 40)

bottom_height = retrieve_bathymetry(grid, bathymetry_file; 
                                    minimum_depth = 2,
                                    dir = "./",
                                    interpolation_passes = 20,
                                    connected_regions_allowed = Inf)
 
grid         = ImmersedBoundaryGrid(grid, GridFittedBottom(bottom_height)) 
sea_ice_grid = ImmersedBoundaryGrid(sea_ice_grid, GridFittedBottom(bottom_height)) 

#####
##### The Ocean component
#####                             

free_surface = SplitExplicitFreeSurface(grid; cfl = 0.75, fixed_Δt = 200)

dates = DateTimeProlepticGregorian(1993, 1, 1) : Month(1) : DateTimeProlepticGregorian(1993, 12, 1)

temperature = ECCOMetadata(:temperature, dates, ECCO4Monthly())
salinity    = ECCOMetadata(:salinity,    dates, ECCO4Monthly())

FT = ECCO_restoring_forcing(temperature; mask = cubic_restoring_mask(50, 30), grid, architecture = arch, timescale = 30days)
FS = ECCO_restoring_forcing(salinity;    mask = cubic_restoring_mask(50, 30), grid, architecture = arch, timescale = 30days)

forcing = (; T = FT, S = FS)

ocean = ocean_simulation(grid; free_surface, forcing) 
model = ocean.model

#####
##### Sea ice simulation
#####

u_surface_velocity = interior(model.velocities.u, :, :, grid.Nz)
v_surface_velocity = interior(model.velocities.v, :, :, grid.Nz)

ocean_velocities = (; u = u_surface_velocity,
                      v = v_surface_velocity)

sea_ice = sea_ice_simulation(sea_ice_grid; ocean_velocities) 

ice_thickness     = ECCOMetadata(:sea_ice_thickness,     dates[1], ECCO4Monthly())
ice_concentration = ECCOMetadata(:sea_ice_area_fraction, dates[1], ECCO4Monthly())
inpaint_kwargs = (; maxiter = 2)

set!(sea_ice.model.ice_thickness,     ice_thickness;     inpaint_kwargs...)
set!(sea_ice.model.ice_concentration, ice_concentration; inpaint_kwargs...)

#####
##### A prescribed atmosphere
#####

backend    = JRA55NetCDFBackend(4) 
atmosphere = JRA55_prescribed_atmosphere(arch; backend)
radiation  = Radiation(arch)

#####
##### Building the complete simulation
#####

coupled_model = OceanSeaIceModel(ocean, sea_ice; atmosphere, radiation)
coupled_simulation = Simulation(coupled_model; Δt = 1minutes, stop_time = 10days)

wall_time = [time_ns()]

# Container to hold the data
htimeseries = []
ℵtimeseries = []
utimeseries = []
vtimeseries = []

## Callback function to collect the data from the `sim`ulation
function accumulate_timeseries(sim)
    h = sim.model.sea_ice.model.ice_thickness
    ℵ = sim.model.sea_ice.model.ice_concentration
    u = sim.model.sea_ice.model.velocities.u
    v = sim.model.sea_ice.model.velocities.v
    push!(htimeseries, deepcopy(Array(interior(h))))
    push!(ℵtimeseries, deepcopy(Array(interior(ℵ))))
    push!(utimeseries, deepcopy(Array(interior(u))))
    push!(vtimeseries, deepcopy(Array(interior(v))))
end

function progress(sim) 
    u, v, w = sim.model.ocean.model.velocities  
    T, S = sim.model.ocean.model.tracers

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

coupled_simulation.callbacks[:progress] = Callback(progress, IterationInterval(10))
coupled_simulation.callbacks[:save]     = Callback(accumulate_timeseries, IterationInterval(10))

run!(coupled_simulation)

# Visualize!
Nt = length(htimeseries)
iter = Observable(1)

hi = @lift(htimeseries[$iter][:, :, 1])
ℵi = @lift(ℵtimeseries[$iter][:, :, 1])
ui = @lift(utimeseries[$iter][:, :, 1])
vi = @lift(vtimeseries[$iter][:, :, 1])

fig = Figure(size = (1000, 500))
ax = Axis(fig[1, 1], title = "sea ice thickness")
heatmap!(ax, hi, colormap = :magma,         colorrange = (0.0, 2.0))

ax = Axis(fig[1, 2], title = "sea ice concentration")
heatmap!(ax, ℵi, colormap = Reverse(:deep), colorrange = (0.0, 1))

ax = Axis(fig[2, 1], title = "zonal velocity")
heatmap!(ax, ui, colorrange = (0, 0.12), colormap = :balance)

ax = Axis(fig[2, 2], title = "meridional velocity")
heatmap!(ax, vi, colorrange = (-0.025, 0.025), colormap = :bwr)

GLMakie.record(fig, "sea_ice_dynamics.mp4", 1:Nt, framerate = 50) do i
    iter[] = i
    @info "doing iter $i"
end
