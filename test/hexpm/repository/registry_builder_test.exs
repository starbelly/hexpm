defmodule Hexpm.Organization.RegistryBuilderTest do
  use Hexpm.DataCase

  alias Hexpm.Repository.{RegistryBuilder, Repository}

  @checksum "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"

  setup do
    packages =
      [p1, p2, p3] =
      insert_list(3, :package)
      |> Hexpm.Repo.preload(:repository)

    r1 = insert(:release, package: p1, version: "0.0.1")
    r2 = insert(:release, package: p2, version: "0.0.1")
    r3 = insert(:release, package: p2, version: "0.0.2")
    r4 = insert(:release, package: p3, version: "0.0.2")

    insert(:requirement, release: r3, requirement: "0.0.1", dependency: p1, app: p1.name)
    insert(:requirement, release: r4, requirement: "~> 0.0.1", dependency: p2, app: p2.name)
    insert(:requirement, release: r4, requirement: "0.0.1", dependency: p1, app: p1.name)

    insert(:install, hex: "0.0.1", elixirs: ["1.0.0"])
    insert(:install, hex: "0.1.0", elixirs: ["1.1.0", "1.1.1"])

    %{packages: packages, releases: [r1, r2, r3, r4]}
  end

  defp open_table(repo \\ nil) do
    path = if repo, do: "repos/#{repo}/registry.ets.gz", else: "registry.ets.gz"

    if contents = Hexpm.Store.get(:repo_bucket, path, []) do
      contents = :zlib.gunzip(contents)
      path = Path.join(Application.get_env(:hexpm, :tmp_dir), "registry_builder_test.ets")
      File.write!(path, contents)
      {:ok, tid} = :ets.file2tab(String.to_charlist(path))
      tid
    end
  end

  defp v2_map(path, args) when is_list(args) do
    nonrepo_path = Regex.replace(~r"^repos/\w+/", path, "")

    if contents = Hexpm.Store.get(:repo_bucket, path, []) do
      public_key = Application.fetch_env!(:hexpm, :public_key)
      {:ok, payload} = :hex_registry.decode_and_verify_signed(:zlib.gunzip(contents), public_key)
      fun = path_to_decoder(nonrepo_path)
      {:ok, decoded} = apply(fun, [payload | args])
      decoded
    end
  end

  defp path_to_decoder("names"), do: &:hex_registry.decode_names/2
  defp path_to_decoder("versions"), do: &:hex_registry.decode_versions/2
  defp path_to_decoder("packages/" <> _), do: &:hex_registry.decode_package/3

  describe "full/0" do
    test "ets registry is in correct format", %{packages: [p1, p2, p3]} do
      RegistryBuilder.full(Repository.hexpm())
      tid = open_table()

      assert :ets.lookup(tid, :"$$version$$") == [{:"$$version$$", 4}]

      assert length(:ets.match_object(tid, :_)) == 9
      assert :ets.lookup(tid, p2.name) == [{p2.name, [["0.0.1", "0.0.2"]]}]

      assert :ets.lookup(tid, {p2.name, "0.0.1"}) == [
               {{p2.name, "0.0.1"}, [[], @checksum, ["mix"]]}
             ]

      assert :ets.lookup(tid, p3.name) == [{p3.name, [["0.0.2"]]}]

      requirements =
        :ets.lookup(tid, {p3.name, "0.0.2"}) |> List.first() |> elem(1) |> List.first()

      assert length(requirements) == 2
      assert Enum.find(requirements, &(&1 == [p2.name, "~> 0.0.1", false, p2.name]))
      assert Enum.find(requirements, &(&1 == [p1.name, "0.0.1", false, p1.name]))

      assert [] = :ets.lookup(tid, "non_existant")
    end

    test "ets registry is uploaded alongside signature" do
      RegistryBuilder.full(Repository.hexpm())

      registry = Hexpm.Store.get(:repo_bucket, "registry.ets.gz", [])
      signature = Hexpm.Store.get(:repo_bucket, "registry.ets.gz.signed", [])

      public_key = Application.fetch_env!(:hexpm, :public_key)
      signature = Base.decode16!(signature, case: :lower)
      assert :hex_registry.verify(registry, signature, public_key)
    end

    test "v2 registry is in correct format", %{packages: [p1, p2, p3] = packages} do
      RegistryBuilder.full(Repository.hexpm())
      first = packages |> Enum.map(& &1.name) |> Enum.sort() |> List.first()

      names = v2_map("names", ["hexpm"])
      assert length(names) == 3
      assert List.first(names) == %{name: first}

      versions = v2_map("versions", ["hexpm"])
      assert length(versions) == 3

      assert Enum.find(versions, &(&1.name == p2.name)) == %{
               name: p2.name,
               versions: ["0.0.1", "0.0.2"],
               retired: []
             }

      package2_releases = v2_map("packages/#{p2.name}", ["hexpm", p2.name])
      assert length(package2_releases) == 2

      assert List.first(package2_releases) == %{
               version: "0.0.1",
               inner_checksum: Base.decode16!(@checksum),
               outer_checksum: Base.decode16!(@checksum),
               dependencies: []
             }

      package3_releases = v2_map("packages/#{p3.name}", ["hexpm", p3.name])
      assert [%{version: "0.0.2", dependencies: deps}] = package3_releases
      assert length(deps) == 2
      assert %{package: p2.name, requirement: "~> 0.0.1"} in deps
      assert %{package: p1.name, requirement: "0.0.1"} in deps
    end

    test "remove package", %{packages: [p1, p2, p3], releases: [_, _, _, r4]} do
      RegistryBuilder.full(Repository.hexpm())

      Hexpm.Repo.delete!(r4)
      Hexpm.Repo.delete!(p3)
      RegistryBuilder.full(Repository.hexpm())

      assert length(v2_map("names", ["hexpm"])) == 2
      assert v2_map("packages/#{p1.name}", ["hexpm", p1.name])
      assert v2_map("packages/#{p2.name}", ["hexpm", p2.name])
      refute v2_map("packages/#{p3.name}", ["hexpm", p3.name])
    end

    test "registry builds for multiple repositories" do
      repository = insert(:repository)
      package = insert(:package, repository_id: repository.id, repository: repository)
      insert(:release, package: package, version: "0.0.1")
      RegistryBuilder.full(repository)

      refute open_table(repository.name)

      names = v2_map("repos/#{repository.name}/names", [repository.name])
      assert length(names) == 1

      versions = v2_map("repos/#{repository.name}/versions", [repository.name])
      assert length(versions) == 1

      releases =
        v2_map("repos/#{repository.name}/packages/#{package.name}", [
          repository.name,
          package.name
        ])

      assert length(releases) == 1
    end
  end

  describe "v1_and_v2_repository/1" do
    test "ets registry is in correct format", %{packages: [p1, p2, p3]} do
      RegistryBuilder.v1_and_v2_repository(Repository.hexpm())
      tid = open_table()

      assert :ets.lookup(tid, :"$$version$$") == [{:"$$version$$", 4}]

      assert length(:ets.match_object(tid, :_)) == 9
      assert :ets.lookup(tid, p2.name) == [{p2.name, [["0.0.1", "0.0.2"]]}]

      assert :ets.lookup(tid, {p2.name, "0.0.1"}) == [
               {{p2.name, "0.0.1"}, [[], @checksum, ["mix"]]}
             ]

      assert :ets.lookup(tid, p3.name) == [{p3.name, [["0.0.2"]]}]

      requirements =
        :ets.lookup(tid, {p3.name, "0.0.2"}) |> List.first() |> elem(1) |> List.first()

      assert length(requirements) == 2
      assert Enum.find(requirements, &(&1 == [p2.name, "~> 0.0.1", false, p2.name]))
      assert Enum.find(requirements, &(&1 == [p1.name, "0.0.1", false, p1.name]))

      assert [] = :ets.lookup(tid, "non_existant")
    end

    test "ets registry is uploaded alongside signature" do
      RegistryBuilder.v1_and_v2_repository(Repository.hexpm())

      registry = Hexpm.Store.get(:repo_bucket, "registry.ets.gz", [])
      signature = Hexpm.Store.get(:repo_bucket, "registry.ets.gz.signed", [])

      public_key = Application.fetch_env!(:hexpm, :public_key)
      signature = Base.decode16!(signature, case: :lower)
      assert :hex_registry.verify(registry, signature, public_key)
    end

    test "v2 registry is in correct format", %{packages: [_, p2, _] = packages} do
      RegistryBuilder.v1_and_v2_repository(Repository.hexpm())
      first = packages |> Enum.map(& &1.name) |> Enum.sort() |> List.first()

      names = v2_map("names", ["hexpm"])
      assert length(names) == 3
      assert List.first(names) == %{name: first}

      versions = v2_map("versions", ["hexpm"])
      assert length(versions) == 3

      assert Enum.find(versions, &(&1.name == p2.name)) == %{
               name: p2.name,
               versions: ["0.0.1", "0.0.2"],
               retired: []
             }
    end

    test "remove package", %{packages: [_, _, p3], releases: [_, _, _, r4]} do
      RegistryBuilder.v1_and_v2_repository(Repository.hexpm())

      Hexpm.Repo.delete!(r4)
      Hexpm.Repo.delete!(p3)
      RegistryBuilder.v1_and_v2_repository(Repository.hexpm())

      assert length(v2_map("names", ["hexpm"])) == 2
    end

    test "registry builds for multiple repositories" do
      repository = insert(:repository)
      package = insert(:package, repository_id: repository.id, repository: repository)
      insert(:release, package: package, version: "0.0.1")
      RegistryBuilder.v1_and_v2_repository(repository)

      refute open_table(repository.name)

      names = v2_map("repos/#{repository.name}/names", [repository.name])
      assert length(names) == 1

      versions = v2_map("repos/#{repository.name}/versions", [repository.name])
      assert length(versions) == 1
    end
  end

  describe "v1_repository/1" do
    test "ets registry is in correct format", %{packages: [p1, p2, p3]} do
      RegistryBuilder.v1_repository(Repository.hexpm())
      tid = open_table()

      assert :ets.lookup(tid, :"$$version$$") == [{:"$$version$$", 4}]

      assert length(:ets.match_object(tid, :_)) == 9
      assert :ets.lookup(tid, p2.name) == [{p2.name, [["0.0.1", "0.0.2"]]}]

      assert :ets.lookup(tid, {p2.name, "0.0.1"}) == [
               {{p2.name, "0.0.1"}, [[], @checksum, ["mix"]]}
             ]

      assert :ets.lookup(tid, p3.name) == [{p3.name, [["0.0.2"]]}]

      requirements =
        :ets.lookup(tid, {p3.name, "0.0.2"}) |> List.first() |> elem(1) |> List.first()

      assert length(requirements) == 2
      assert Enum.find(requirements, &(&1 == [p2.name, "~> 0.0.1", false, p2.name]))
      assert Enum.find(requirements, &(&1 == [p1.name, "0.0.1", false, p1.name]))

      assert [] = :ets.lookup(tid, "non_existant")
    end

    test "ets registry is uploaded alongside signature" do
      RegistryBuilder.v1_repository(Repository.hexpm())

      registry = Hexpm.Store.get(:repo_bucket, "registry.ets.gz", [])
      signature = Hexpm.Store.get(:repo_bucket, "registry.ets.gz.signed", [])

      public_key = Application.fetch_env!(:hexpm, :public_key)
      signature = Base.decode16!(signature, case: :lower)
      assert :hex_registry.verify(registry, signature, public_key)
    end
  end

  describe "v2_repository/1" do
    test "v2 registry is in correct format", %{packages: [_, p2, _] = packages} do
      RegistryBuilder.v2_repository(Repository.hexpm())
      first = packages |> Enum.map(& &1.name) |> Enum.sort() |> List.first()

      names = v2_map("names", ["hexpm"])
      assert length(names) == 3
      assert List.first(names) == %{name: first}

      versions = v2_map("versions", ["hexpm"])
      assert length(versions) == 3

      assert Enum.find(versions, &(&1.name == p2.name)) == %{
               name: p2.name,
               versions: ["0.0.1", "0.0.2"],
               retired: []
             }

      refute open_table("hexpm")
    end

    test "remove package", %{packages: [_, _, p3], releases: [_, _, _, r4]} do
      RegistryBuilder.v2_repository(Repository.hexpm())

      Hexpm.Repo.delete!(r4)
      Hexpm.Repo.delete!(p3)
      RegistryBuilder.v2_repository(Repository.hexpm())

      assert length(v2_map("names", ["hexpm"])) == 2
    end

    test "registry builds for multiple repositories" do
      repository = insert(:repository)
      package = insert(:package, repository_id: repository.id, repository: repository)
      insert(:release, package: package, version: "0.0.1")
      RegistryBuilder.v2_repository(repository)

      names = v2_map("repos/#{repository.name}/names", [repository.name])
      assert length(names) == 1

      versions = v2_map("repos/#{repository.name}/versions", [repository.name])
      assert length(versions) == 1
    end
  end

  describe "v2_package/1" do
    test "v2 registry is in correct format", %{packages: [p1, p2, p3]} do
      RegistryBuilder.v2_package(p2)
      RegistryBuilder.v2_package(p3)

      package2_releases = v2_map("packages/#{p2.name}", ["hexpm", p2.name])
      assert length(package2_releases) == 2

      assert List.first(package2_releases) == %{
               version: "0.0.1",
               inner_checksum: Base.decode16!(@checksum),
               outer_checksum: Base.decode16!(@checksum),
               dependencies: []
             }

      package3_releases = v2_map("packages/#{p3.name}", ["hexpm", p3.name])
      assert [%{version: "0.0.2", dependencies: deps}] = package3_releases
      assert length(deps) == 2
      assert %{package: p2.name, requirement: "~> 0.0.1"} in deps
      assert %{package: p1.name, requirement: "0.0.1"} in deps
    end
  end

  describe "v2_package_delete/1" do
    test "remove package", %{packages: [_, _, p3]} do
      RegistryBuilder.full(Repository.hexpm())
      assert v2_map("packages/#{p3.name}", ["hexpm", p3.name])

      RegistryBuilder.v2_package_delete(p3)
      refute v2_map("packages/#{p3.name}", ["hexpm", p3.name])
    end
  end
end
