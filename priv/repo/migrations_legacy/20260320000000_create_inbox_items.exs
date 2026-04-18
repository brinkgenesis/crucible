defmodule Crucible.Repo.Migrations.CreateInboxItems do
  use Ecto.Migration

  def change do
    create table(:inbox_items, primary_key: false) do
      add :id, :text, primary_key: true
      add :source, :text, null: false, default: "twitter"
      add :source_id, :text, null: false
      add :status, :text, null: false, default: "unread"
      add :author_username, :text
      add :author_name, :text
      add :original_text, :text, null: false
      add :summary, :text
      add :extracted_urls, :jsonb, null: false, default: "[]"
      add :extracted_repos, :jsonb, null: false, default: "[]"
      add :related_vault_notes, :jsonb, null: false, default: "[]"
      add :card_id, references(:cards, type: :text, on_delete: :nilify_all)
      add :report_path, :text
      add :raw_data, :jsonb, null: false, default: "{}"
      add :ingested_at, :timestamptz, null: false
      add :created_at, :timestamptz, null: false, default: fragment("NOW()")
      add :updated_at, :timestamptz, null: false, default: fragment("NOW()")
    end

    create unique_index(:inbox_items, [:source, :source_id])
    create index(:inbox_items, [:status])
    create index(:inbox_items, [:created_at], name: :inbox_items_created_at_desc)
  end
end
