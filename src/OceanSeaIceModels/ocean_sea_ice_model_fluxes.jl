using Oceananigans.Models.HydrostaticFreeSurfaceModels: HydrostaticFreeSurfaceModel
using ClimaSeaIce.SlabSeaIceModels: SlabSeaIceModel

#####
##### Utilities
#####

@inline stateindex(a::Number, i, j, k, time) = a
@inline stateindex(a::SKOFTS, i, j, k, time) = a[i, j, k, time]
@inline stateindex(a::AbstractArray, i, j, k, time) = a[i, j, k]
@inline Δϕt²(i, j, k, grid, ϕ1, ϕ2, time) = (stateindex(ϕ1, i, j, k, time) - stateindex(ϕ2, i, j, k, time))^2

@inline function stateindex(a::Tuple, i, j, k, time)
    N = length(a)
    ntuple(Val(N)) do n
        stateindex(a[n], i, j, k, time)
    end
end

@inline function stateindex(a::NamedTuple, i, j, k, time)
    vals = stateindex(values(a), i, j, k, time)
    names = keys(a)
    return NamedTuple{names}(vals)
end

function surface_flux(f::Field)
    top_bc = f.boundary_conditions.top
    if top_bc isa BoundaryCondition{<:Oceananigans.BoundaryConditions.Flux}
        return top_bc.condition
    else
        return nothing
    end
end

#####
##### Convenience containers for surface fluxes
##### 
##### "Cross realm fluxes" can refer to the flux _data_ (ie, fields representing
##### the total flux for a given variable), or to the flux _components_ / formula.
#####

struct CrossRealmFluxes{M, H, T}
    momentum :: M
    heat :: H
    tracers :: T
end

CrossRealmFluxes(; momentum=nothing, heat=nothing, tracers=nothing) =
    CrossRealmFluxes(momentum, heat, tracers)

Base.summary(osf::CrossRealmFluxes) = "CrossRealmFluxes"
Base.show(io::IO, osf::CrossRealmFluxes) = print(io, summary(osf))

#####
##### Container for organizing information related to fluxes
#####

struct OceanSeaIceModelFluxes{U, R, AO, ASI, SIO}
    bulk_velocity_scale :: U
    surface_radiation :: R
    atmosphere_ocean :: AO
    atmosphere_sea_ice :: ASI
    sea_ice_ocean :: SIO
end

function default_atmosphere_ocean_fluxes(FT=Float64, tracers=tuple(:S))
    momentum_transfer_coefficient = 1e-3
    evaporation_transfer_coefficient = 1e-3
    sensible_heat_transfer_coefficient = 1e-3

    τˣ = BulkFormula(RelativeUVelocity(), momentum_transfer_coefficient)
    τʸ = BulkFormula(RelativeVVelocity(), momentum_transfer_coefficient)
    momentum_flux_formulae = (u=τˣ, v=τʸ)

    water_vapor_difference = WaterVaporFraction(FT)
    evaporation = BulkFormula(WaterVaporFraction(FT), evaporation_transfer_coefficient)
    tracer_flux_formulae = (; S = evaporation)

    vaporization_enthalpy  = convert(FT, 2.5e-3)
    latent_heat_difference = LatentHeat(vapor_difference = water_vapor_difference; vaporization_enthalpy)
    latent_heat_formula    = BulkFormula(latent_heat_difference,  evaporation_transfer_coefficient)
    sensible_heat_formula  = BulkFormula(SensibleHeat(), sensible_heat_transfer_coefficient)

    heat_flux_formulae = (sensible_heat_formula, latent_heat_formula)

    return CrossRealmFluxes(momentum = momentum_flux_formulae,
                            heat = heat_flux_formulae,
                            tracers = tracer_flux_formulae)
end

function OceanSeaIceModelFluxes(FT=Float64;
                                bulk_velocity_scale = RelativeVelocityScale(),
                                surface_radiation = nothing,
                                atmosphere_ocean = nothing,
                                atmosphere_sea_ice = nothing,
                                sea_ice_ocean = nothing)

    if isnothing(atmosphere_ocean) # defaults
        atmosphere_ocean = default_atmosphere_ocean_fluxes(FT)
    end

    return OceanSeaIceModelFluxes(bulk_velocity_scale,
                                  surface_radiation,
                                  atmosphere_ocean,
                                  atmosphere_sea_ice,
                                  sea_ice_ocean)
end

