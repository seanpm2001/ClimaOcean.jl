using Oceananigans.TurbulenceClosures: HorizontalDivergenceFormulation
using Oceananigans.Advection: VelocityStencil
using CUDA

prettyelapsedtime(start) = prettytime(1e-9 * (time_ns() - start)) * ")"

"""
    quarter_degree_near_global_simulation(architecture = GPU(); kwargs...)

Return an Oceananigans.Simulation of Earth's ocean at 1/4 degree resolution.
"""
function quarter_degree_near_global_simulation(architecture = GPU();
        z                                            = stretched_vertical_cell_interfaces(),
        boundary_layer_turbulence_closure            = RiBasedVerticalDiffusivity(),
        background_vertical_diffusivity              = 1e-5,
        background_vertical_viscosity                = 1e-4,
        surface_temperature_relaxation_time_scale    = 7days,
        surface_salinity_relaxation_time_scale       = 7days,
        bottom_drag_coefficient                      = 3e-3,
        reference_density                            = 1029.0,
        reference_heat_capacity                      = 3991.0,
        reference_salinity                           = 34.0,
        time_step                                    = 6minutes,
        stop_iteration                               = Inf,
        start_time                                   = 0.0,
        stop_time                                    = Inf,
        equation_of_state                            = TEOS10EquationOfState(; reference_density),
        tracers                                      = [:T, :S],
        maximum_free_surface_iterations              = 200,
        initial_conditions                           = nothing,
        bathymetry_path                              = datadep"near_global_quarter_degree/near_global_bathymetry_1440_600.jld2",
        surface_temperature_boundary_conditions_path = datadep"near_global_quarter_degree/near_global_surface_temperature_1440_600.jld2",
        surface_salinity_boundary_conditions_path    = datadep"near_global_quarter_degree/near_global_surface_salinity_1440_600.jld2",
        east_momentum_flux_path                      = datadep"near_global_quarter_degree/near_global_east_momentum_flux_1440_600.jld2",
        north_momentum_flux_path                     = datadep"near_global_quarter_degree/near_global_north_momentum_flux_1440_600.jld2",
    )

    start_building_simulation = time_ns()

    bathymetry_file = jldopen(bathymetry_path)
    bathymetry = bathymetry_file["bathymetry"]
    close(bathymetry_file)

    if isnothing(initial_conditions)
        initial_conditions_path = datadep"near_global_one_degree/near_global_initial_conditions_360_150_48.jld2"
        @info "Preparing initial conditions..."; start=time_ns()
        initial_conditions_file = jldopen(initial_conditions_path)
        T_one_degree_data = initial_conditions_file["T"]
        S_one_degree_data = initial_conditions_file["S"]
        one_degree_grid = initial_conditions_file["grid"]
        close(initial_conditions_file)
        @info "... read initial conditions (" * prettyelapsedtime(start) * ")"
    end

    T_one_degree = CenterField(one_degree_grid)
    S_one_degree = CenterField(one_degree_grid)

    interior(T_one_degree) .= T_one_degree_data
    interior(S_one_degree) .= S_one_degree_data

    T_quarter, S_quarter = regrid_to_quarter_degree(T_one_degree, S_one_degree, bathymetry; z, architecture)

    # Files contain 12 arrays of monthly-averaged data from 1992
    @info "Reading boundary conditions..."; start=time_ns()
    # Files contain 1 year (1992) of 12 monthly averages
    τˣ = jldopen(east_momentum_flux_path)["east_momentum_flux"] ./ reference_density
    τʸ = jldopen(north_momentum_flux_path)["north_momentum_flux"] ./ reference_density
    T★ = jldopen(surface_temperature_boundary_conditions_path)["surface_temperature"] 
    S★ = jldopen(surface_salinity_boundary_conditions_path)["surface_salinity"] 
    Qˢ = zeros(size(T★)...)
    Qᵀ = zeros(size(S★)...)
    @info "... read boundary conditions (" * prettyelapsedtime(start) * ")"

    # Convert boundary conditions arrays to GPU
    τˣ = arch_array(architecture, τˣ)
    τʸ = arch_array(architecture, τʸ)
    target_sea_surface_temperature = T★ = arch_array(architecture, T★)
    target_sea_surface_salinity    = S★ = arch_array(architecture, S★)
    surface_temperature_flux       = Qᵀ = arch_array(architecture, Qᵀ)
    surface_salt_flux              = Qˢ = arch_array(architecture, Qˢ)

    # Stretched faces from ECCO Version 4 (49 levels in the vertical)
    cpu_grid = T_quarter.grid
    Nx, Ny, Nz = size(cpu_grid)

    @info "Creating quarter degree grid..."; start=time_ns()
    # Remake quarter degree grid on `architecture`
    underlying_grid = LatitudeLongitudeGrid(architecture; z,
                                            size = (Nx, Ny, Nz),
                                            longitude = (-180, 180),
                                            latitude = (-75, 75),
                                            halo = (5, 5, 5))

    grid = ImmersedBoundaryGrid(underlying_grid, GridFittedBottom(bathymetry))
    @info "... created quarter degree grid (" * prettyelapsedtime(start) * ")"

    #####
    ##### Physics and model setup
    #####

    @info "Building quarter degree model..."; start=time_ns()

    vitd = VerticallyImplicitTimeDiscretization()
    vertical_viscosity = VerticalScalarDiffusivity(vitd, ν=background_vertical_viscosity, κ=background_vertical_diffusivity)
    closures = (boundary_layer_turbulence_closure, vertical_viscosity)
    boundary_layer_turbulence_closure isa CATKEVerticalDiffusivity && push!(tracers, :e)

    #####
    ##### Boundary conditions / time-dependent fluxes 
    #####

    drag_u = FluxBoundaryCondition(u_immersed_bottom_drag, discrete_form=true, parameters=bottom_drag_coefficient)
    drag_v = FluxBoundaryCondition(v_immersed_bottom_drag, discrete_form=true, parameters=bottom_drag_coefficient)

    no_slip_bc = ValueBoundaryCondition(0)

    u_immersed_bc = ImmersedBoundaryCondition(bottom = drag_u,
                                              west = no_slip_bc,
                                              east = no_slip_bc,
                                              south = no_slip_bc,
                                              north = no_slip_bc)

    v_immersed_bc = ImmersedBoundaryCondition(bottom = drag_v,
                                              west = no_slip_bc,
                                              east = no_slip_bc,
                                              south = no_slip_bc,
                                              north = no_slip_bc)

    u_bottom_drag_bc = FluxBoundaryCondition(u_bottom_drag, discrete_form=true, parameters=bottom_drag_coefficient)
    v_bottom_drag_bc = FluxBoundaryCondition(v_bottom_drag, discrete_form=true, parameters=bottom_drag_coefficient)

    Nmonths = 12 # number of months in the forcing file
    u_wind_stress_parameters = (; τ=τˣ, Nmonths)
    v_wind_stress_parameters = (; τ=τʸ, Nmonths)
    u_wind_stress_bc = FluxBoundaryCondition(surface_wind_stress, discrete_form=true, parameters=u_wind_stress_parameters)
    v_wind_stress_bc = FluxBoundaryCondition(surface_wind_stress, discrete_form=true, parameters=v_wind_stress_parameters)

    Δz_top = @allowscalar Δzᵃᵃᶜ(1, 1, grid.Nz, grid.underlying_grid)

    T_relaxation_parameters = (; λ = Δz_top / surface_temperature_relaxation_time_scale,
                                 Nmonths,
                                 T★ = target_sea_surface_temperature,
                                 Q★ = surface_temperature_flux)

    S_relaxation_parameters = (; λ = Δz_top / surface_salinity_relaxation_time_scale,
                                 Nmonths,
                                 S★ = target_sea_surface_salinity,
                                 F★ = surface_salt_flux)

    T_surface_relaxation_bc = FluxBoundaryCondition(surface_temperature_relaxation,
                                                    discrete_form = true,
                                                    parameters = T_relaxation_parameters)

    S_surface_relaxation_bc = FluxBoundaryCondition(surface_salinity_relaxation,
                                                    discrete_form = true,
                                                    parameters = S_relaxation_parameters)

    u_bcs = FieldBoundaryConditions(top = u_wind_stress_bc,
                                    bottom = u_bottom_drag_bc,
                                    immersed = u_immersed_bc)

    v_bcs = FieldBoundaryConditions(top = v_wind_stress_bc,
                                    bottom = v_bottom_drag_bc,
                                    immersed = v_immersed_bc)

    T_bcs = FieldBoundaryConditions(top = T_surface_relaxation_bc)
    S_bcs = FieldBoundaryConditions(top = S_surface_relaxation_bc)

    buoyancy     = SeawaterBuoyancy(; equation_of_state)
    coriolis     = HydrostaticSphericalCoriolis(scheme = WetCellEnstrophyConservingScheme())
    free_surface = ImplicitFreeSurface(maximum_iterations=maximum_free_surface_iterations)

    model = HydrostaticFreeSurfaceModel(; grid, free_surface, coriolis, buoyancy, tracers,
                                        momentum_advection = VectorInvariant(vorticity_scheme   = WENO(),
                                                                             divergence_scheme  = WENO(),
                                                                             vertical_scheme    = WENO()),
                                        tracer_advection = WENO(underlying_grid),
                                        closure = closures,
                                        boundary_conditions = (u=u_bcs, v=v_bcs, T=T_bcs, S=S_bcs))

    @info "... created quarter degree model (" * prettyelapsedtime(start) * ")"

    #####
    ##### Initial condition:
    #####

    set!(model, T=T_quarter, S=S_quarter)
    boundary_layer_turbulence_closure isa CATKEVerticalDiffusivity && set!(model, e=1e-6)

    # Because MITgcm forcing starts at Jan 15 (?)
    model.clock.time = start_time

    simulation = Simulation(model; Δt=time_step, stop_iteration, stop_time)

    start_time = [time_ns()]

    function progress(sim)
        wall_time = (time_ns() - start_time[1]) * 1e-9

        u = sim.model.velocities.u
        w = sim.model.velocities.w

        intw  = Array(interior(w))
        max_w = findmax(intw)

        mw = max_w[1]
        iw = max_w[2]

        msg1 = @sprintf("Time: % 12s, iteration: %d, ", prettytime(sim), iteration(sim))

        msg2 = @sprintf("max(|u|): %.2e m s⁻¹, wmax: %.2e, loc: (%d, %d, %d), ",
                        maximum(abs, u), mw, iw[1], iw[2], iw[3])

        if boundary_layer_turbulence_closure isa CATKEVerticalDiffusivity
            e = sim.model.tracers.e
            msg2a = @sprintf("extrema(e): (%.2e, %.2e)  m² s⁻², ", maximum(e), minimum(e))
            msg2 *= msg2a
        end

        msg3 = @sprintf("wall time: %s", prettytime(wall_time))

        @info msg1 * msg2 * msg3

        start_time[1] = time_ns()

        return nothing
    end

    simulation.callbacks[:progress] = Callback(progress, IterationInterval(10))

    @info "Finishing building simulation. Total build time: " * prettyelapsedtime(start_building_simulation)

    return simulation
