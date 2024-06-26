module ENVPack

using Pkg, TOML, RegistryTools
using Pkg.Types
using Pkg: PlatformEngines, MiniProgressBars
using UUIDs: uuid4
using Dates
const TARGET_ARCH = "x86_64"
const TARGET_OS = "windows"

juliatempdir() = joinpath(homedir(), ".envpack\\.julia")

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

function get_missing_deps(might_missing, registed, packages)
    weakenv = Set{String}()
    idir = joinpath(Pkg.depots1(), "registries", "General")
    for uuid in might_missing
        for file in ("WeakDeps.toml", "Deps.toml")
            depsfile = joinpath(idir, packages[uuid]["path"], file)
            isfile(depsfile) || continue
            deps = TOML.parsefile(depsfile)
            for subdeps in values(deps), dep in values(subdeps)
                is_stdlib(UUID(dep)) || 
                haskey(registed, dep) ||
                push!(weakenv, dep)
            end
        end
    end
    weakenv
end

function handle_registries(ienv::Set{PackageSpec})
    env = Set(PackageSpec(;name = e.name, uuid = e.uuid, url = e.url, path = e.path) for e in ienv)
    idir = joinpath(Pkg.depots1(), "registries", "General")
    odir = joinpath(juliatempdir(), "registries", "MiniGeneral")
    packages = TOML.parsefile(joinpath(idir, "Registry.toml"))["packages"]
    registry_data = RegistryTools.RegistryData("MinimumEnv", uuid4())
    registed = registry_data.packages
    for pkg in env
        (is_stdlib(pkg.uuid) || pkg.url !== nothing || pkg.path !== nothing) && continue
        let uuid = string(pkg.uuid)
            pkgdata = packages[uuid]
            registed[uuid] = pkgdata
            symlink(joinpath.((idir, odir), pkgdata["path"])...)
        end
    end
    # `MiniGeneral` must contain Deps/WeakDeps to work correctly
    # TODO: ideally a stale dependence should be excluded from Deps.jl
    weakenv = get_missing_deps(keys(registed), registed, packages)
    while true
        isempty(weakenv) && break
        for uuid in weakenv
            pkgdata = packages[uuid]
            registry_data.packages[uuid] = pkgdata
            symlink(joinpath.((idir, odir), pkgdata["path"])...)
        end
        weakenv = get_missing_deps(weakenv, registed, packages)
    end
    RegistryTools.write_registry(joinpath(odir, "Registry.toml"), registry_data)
end

function handle_package(env::Set{PackageSpec})
    history = joinpath(homedir(), ".envpack", "history.toml")
    oldlog = if isfile(history)
        TOML.parsefile(history)
    else
        Dict{String, Any}("packages" => Dict{String, Any}(), "artifacts" => [])
    end
    log = copy(oldlog)
    downs = Any[]
    for (;name, uuid, tree_hash, url, path) in env
        is_stdlib(uuid) && continue
        if path === nothing
            slug = Base.version_slug(uuid, tree_hash)
            ppath = joinpath("packages", name, slug)
            if !haskey(oldlog["packages"], name) || !in(slug, oldlog["packages"][name])
                src = joinpath(Pkg.depots1(), ppath)
                dst = joinpath(juliatempdir(), ppath)
                symlink(src, dst)
                push!(get!(Vector{Any}, log["packages"], name), slug)
            end
        else
            src = path
            dst = joinpath(juliatempdir(), "dev", name)
            symlink(src, dst)
        end
        if path === nothing
            isjll = endswith(name, "_jll")
            if isjll
                @assert(url === nothing && path === nothing)
            end            
            slug = Base.version_slug(uuid, tree_hash)
            arfname = joinpath(Pkg.depots1(), "packages", name, slug, "Artifacts.toml")
            if isjll || isfile(arfname)
                if !isjll
                    @warn "$name has artifacts!\n"
                end
                arfs = arfname |> TOML.parsefile |> values |> only
                if arfs isa Dict{String, Any}
                    arfs = [arfs]
                end
                valid_arfs = Iterators.filter(arfs) do src
                    get(src, "arch", TARGET_ARCH) == TARGET_ARCH &&
                    get(src, "os", TARGET_OS) == TARGET_OS
                end
                for arf in valid_arfs
                    sha = arf["git-tree-sha1"]
                    sha in oldlog["artifacts"] && continue
                    src = joinpath(Pkg.depots1(), "artifacts", sha)
                    dst = joinpath(juliatempdir(), "artifacts", sha)
                    push!(log["artifacts"], sha)
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
    log
end

function pack_env(srcenvs::Vector{String} = ["@v1.11",]; update_history = false)
    rm(juliatempdir(); force = true, recursive = true)
    env = Set{PackageSpec}()
    for srcenv in srcenvs
        if isdir(srcenv)
            srcenv_path = srcenv
            desenv_path = joinpath(juliatempdir(), "environments", split(srcenv, '\\')[end])
        elseif srcenv[1] == '@'
            srcenv_path = joinpath(Pkg.depots1(), "environments", srcenv[2:end])
            desenv_path = joinpath(juliatempdir(), "environments", srcenv[2:end])
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
    log = handle_package(env)
    # pack_env
    zip_path = joinpath(homedir(), ".envpack", "packed")
    rm(zip_path, force=true, recursive=true)
    run(pipeline(`$(PlatformEngines.exe7z()) a -tzip -v256m -mx5 -mmt16 $(joinpath(zip_path, "output")) $(juliatempdir())`))
    # history
    if update_history
        history = joinpath(homedir(), ".envpack", "history.toml")
        if isfile(history)
            newfile = "history-$(now()).toml"
            newfile = replace(newfile, ':'=>'_')
            to = joinpath(homedir(), ".envpack", "old-history")
            mkpath(to)
            mv(history, joinpath(to, newfile))
        end
        open(history, "w") do io
            TOML.print(io, log)
        end
    end
end

end