Base.summary(crf::OceanSeaIceModelFluxes) = "OceanSeaIceModelFluxes"
Base.show(io::IO, crf::OceanSeaIceModelFluxes) = print(io, summary(crf))

#####
##### Bulk formula
#####

"""
    BulkFormula(air_sea_difference, transfer_coefficient)

The basic structure of a flux `J` computed by a bulk formula is:

```math
J = - ρₐ * C * Δc * ΔU
```

where `ρₐ` is the density of air, `C` is the `transfer_coefficient`,
`Δc` is the air_sea_difference, and `ΔU` is the bulk velocity scale.
"""
struct BulkFormula{F, CD}
    air_sea_difference :: F
    transfer_coefficient :: CD
end

@inline function cross_realm_flux(i, j, grid, time, formula::BulkFormula, ΔU, atmos_state, ocean_state)
    ρₐ = stateindex(atmos_state.ρ, i, j, 1, time)
    C = formula.transfer_coefficient
    Δc = air_sea_difference(i, j, grid, time, formula.air_sea_difference, atmos_state, ocean_state)

    # Note the sign convention, which corresponds to positive upward fluxes:
    return - ρₐ * C * Δc * ΔU
end

@inline cross_realm_flux(i, j, grid, time, ::Nothing,        args...) = zero(grid)
@inline cross_realm_flux(i, j, grid, time, a::AbstractArray, args...) = stateindex(a, i, j, 1, time)
@inline cross_realm_flux(i, j, grid, time, nt::NamedTuple,   args...) = cross_realm_flux(i, j, grid, time, values(nt), args...)

@inline cross_realm_flux(i, j, grid, time, flux_tuple::Tuple{<:Any, <:Any}, args...) =
    cross_realm_flux(i, j, grid, time, flux_tuple[1], args...) +
    cross_realm_flux(i, j, grid, time, flux_tuple[2], args...)

@inline cross_realm_flux(i, j, grid, time, flux_tuple::Tuple{<:Any, <:Any, <:Any}, args...) =
    cross_realm_flux(i, j, grid, time, flux_tuple[1], args...) +
    cross_realm_flux(i, j, grid, time, flux_tuple[2], args...) +
    cross_realm_flux(i, j, grid, time, flux_tuple[3], args...)

@inline cross_realm_flux(i, j, grid, time, flux_tuple::Tuple{<:Any, <:Any, <:Any, <:Any}, args...) =
    cross_realm_flux(i, j, grid, time, flux_tuple[1], args...) +
    cross_realm_flux(i, j, grid, time, flux_tuple[2], args...) +
    cross_realm_flux(i, j, grid, time, flux_tuple[3], args...) +
    cross_realm_flux(i, j, grid, time, flux_tuple[4], args...)

#####
##### Air-sea differences
#####

@inline air_sea_difference(i, j, grid, time, air, sea) = stateindex(air, i, j, 1, time) -
                                                         stateindex(sea, i, j, 1, time)

struct RelativeUVelocity end
struct RelativeVVelocity end

@inline function air_sea_difference(i, j, grid, time, ::RelativeUVelocity, atmos_state, ocean_state)
    uₐ = atmos_state.u
    uₒ = ocean_state.u
    return air_sea_difference(i, j, grid, time, uₐ, uₒ)
end

@inline function air_sea_difference(i, j, grid, time, ::RelativeVVelocity, atmos_state, ocean_state)
    vₐ = atmos_state.v
    vₒ = ocean_state.v
    return air_sea_difference(i, j, grid, time, vₐ, vₒ)
end

struct SensibleHeat end

@inline function air_sea_difference(i, j, grid, time, ::SensibleHeat, atmos_state, ocean_state)
    cₚ = stateindex(atmos_state.cₚ, i, j, 1, time)
    Tₐ = atmos_state.T
    Tₒ = ocean_state.T
    ΔT = air_sea_difference(i, j, grid, time, Tₐ, Tₒ)

    return @inbounds cₚ[i, j, 1] * ΔT
end

struct WaterVaporFraction{S}
    saturation_vapor_fraction :: S

    @doc """
        WaterVaporFraction(FT = Float64;
                               saturation_vapor_fraction = LargeYeagerSaturationVaporFraction(FT))

    """
    function WaterVaporFraction(FT = Float64;
                                    saturation_vapor_fraction = LargeYeagerSaturationVaporFraction(FT))
        S = typeof(saturation_vapor_fraction)
        return new{S}(saturation_vapor_fraction)
    end
end

struct LargeYeagerSaturationVaporFraction{FT}
    q₀ :: FT
    c₁ :: FT
    c₂ :: FT
    reference_temperature:: FT
