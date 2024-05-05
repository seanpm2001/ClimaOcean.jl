module ECCO4

export ECCOMetadata, ecco4_field, ecco4_center_mask, adjusted_ecco_tracers, initialize!

using ClimaOcean.DataWrangling: inpaint_mask!
using ClimaOcean.InitialConditions: three_dimensional_regrid!, interpolate!

using Oceananigans
using Oceananigans.Architectures: architecture, child_architecture
using Oceananigans.BoundaryConditions
using Oceananigans.DistributedComputations: DistributedField, all_reduce, barrier!
using Oceananigans.Utils
using KernelAbstractions: @kernel, @index
using NCDatasets
using Downloads: download
using Dates

import Oceananigans.Fields: set!

# Ecco field used to set model's initial conditions
struct ECCOMetadata
    name  :: Symbol
    year  :: Int
    month :: Int
    day   :: Int
end

const ECCO_Nx = 720
const ECCO_Ny = 360
const ECCO_Nz = 50

# Vertical coordinate
const ECCO_z = [
    -6128.75,
    -5683.75,
    -5250.25,
    -4839.75,
    -4452.25,
    -4087.75,
    -3746.25,
    -3427.75,
    -3132.25,
    -2859.75,
    -2610.25,
    -2383.74,
    -2180.13,
    -1999.09,
    -1839.64,
    -1699.66,
    -1575.64,
    -1463.12,
    -1357.68,
    -1255.87,
    -1155.72,
    -1056.53,
    -958.45,
    -862.10,
    -768.43,
    -678.57,
    -593.72,
    -515.09,
    -443.70,
    -380.30,
    -325.30,
    -278.70,
    -240.09,
    -208.72,
    -183.57,
    -163.43,
    -147.11,
    -133.45,
    -121.51,
    -110.59,
    -100.20,
    -90.06,
    -80.01,
    -70.0,
    -60.0,
    -50.0,
    -40.0,
    -30.0,
    -20.0,
    -10.0,
      0.0,
]

unprocessed_ecco4_file_prefix = Dict(
    :temperature           => ("OCEAN_TEMPERATURE_SALINITY_day_mean_", "_ECCO_V4r4_latlon_0p50deg.nc"),
    :salinity              => ("OCEAN_TEMPERATURE_SALINITY_day_mean_", "_ECCO_V4r4_latlon_0p50deg.nc"),
)

# We only have 1992 at the moment
ECCOMetadata(name::Symbol) = ECCOMetadata(name, 1992, 1, 2)

function ECCOMetadata(name::Symbol, date::DateTimeAllLeap) 
    year  = Dates.year(date)
    month = Dates.month(date)
    day   = Dates.day(date)

    return ECCOMetadata(name, year, month, day)
end

date(data::ECCOMetadata) = DateTimeAllLeap(data.year, data.month, data.day)

function ecco4_filename(metadata::ECCOMetadata)
    variable_name = metadata.name
    prefix, postfix = unprocessed_ecco4_file_prefix[variable_name]

    yearstr  = string(year)
    monthstr = string(month, pad=2)
    daystr   = string(day, pad=2) 
    datestr  = "$(yearstr)-$(monthstr)-$(daystr)"
    filename = prefix * datestr * postfix

    return filename
end

filename(data::ECCOMetadata) = "ecco4_" * string(data.name) * "_$(data.year)$(data.month)$(data.day).nc"

variable_is_three_dimensional = Dict(
    :temperature             => true,
    :salinity                => true,
    :u_velocity              => true,
    :v_velocity              => true,
    :sea_ice_thickness       => false,
    :sea_ice_area_fraction   => false,
)

ecco4_short_names = Dict(
    :temperature           => "THETA",
    :salinity              => "SALT",
    :u_velocity            => "UVEL",
    :v_velocity            => "VVEL",
    :sea_ice_thickness     => "SIheff",
    :sea_ice_area_fraction => "SIarea"
)

ecco4_location = Dict(
    :temperature           => (Center, Center, Center),
    :salinity              => (Center, Center, Center),
    :sea_ice_thickness     => (Center, Center, Nothing),
    :sea_ice_area_fraction => (Center, Center, Nothing),
    :u_velocity            => (Face,   Center, Center),
    :v_velocity            => (Center, Face,   Center),
)