end

function stretched_vertical_cell_interfaces(; surface_layer_Δz = 5.0,
                                            surface_layer_height = 100.0,
                                            stretching_parameter = 1.02,
                                            minimum_depth = 5000)

    Δz₀ = surface_layer_Δz
    h₀ = surface_layer_height
    
    # Generate surface layer grid
    z = [-Δz₀ * (k-1) for k = 1:ceil(h₀ / Δz₀)]
    
    # Generate stretched interior grid
    γ = stretching_parameter
    Lz₀ = minimum_depth
    
    while z[end] > - Lz₀
        Δz = (z[end-1] - z[end])^γ
        push!(z, round(z[end] - Δz, digits=1))
    end
    
    # Reverse grid to be right-side-up
    z = reverse(z)
    
    # Infer domain parameters
    Lz = z[1]

    return z
end

function regrid_to_quarter_degree(T, S, bathymetry;
                                  architecture = GPU(),
                                  z = stretched_vertical_cell_interfaces(),
                                  initial_vertical_diffusion_steps=0,
                                  initial_horizontal_diffusion_steps=0)

    Nz = length(z) - 1
    vertically_refined_one_degree_grid = LatitudeLongitudeGrid(CPU(); z,
                                                               size = (360, 150, Nz),
                                                               longitude = (-180, 180),
                                                               latitude = (-75, 75),
                                                               halo = (5, 5, 5))

    T_one = CenterField(vertically_refined_one_degree_grid)
    S_one = CenterField(vertically_refined_one_degree_grid)

    regrid!(T_one, T)
    regrid!(S_one, S)

    #=
    start_time = time_ns()
    # T⁺ = T⁻ + κ * ∂z(∂z(T⁻))
    Δz = z[Nz] - z[Nz-1]
    κz = Δz^2
    for i = 1:initial_vertical_diffusion_steps
        T_one .= T_one .+ 0.05 * κz * ∂z(∂z(T_one))
        S_one .= S_one .+ 0.05 * κz * ∂z(∂z(S_one))
        elapsed = 1e-9 * (time_ns() - start_time)
        elapsed_str = prettytime(elapsed)
        @info "Vertically diffusing one degree solution, step $i, $elapsed_str"
        start_time = time_ns()
    end
    =#

    #####
    ##### Regrid one degree initial condition to quarter degree grid with high vertical resolution
    #####

    # Intermediate grid: quarter degree in x, one degree in y
    quarter_degree_x_grid = LatitudeLongitudeGrid(CPU(); z,
                                                  size = (1440, 150, Nz),
                                                  longitude = (-180, 180),
                                                  latitude = (-75, 75),
                                                  halo = (5, 5, 5))

    T_quarter_x = CenterField(quarter_degree_x_grid)
    S_quarter_x = CenterField(quarter_degree_x_grid)

    regrid!(T_quarter_x, T_one)
    regrid!(S_quarter_x, S_one)

    # Quarter degree grid
    quarter_degree_grid = LatitudeLongitudeGrid(CPU(); z,
                                                size = (1440, 600, Nz),
                                                longitude = (-180, 180),
                                                latitude = (-75, 75),
                                                halo = (5, 5, 5))

    T_quarter = CenterField(quarter_degree_grid)
    S_quarter = CenterField(quarter_degree_grid)

    regrid!(T_quarter, T_quarter_x)
    regrid!(S_quarter, S_quarter_x)


    if architecture isa GPU
        # Quarter degree grid
        quarter_degree_grid = LatitudeLongitudeGrid(GPU(); z,
                                                    size = (1440, 600, Nz),
                                                    longitude = (-180, 180),
                                                    latitude = (-75, 75),
                                                    halo = (5, 5, 5))

        quarter_degree_grid = ImmersedBoundaryGrid(quarter_degree_grid, GridFittedBottom(bathymetry)) 

        T_quarter = CenterField(quarter_degree_grid)
        S_quarter = CenterField(quarter_degree_grid)
    end

    parent(T_quarter) .= arch_array(architecture, parent(T_quarter))
    parent(S_quarter) .= arch_array(architecture, parent(S_quarter))

    start = time_ns()
    Δz = z[Nz] - z[Nz-1]
    κz = Δz^2
    Δh = 25kilometers
    κh = Δh^2
    for i = 1:initial_horizontal_diffusion_steps
        T_quarter .= T_quarter .+ 0.05 * κh * ∂x(∂x(T_quarter))
        S_quarter .= S_quarter .+ 0.05 * κh * ∂x(∂x(S_quarter))
        T_quarter .= T_quarter .+ 0.05 * κh * ∂y(∂y(T_quarter))
        S_quarter .= S_quarter .+ 0.05 * κh * ∂y(∂y(S_quarter))
        T_quarter .= T_quarter .+ 0.05 * κz * ∂z(∂z(T_quarter))
        S_quarter .= S_quarter .+ 0.05 * κz * ∂z(∂z(S_quarter))
        @info "Horizontally diffusing quarter degree solution, step $i, " * prettyelapsedtime(start)
        start = time_ns()
    end


    return T_quarter, S_quarter
end

