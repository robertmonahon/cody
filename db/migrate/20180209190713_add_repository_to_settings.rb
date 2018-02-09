class AddRepositoryToSettings < ActiveRecord::Migration[5.1]
  def change
    add_column :settings, :repository, :string
  end
end
