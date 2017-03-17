defmodule Hexpm.Web.API.ReleaseControllerTest do
  use Hexpm.ConnCase, async: true

  alias Hexpm.Accounts.AuditLog
  alias Hexpm.Repository.Package
  alias Hexpm.Repository.Release
  alias Hexpm.Repository.RegistryBuilder

  setup do
    user = insert(:user)
    package = insert(:package, package_owners: [build(:package_owner, owner: user)])
    release = insert(:release, package: package, version: "0.0.1")
    %{user: user, package: package, release: release}
  end

  describe "POST /api/packages/:name/releases" do
    test "create release and new package", %{user: user} do
      meta = %{name: Fake.sequence(:package), version: "1.0.0", description: "Domain-specific language."}
      conn = build_conn()
             |> put_req_header("content-type", "application/octet-stream")
             |> put_req_header("authorization", key_for(user))
             |> post("api/packages/#{meta.name}/releases", create_tar(meta, []))

      result = json_response(conn, 201)
      assert result["url"] =~ "api/packages/#{meta.name}/releases/1.0.0"

      package = Hexpm.Repo.get_by!(Package, name: meta.name)
      package_owner = Hexpm.Repo.one!(assoc(package, :owners))
      assert package_owner.id == user.id

      log = Hexpm.Repo.one!(AuditLog)
      assert log.actor_id == user.id
      assert log.action == "release.publish"
      assert log.params["package"]["name"] == meta.name
      assert log.params["release"]["version"] == "1.0.0"
    end

    test "update package", %{user: user, package: package} do
      meta = %{name: package.name, version: "1.0.0", description: "awesomeness"}
      conn = build_conn()
             |> put_req_header("content-type", "application/octet-stream")
             |> put_req_header("authorization", key_for(user))
             |> post("api/packages/#{package.name}/releases", create_tar(meta, []))

      assert conn.status == 201
      result = json_response(conn, 201)
      assert result["url"] =~ "/api/packages/#{package.name}/releases/1.0.0"

      assert Hexpm.Repo.get_by(Package, name: package.name).meta.description == "awesomeness"
    end

    test "create release authorizes existing package", %{package: package} do
      other_user = insert(:user)
      meta = %{name: package.name, version: "0.1.0", description: "description"}
      build_conn()
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("authorization", key_for(other_user))
      |> post("api/packages/#{package.name}/releases", create_tar(meta, []))
      |> json_response(403)
    end

    test "create release authorizes" do
      meta = %{name: Fake.sequence(:package), version: "0.1.0", description: "description"}
      conn = build_conn()
             |> put_req_header("content-type", "application/octet-stream")
             |> put_req_header("authorization", "WRONG")
             |> post("api/packages/#{meta.name}/releases", create_tar(meta, []))

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Basic realm=hex"]
    end

    test "update package authorizes", %{package: package} do
      meta = %{name: package.name, version: "1.0.0", description: "Domain-specific language."}
      conn = build_conn()
             |> put_req_header("content-type", "application/octet-stream")
             |> put_req_header("authorization", "WRONG")
             |> post("api/packages/ecto/releases", create_tar(meta, []))

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Basic realm=hex"]
    end

    test "create package validates", %{user: user, package: package} do
      meta = %{name: package.name, version: "1.0.0", links: "invalid", description: "description"}
      conn = build_conn()
             |> put_req_header("content-type", "application/octet-stream")
             |> put_req_header("authorization", key_for(user))
             |> post("api/packages/#{package.name}/releases", create_tar(meta, []))

      result = json_response(conn, 422)
      assert result["errors"]["meta"]["links"] == "expected type map(string)"
    end

    test "create release checks if package name is correct", %{user: user, package: package} do
      meta = %{name: Fake.sequence(:package), version: "0.1.0", description: "description"}
      conn = build_conn()
             |> put_req_header("content-type", "application/octet-stream")
             |> put_req_header("authorization", key_for(user))
             |> post("api/packages/#{package.name}/releases", create_tar(meta, []))

      result = json_response(conn, 422)
      assert result["errors"]["name"] == "mismatch between metadata and endpoint"

      meta = %{name: package.name, version: "1.0.0", description: "description"}
      conn = build_conn()
             |> put_req_header("content-type", "application/octet-stream")
             |> put_req_header("authorization", key_for(user))
             |> post("api/packages/#{Fake.sequence(:package)}/releases", create_tar(meta, []))

      # Bad error message but nothing we can do about it at this point
      # https://github.com/hexpm/hexpm/issues/489
      result = json_response(conn, 422)
      assert result["errors"]["name"] == "has already been taken"
    end

    test "create releases", %{user: user} do
      meta = %{name: Fake.sequence(:package), app: "other", version: "0.0.1", description: "description"}
      conn = build_conn()
             |> put_req_header("content-type", "application/octet-stream")
             |> put_req_header("authorization", key_for(user))
             |> post("api/packages/#{meta.name}/releases", create_tar(meta, []))

      result = json_response(conn, 201)
      assert result["meta"]["app"] == "other"
      assert result["url"] =~ "/api/packages/#{meta.name}/releases/0.0.1"

      meta = %{name: meta.name, version: "0.0.2", description: "description"}
      build_conn()
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("authorization", key_for(user))
      |> post("api/packages/#{meta.name}/releases", create_tar(meta, []))

      |> json_response(201)

      package = Hexpm.Repo.get_by!(Package, name: meta.name)
      package_id = package.id

      assert [%Release{package_id: ^package_id, version: %Version{major: 0, minor: 0, patch: 2}},
              %Release{package_id: ^package_id, version: %Version{major: 0, minor: 0, patch: 1}}] =
             Release.all(package) |> Hexpm.Repo.all |> Release.sort

      Hexpm.Repo.get_by!(assoc(package, :releases), version: "0.0.1")
    end

    test "create release also creates package", %{user: user} do
      meta = %{name: Fake.sequence(:package), version: "1.0.0", description: "Web framework"}
      build_conn()
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("authorization", key_for(user))
      |> post("api/packages/#{meta.name}/releases", create_tar(meta, []))
      |> json_response(201)

      Hexpm.Repo.get_by!(Package, name: meta.name)
    end

    test "update release", %{user: user} do
      meta = %{name: Fake.sequence(:package), version: "0.0.1", description: "description"}
      build_conn()
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("authorization", key_for(user))
      |> post("api/packages/#{meta.name}/releases", create_tar(meta, []))
      |> json_response(201)

      build_conn()
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("authorization", key_for(user))
      |> post("api/packages/#{meta.name}/releases", create_tar(meta, []))
      |> json_response(200)

      package = Hexpm.Repo.get_by!(Package, name: meta.name)
      Hexpm.Repo.get_by!(assoc(package, :releases), version: "0.0.1")
      assert [%AuditLog{action: "release.publish"}, %AuditLog{action: "release.publish"}] =
             Hexpm.Repo.all(AuditLog)
    end

    test "cannot update release after grace period", %{user: user, package: package, release: release} do
      Ecto.Changeset.change(release, inserted_at: %{NaiveDateTime.utc_now | year: 2000})
      |> Hexpm.Repo.update!

      meta = %{name: package.name, version: "0.0.1", description: "description"}
      conn = build_conn()
             |> put_req_header("content-type", "application/octet-stream")
             |> put_req_header("authorization", key_for(user))
             |> post("api/packages/#{package.name}/releases", create_tar(meta, []))

      result = json_response(conn, 422)
      assert result["errors"]["inserted_at"] == "can only modify a release up to one hour after creation"
    end

    test "create releases with requirements", %{user: user, package: package} do
      reqs = [%{name: package.name, requirement: "~> 0.0.1", app: "app", optional: false}]
      meta = %{name: Fake.sequence(:package), version: "0.0.1", requirements: reqs, description: "description"}
      conn = build_conn()
             |> put_req_header("content-type", "application/octet-stream")
             |> put_req_header("authorization", key_for(user))
             |> post("api/packages/#{meta.name}/releases", create_tar(meta, []))

      result = json_response(conn, 201)
      assert result["requirements"] == %{package.name => %{"app" => "app", "optional" => false, "requirement" => "~> 0.0.1"}}

      release =
        Hexpm.Repo.get_by!(Package, name: meta.name)
        |> assoc(:releases)
        |> Hexpm.Repo.get_by!(version: "0.0.1")
        |> Hexpm.Repo.preload(:requirements)

      assert [%{app: "app", requirement: "~> 0.0.1", optional: false}] = release.requirements
    end

    test "create releases with requirements validates requirement", %{user: user, package: package} do
      reqs = [%{name: package.name, requirement: "~> invalid", app: "app", optional: false}]
      meta = %{name: Fake.sequence(:package), version: "0.0.1", requirements: reqs, description: "description"}
      conn = build_conn()
             |> put_req_header("content-type", "application/octet-stream")
             |> put_req_header("authorization", key_for(user))
             |> post("api/packages/#{meta.name}/releases", create_tar(meta, []))

      result = json_response(conn, 422)
      assert result["errors"]["requirements"][package.name] == ~s(invalid requirement: "~> invalid")
    end

    test "create releases with requirements validates package name", %{user: user} do
      reqs = [%{name: "nonexistant_package", requirement: "~> 1.0", app: "app", optional: false}]
      meta = %{name: Fake.sequence(:package), version: "0.0.1", requirements: reqs, description: "description"}
      conn = build_conn()
             |> put_req_header("content-type", "application/octet-stream")
             |> put_req_header("authorization", key_for(user))
             |> post("api/packages/#{meta.name}/releases", create_tar(meta, []))

      result = json_response(conn, 422)
      assert result["errors"]["requirements"]["nonexistant_package"] == "package does not exist"
    end

    test "create releases with requirements validates resolution", %{user: user, package: package} do
      reqs = [%{name: package.name, requirement: "~> 1.0", app: "app", optional: false}]
      meta = %{name: Fake.sequence(:package), version: "0.1.0", requirements: reqs, description: "description"}
      conn = build_conn()
             |> put_req_header("content-type", "application/octet-stream")
             |> put_req_header("authorization", key_for(user))
             |> post("api/packages/#{meta.name}/releases", create_tar(meta, []))

      result = json_response(conn, 422)
      assert result["errors"]["requirements"][package.name] == ~s(Failed to use "#{package.name}" because\n  mix.exs specifies ~> 1.0\n)
    end

    test "create release updates registry", %{user: user, package: package} do
      RegistryBuilder.full_build()
      registry_before = Hexpm.Store.get(nil, :s3_bucket, "registry.ets.gz", [])

      reqs = [%{name: package.name, app: "app", requirement: "~> 0.0.1", optional: false}]
      meta = %{name: Fake.sequence(:package), app: "app", version: "0.0.1", requirements: reqs, description: "description"}
      build_conn()
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("authorization", key_for(user))
      |> post("api/packages/#{meta.name}/releases", create_tar(meta, []))
      |> json_response(201)

      registry_after = Hexpm.Store.get(nil, :s3_bucket, "registry.ets.gz", [])
      assert registry_before != registry_after
    end
  end

  describe "DELETE /api/packages/:name/releases/:version" do
    @tag isolation: :serializable
    test "delete release validates release age", %{user: user, package: package, release: release} do
      Ecto.Changeset.change(release, inserted_at: %{NaiveDateTime.utc_now | year: 2000})
      |> Hexpm.Repo.update!

      conn = build_conn()
             |> put_req_header("authorization", key_for(user))
             |> delete("api/packages/#{package.name}/releases/0.0.1")

      result = json_response(conn, 422)
      assert result["errors"]["inserted_at"] == "can only delete a release up to one hour after creation"
    end

    @tag isolation: :serializable
    test "delete release", %{user: user, package: package, release: release} do
      Ecto.Changeset.change(release, inserted_at: %{NaiveDateTime.utc_now | year: 2030})
      |> Hexpm.Repo.update!

      build_conn()
      |> put_req_header("authorization", key_for(user))
      |> delete("api/packages/#{package.name}/releases/0.0.1")
      |> response(204)

      refute Hexpm.Repo.get_by(Package, name: package.name)
      refute Hexpm.Repo.get_by(assoc(package, :releases), version: "0.0.1")

      [log] = Hexpm.Repo.all(AuditLog)
      assert log.actor_id == user.id
      assert log.action == "release.revert"
      assert log.params["package"]["name"] == package.name
      assert log.params["release"]["version"] == "0.0.1"
    end
  end

  describe "GET /api/packages/:name/releases/:version" do
    test "get release", %{package: package, release: release} do
      result =
        build_conn()
        |> get("api/packages/#{package.name}/releases/#{release.version}")
        |> json_response(200)

      assert result["url"] =~ "/api/packages/#{package.name}/releases/#{release.version}"
      assert result["version"] == "#{release.version}"
    end

    test "get unknown release", %{package: package} do
      conn = get(build_conn(), "api/packages/#{package.name}/releases/1.2.3")
      assert conn.status == 404

      conn = get(build_conn(), "api/packages/unknown/releases/1.2.3")
      assert conn.status == 404
    end
  end
end