ecco4_remote_folder = Dict(
    :temperature           => "ECCO_L4_TEMP_SALINITY_05DEG_DAILY_V4R4"
    :salinity              => "ECCO_L4_TEMP_SALINITY_05DEG_DAILY_V4R4"
    :sea_ice_thickness     => (Center, Center, Nothing),
    :sea_ice_area_fraction => (Center, Center, Nothing),
    :u_velocity            => (Face,   Center, Center),
    :v_velocity            => (Center, Face,   Center),
)

surface_variable(variable_name) = variable_name == :sea_ice_thickness

function empty_ecco4_field(metadata::ECCOMetadata; kw...)
    variable_name = metadata.name
    return empty_ecco4_field(variable_name; kw...)
end

function empty_ecco4_field(variable_name::Symbol;
                           Nx = ECCO_Nx,
                           Ny = ECCO_Ny,
                           Nz = ECCO_Nz,
                           z_faces = ECCO_z,
                           architecture = CPU(), 
                           horizontal_halo = (3, 3))


    location = ecco4_location[variable_name]

    longitude = (0, 360)
    latitude = (-90, 90)
    TX, TY = (Periodic, Bounded)

    if variable_is_three_dimensional[variable_name] 
        z    = z_faces
        # add vertical halo for 3D fields
        halo = (horizontal_halo..., 3)
        LZ   = Center
        TZ   = Bounded
        N    = (Nx, Ny, Nz)
    else
        z    = nothing
        halo = horizontal_halo
        LZ   = Nothing
        TZ   = Flat
        N    = (Nx, Ny)
    end

    # Flat in z if the variable is two-dimensional
    grid = LatitudeLongitudeGrid(architecture; halo, size = N, topology = (TX, TY, TZ),
                                 longitude, latitude, z)

    return Field{location...}(grid)
end

"""
    ecco4_field(variable_name;
                architecture = CPU(),
                horizontal_halo = (1, 1),
                user_data = nothing,
                url = ecco4_urls[variable_name],
                filename = ecco4_file_names[variable_name],
                short_name = ecco4_short_names[variable_name])

Retrieve the ecco4 field corresponding to `variable_name`. 
The data is either:
(1) retrieved from `filename`,
(2) dowloaded from `url` if `filename` does not exists,
(3) filled from `user_data` if `user_data` is provided.
"""
function ecco4_field(metadata::ECCOMetadata;
                     architecture = CPU(),
                     horizontal_halo = (3, 3),
                     user_data = nothing,
                     filename = ecco4_filename(metadata),
                     remote_folder = ecco4_remote_folder[metadata.name])

    variable_name = metadata.name
    short_name = ecco4_short_names[variable_name]
    
    if !isfile(filename) 
        cmd = `podaac-data-downloader -c $(remote_folder) -d ./ --start-date $(datestr)T00:00:00Z --end-date $(datestr)T00:00:00Z -e .nc`
        @info "downloading $(filename) from $(remote_folder)"
        run(cmd)
    end

    if user_data isa Nothing
        ds = Dataset(filename)
        if variable_is_three_dimensional[variable_name] 
            data = ds[short_name][:, :, :, 1]
            # The surface layer in three-dimensional ECCO fields is at `k = 1`
            data = reverse(data, dims = 3)
        else
            data = ds[short_name][:, :, 1]
        end        
        close(ds)
    else
        data = user_data
    end

    field = empty_ecco4_field(metadata; architecture, horizontal_halo)
    FT    = eltype(field)
    data[ismissing.(data)] .= 1e10 # Artificially large number!
    data  = if location(field)[2] == Face
        new_data = zeros(FT, size(field))
        new_data[:, 1:end-1, :] .= data
        new_data    
    else
        convert.(FT, data)
    end

    set!(field, data)
    fill_halo_regions!(field)

    return field
end

@kernel function _set_ecco4_mask!(mask, Tᵢ, minimum_value, maximum_value)
    i, j, k = @index(Global, NTuple)
    @inbounds mask[i, j, k] = (Tᵢ[i, j, k] < minimum_value) | (Tᵢ[i, j, k] > maximum_value) 
end

"""
    ecco4_center_mask(architecture = CPU(); minimum_value = Float32(-1e5))

A boolean field where `false` represents a missing value in the ECCO :temperature dataset.
"""
function ecco4_center_mask(architecture = CPU(); 
                           minimum_value = Float32(-1e5),
                           maximum_value = Float32(1e5),
                           filename = ecco4_file_names[:temperature])

    Tᵢ   = ecco4_field(:temperature; architecture, filename)
    mask = CenterField(Tᵢ.grid, Bool)

    # Set the mask with ones where T is defined
    launch!(architecture, Tᵢ.grid, :xyz, _set_ecco4_mask!, mask, Tᵢ, minimum_value, maximum_value)

    return mask
