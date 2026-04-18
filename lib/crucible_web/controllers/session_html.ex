defmodule CrucibleWeb.SessionHTML do
  @moduledoc """
  Templates for the session (login/logout) controller.
  """
  use CrucibleWeb, :html

  embed_templates "session_html/*"
end
