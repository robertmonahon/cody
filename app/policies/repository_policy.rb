class RepositoryPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      Repository
    end
  end
end
