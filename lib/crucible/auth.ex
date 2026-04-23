defmodule Crucible.Auth do
  @moduledoc """
  Session-based authentication for the dashboard.
  Manages DB-backed sessions shared with the TypeScript dashboard.
  Both apps read/write the same `users` and `sessions` tables.
  """
  alias Crucible.Repo
  alias Crucible.Schema.{User, Session}
  import Ecto.Query

  @session_ttl_days 7
  @dev_user_id "dev-user-00000000"
  @dev_user_email "dev@localhost"

  @type auth_user :: %{
          id: String.t(),
          email: String.t(),
          name: String.t(),
          picture_url: String.t() | nil,
          role: String.t()
        }

  @doc "Look up a session by ID. Returns user map if valid and not expired."
  @spec lookup_session(String.t()) :: auth_user() | nil
  def lookup_session(sid) do
    now = DateTime.utc_now()

    from(s in Session,
      join: u in User,
      on: u.id == s.user_id,
      where: s.id == ^sid and s.expires_at > ^now,
      select: %{
        id: u.id,
        email: u.email,
        name: u.name,
        picture_url: u.picture_url,
        role: u.role
      }
    )
    |> Repo.one()
  end

  @doc "Create a new DB session. Returns `{session_id, expires_at}`."
  @spec create_session(String.t()) :: {String.t(), DateTime.t()}
  def create_session(user_id) do
    id = Ecto.UUID.generate()
    expires_at = DateTime.add(DateTime.utc_now(), @session_ttl_days * 86_400)

    %Session{id: id}
    |> Session.changeset(%{user_id: user_id, expires_at: expires_at})
    |> Repo.insert!()

    {id, expires_at}
  end

  @doc "Destroy a session by ID."
  @spec destroy_session(String.t()) :: :ok
  def destroy_session(sid) do
    from(s in Session, where: s.id == ^sid) |> Repo.delete_all()
    :ok
  end

  @doc "Delete all expired sessions. Returns count deleted."
  @spec clean_expired_sessions() :: non_neg_integer()
  def clean_expired_sessions do
    now = DateTime.utc_now()
    {count, _} = from(s in Session, where: s.expires_at < ^now) |> Repo.delete_all()
    count
  end

  @doc "Upsert user from Google OAuth profile. Preserves existing role."
  @spec upsert_oauth_user(map()) :: User.t()
  def upsert_oauth_user(profile) do
    case Repo.get_by(User, email: profile.email) do
      nil ->
        %User{id: profile.sub}
        |> User.changeset(%{
          email: profile.email,
          name: profile.name || "",
          picture_url: profile.picture_url,
          role: "viewer"
        })
        |> Repo.insert!()

      existing ->
        existing
        |> User.changeset(%{
          name: profile.name || existing.name,
          picture_url: profile.picture_url
        })
        |> Repo.update!()
    end
  end

  @doc "Ensure the dev user exists. Returns user struct."
  @spec ensure_dev_user() :: User.t()
  def ensure_dev_user do
    case Repo.get(User, @dev_user_id) do
      nil ->
        %User{id: @dev_user_id}
        |> User.changeset(%{
          email: @dev_user_email,
          name: "Dev User",
          role: "admin"
        })
        |> Repo.insert!()

      user ->
        user
    end
  end

  def dev_user_id, do: @dev_user_id
  def session_ttl_seconds, do: @session_ttl_days * 86_400
end