end

"""
    inpainted_ecco4_field(variable_name; 
                          architecture = CPU(),
                          filename = "./inpainted_ecco4_fields.nc",
                          mask = ecco4_center_mask(architecture))
    
Retrieve the ECCO field corresponding to `variable_name` inpainted to fill all the
missing values in the original dataset.

Arguments:
==========

- `variable_name`: the variable name corresponding to the Dataset.

Keyword Arguments:
==================

- `architecture`: either `CPU()` or `GPU()`.

- `filename`: the path where to retrieve the data from. If the file does not exist,
              the data will be retrived from the ECCO dataset, inpainted, and
              saved to `filename`.

- `mask`: the mask used to inpaint the field (see `inpaint_mask!`).
"""
function inpainted_ecco4_field(metadata::ECCOMetadata; 
                               architecture = CPU(),
                               inpainted_filename = nothing,
                               filename =  ecco4_file_names[metadata.name],
                               mask = ecco4_center_mask(architecture; filename),
                               maxiter = Inf,
                               kw...)
    
    if isnothing(inpainted_filename)
        f = ecco4_field(metadata; architecture, filename, kw...)
        
        # Make sure all values are extended properly
        @info "In-painting ecco $(metadata.name)"
        inpaint_mask!(f, mask; maxiter)

        fill_halo_regions!(f)

    elseif !isfile(inpainted_filename)
        f = ecco4_field(metadata; architecture, filename, kw...)
        
        # Make sure all values are extended properly
        @info "In-painting ecco $(metadata.name) and saving it in $filename"
        inpaint_mask!(f, mask; maxiter)

        fill_halo_regions!(f)

        ds = Dataset(inpainted_filename, "c")
        defVar(ds, string(metadata.name), Array(interior(f)), ("lat", "lon", "z"))

        close(ds)

    else
        ds = Dataset(inpainted_filename, "a")

        if haskey(ds, string(metadata.name))
            data = ds[metadata.name][:, :, :]
            f = ecco4_field(metadata; architecture, filename, user_data = data, kw...)
            fill_halo_regions!(f)
        else
            f = ecco4_field(metadata; architecture, kw...)
            # Make sure all values are inpainted properly
            @info "In-painting ecco $(metadata.name) and saving it in $filename"
            inpaint_mask!(f, mask; maxiter)
            fill_halo_regions!(f)

            defVar(ds, string(metadata.name), Array(interior(f)), ("lat", "lon", "z"))
        end

        close(ds)
    end

    return f
end

function set!(field::DistributedField, ecco4_metadata::ECCOMetadata; filename="./inpainted_ecco4_fields.nc", kw...)
    # Fields initialized from ECCO
    grid = field.grid
    arch = architecture(grid)
    child_arch = child_architecture(arch)
    name = ecco4_metadata.name

    f_ecco = if arch.local_rank == 0 # Make sure we read/write the file using only one core
        mask = ecco4_center_mask(child_arch)
        
        inpainted_ecco4_field(name; filename, mask,
                                  architecture = child_arch,
                                  kw...)
    else
        empty_ecco4_field(ecco4_metadata; architecture = child_arch)
    end

    barrier!(arch)

    # Distribute ecco field to all workers
    parent(f_ecco) .= all_reduce(+, parent(f_ecco), arch)

    f_grid = Field(ecco4_location[name], grid)   
    interpolate!(f_grid, f_ecco)
    set!(field, f_grid)
    
    return field
end

function set!(field::Field, ecco4_metadata::ECCOMetadata; filename="./inpainted_ecco4_fields.nc", kw...)

    # Fields initialized from ECCO
    grid = field.grid
    name = ecco4_metadata.name

    mask = ecco4_center_mask(architecture(grid))
    
    f = inpainted_ecco4_field(name; filename, mask,
                              architecture = architecture(grid),
                              kw...)

    f_grid = Field(ecco4_location[name], grid)   
    interpolate!(f_grid, f)
    set!(field, f_grid)

    return field
end

include("ECCO4_climatology.jl")

end # module



