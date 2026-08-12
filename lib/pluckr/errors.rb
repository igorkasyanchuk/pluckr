# frozen_string_literal: true

module Pluckr
  # Base class for every error raised by Pluckr.
  class Error < StandardError; end

  # Raised when a query is defined or used incorrectly.
  class ConfigurationError < Error; end

  # `field :nope` where the model has no such column.
  class UnknownField < ConfigurationError; end

  # `one :nope` / `exists :nope` where the model has no such association.
  class UnknownAssociation < ConfigurationError; end

  # Association exists but has the wrong cardinality for the DSL node used.
  class InvalidAssociation < ConfigurationError; end

  # Association exists but Pluckr cannot compile it yet (polymorphic, through, scoped).
  class UnsupportedAssociation < ConfigurationError; end

  # A root-record node was used in a query without `source`.
  class MissingSource < ConfigurationError; end
end