end

"""
    LargeYeagerSaturationVaporFraction(FT = Float64;
                                    q₀ = 0.98,
                                    c₁ = 640380,
                                    c₂ = -5107.4,
                                    reference_temperature = 273.15)

"""
function LargeYeagerSaturationVaporFraction(FT = Float64;
                                         q₀ = 0.98,
                                         c₁ = 640380,
                                         c₂ = -5107.4,
                                         reference_temperature = 273.15)

    return LargeYeagerSaturationVaporFraction(convert(FT, q₀),
                                           convert(FT, c₁),
                                           convert(FT, c₂),
                                           convert(FT, reference_temperature))
end

@inline function saturation_vapor_fraction(i, j, grid, time,
                                           ratio::LargeYeagerSaturationVaporFraction,
                                           atmos_state, ocean_state)

    Tₒ = stateindex(ocean_state.T, i, j, 1, time)
    ρₐ = stateindex(atmos_state.ρ, i, j, 1, time)
    Tᵣ = ratio.reference_temperature
    q₀ = ratio.q₀
    c₁ = ratio.c₁
    c₂ = ratio.c₂

    return q₀ * c₁ * exp(-c₂ / (Tₒ + Tᵣ))
end

@inline function air_sea_difference(i, j, grid, time, diff::WaterVaporFraction, atmos_state, ocean_state)
    vapor_fraction = diff.saturation_vapor_fraction 
    qₐ = stateindex(atmos_state.q, i, j, 1, time)
    qₛ = saturation_vapor_fraction(i, j, grid, time, vapor_fraction, atmos_state, ocean_state)
    return qₐ - qₛ
end

struct LatentHeat{Q, FT}
    vapor_difference :: Q
    vaporization_enthalpy :: FT
end

"""
    LatentHeat(FT = Float64;
               vaporization_enthalpy = 2.5e3 # J / g
               vapor_difference = WaterVaporFraction(FT))

"""
function LatentHeat(FT = Float64;
                    vaporization_enthalpy = 2.5e3, # J / g
                    vapor_difference = WaterVaporFraction(FT))

    vaporization_enthalpy = convert(FT, vaporization_enthalpy)
    return LatentHeat(vapor_difference, vaporization_enthalpy)
end

@inline function air_sea_difference(i, j, grid, time, diff::LatentHeat, atmos, ocean)
    Δq = air_sea_difference(i, j, grid, time, diff.vapor_difference, atmos, ocean)
    Λᵥ = diff.vaporization_enthalpy
    return Λᵥ * Δq
end

#####
##### Bulk velocity scales
#####

struct RelativeVelocityScale end
# struct AtmosphereOnlyVelocityScale end

@inline function bulk_velocity_scaleᶠᶜᶜ(i, j, grid, time, ::RelativeVelocityScale, atmos_state, ocean_state)
    uₐ = atmos_state.u
    vₐ = atmos_state.v
    uₒ = ocean_state.u
    vₒ = ocean_state.v
    Δu = stateindex(uₐ, i, j, 1, time) - stateindex(uₒ, i, j, 1, time)
    Δv² = ℑxyᶠᶜᵃ(i, j, 1, grid, Δϕt², vₐ, vₒ, time)
    return sqrt(Δu^2 + Δv²)
end

@inline function bulk_velocity_scaleᶜᶠᶜ(i, j, grid, time, ::RelativeVelocityScale, atmos_state, ocean_state)
    uₐ = atmos_state.u
    vₐ = atmos_state.v
    uₒ = ocean_state.u
    vₒ = ocean_state.v
    Δu² = ℑxyᶜᶠᵃ(i, j, 1, grid, Δϕt², uₐ, uₒ, time)
    Δv = stateindex(vₐ, i, j, 1, time) - stateindex(vₒ, i, j, 1, time)
    return sqrt(Δu² + Δv^2)
end

@inline function bulk_velocity_scaleᶜᶜᶜ(i, j, grid, time, ::RelativeVelocityScale, atmos_state, ocean_state)
    uₐ = atmos_state.u
    vₐ = atmos_state.v
    uₒ = ocean_state.u
    vₒ = ocean_state.v
    Δu² = ℑxᶜᵃᵃ(i, j, 1, grid, Δϕt², uₐ, uₒ, time)
    Δv² = ℑyᵃᶜᵃ(i, j, 1, grid, Δϕt², vₐ, vₒ, time)
    return sqrt(Δu² + Δv²)
end

