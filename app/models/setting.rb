class Setting < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :value, presence: true

  class << self
    def lookup(key, repository = nil)
      return nil unless exists?(key: key, repository: repository)
      raw = find_by(key: key, repository: repository).value
      Transit::Reader.new(:json, StringIO.new(raw)).read
    end

    def assign(key, value, repository = nil)
      io = StringIO.new("", "w+")
      Transit::Writer.new(:json, io).write(value)
      s = find_or_initialize_by(key: key, repository: repository)
      s.value = io.string
      s.save!
      s
    end
  end
end
