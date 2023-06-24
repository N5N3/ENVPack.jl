module ENVPack

using Pkg, TOML, RegistryTools
using Pkg.Types
using Pkg: PlatformEngines, MiniProgressBars
using UUIDs: uuid4
const TARGET_ARCH = "x86_64"
const TARGET_OS = "windows"

outputdir() = joinpath(homedir(), ".envpack\\.julia")

function symlink(target, link)
    @assert isdir(target)
    @assert link[end] != '\\' || link[end] != '/'
    if isdir(link)
        @warn "$link already exists!"
        return
    end
    mkpath(dirname(link))
    Base.symlink(target, link)
end

read_whole_env(manifest_path::String) = read_whole_env!(Set{PackageSpec}(), manifest_path)
function read_whole_env!(all_env::Set{PackageSpec}, manifest_path::String)
    src = read_manifest(manifest_path).deps
    for (uuid, pkgentry) in src
        (;name, version, tree_hash, path, repo) = pkgentry
        url = repo.source
        push!(all_env, PackageSpec(;name, uuid, version, tree_hash, url, path))
    end
    all_env
end

function handle_registries(ienv::Set{PackageSpec})
    env = Set(PackageSpec(;name = e.name, uuid = e.uuid, url = e.url, path = e.path) for e in ienv)
    idir = joinpath(Pkg.depots1(), "registries", "General")
    odir = joinpath(outputdir(), "registries", "MinimumEnv")
    packages = TOML.parsefile(joinpath(idir, "Registry.toml"))["packages"]
    registry_data = RegistryTools.RegistryData("MinimumEnv", uuid4())
    for pkg in env
        (is_stdlib(pkg.uuid) || pkg.url !== nothing || pkg.path !== nothing) && continue
        let uuid = string(pkg.uuid), pkgdata = packages[uuid]
            registry_data.packages[uuid] = pkgdata
            symlink(joinpath.((idir, odir), pkgdata["path"])...)
        end
    end
    RegistryTools.write_registry(joinpath(odir, "Registry.toml"), registry_data)
end

function handle_package(env::Set{PackageSpec})
    downs = Any[]
    for (;name, uuid, tree_hash, url, path) in env
        is_stdlib(uuid) && continue
        if path === nothing
            slug = Base.version_slug(uuid, tree_hash)
            ppath = joinpath("packages", name, slug)
            src = joinpath(Pkg.depots1(), ppath)
            dst = joinpath(outputdir(), ppath)
        else
            src = path
            dst = joinpath(outputdir(), "dev", name)
        end
        symlink(src, dst)
        if endswith(name, "_jll")
            @assert(url === nothing && path === nothing)
            slug = Base.version_slug(uuid, tree_hash)
            arfs = joinpath(Pkg.depots1(), "packages", name, slug, "Artifacts.toml") |> TOML.parsefile |> values |> only
            valid_arfs = Iterators.filter(arfs) do src
                get(src, "arch", TARGET_ARCH) == TARGET_ARCH &&
                get(src, "os", TARGET_OS) == TARGET_OS
            end
            for arf in valid_arfs
                src = joinpath(Pkg.depots1(), "artifacts", arf["git-tree-sha1"])
                dst = joinpath(outputdir(), "artifacts", arf["git-tree-sha1"])
                if isdir(src)
                    symlink(src, dst)
                else
                    @assert !isdir(dst)
                    down = only(arf["download"])
                    mkpath(dirname(dst))
                    push!(downs, (down["url"], down["sha256"], dst))
                end
            end
        end
    end
    if !isempty(downs)
        printstyled("Start downloading missing ", length(downs), " artifacts:\n"; color=:blue)
        prog = MiniProgressBars.MiniProgressBar(;max = length(downs), color = :blue)
        MiniProgressBars.start_progress(stdout, prog)
        for i in eachindex(downs)
            PlatformEngines.download_verify_unpack(downs[i]...; quiet_download = true)
            prog.current = i
            MiniProgressBars.show_progress(stdout, prog)
        end
        MiniProgressBars.end_progress(stdout, prog)
        printstyled("Artifacts ready!\n"; color=:green)
    end
end

function pack_env(srcenvs::Vector{String} = ["@v1.10",])
    rm(outputdir(); force = true, recursive = true)
    env = Set{PackageSpec}()
    for srcenv in srcenvs
        if isdir(srcenv)
            srcenv_path = srcenv
            desenv_path = joinpath(outputdir(), "environments", split(srcenv, '\\')[end])
        elseif srcenv[1] == '@'
            srcenv_path = joinpath(Pkg.depots1(), "environments", srcenv[2:end])
            desenv_path = joinpath(outputdir(), "environments", srcenv[2:end])
        else
            error("unresolvable env name!")
        end
        isdir(srcenv_path) || error("unresolvable env name!")
        manifest_path = joinpath(srcenv_path, "Manifest.toml")
        project_path = joinpath(srcenv_path, "Project.toml")
        (isfile(manifest_path) && isfile(project_path)) || error("invalid env path!")
        symlink(srcenv_path, desenv_path)
        read_whole_env!(env, manifest_path)
    end
    handle_registries(env)
    handle_package(env)
end

end
