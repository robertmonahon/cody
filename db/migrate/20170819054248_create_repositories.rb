class CreateRepositories < ActiveRecord::Migration[5.1]
  def change
    create_table :repositories do |t|
      t.string "owner"
      t.string "name"
      t.text "config_fingerprint"
    end

    rename_column :pull_requests, :repository, :repository_name
    add_reference :pull_requests, :repository, index: true

    rename_column :review_rules, :repository, :repository_name
    add_reference :review_rules, :repository, index: true
  end
end
