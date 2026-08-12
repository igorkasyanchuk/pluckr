# frozen_string_literal: true

module QueryHelpers
  # Defines a Pluckr::Query under a real constant name so error messages,
  # result labels and inspect output look like they do in an app.
  def define_query(name, &block)
    klass = Class.new(Pluckr::Query, &block)
    stub_const(name, klass)
    klass
  end
end
