# frozen_string_literal: true

module Pluckr
  # Single source of truth for the flat column aliases used in generated SQL.
  #
  # The SQL stays flat; nesting lives in the alias path:
  #
  #   users.id                 AS "id"
  #   subscriptions.name       AS "subscription.name"
  #   subscriptions.id         AS "__pluckr.subscription.present"
  #
  # The result builder reads the same helpers back, so the encoding is never
  # duplicated between the compiler and the hydrator.
  module Aliases
    SEPARATOR = "."
    PRESENCE_PREFIX = "__pluckr"
    PRESENCE_SUFFIX = "present"
    TABLE_PREFIX = "pluckr"

    module_function

    # Output alias for a value node, e.g. ["subscription"], :name => "subscription.name"
    def output(path, name)
      (path + [name]).join(SEPARATOR)
    end

    # Hidden marker telling the hydrator whether a nested `one` row exists at all.
    def presence(path)
      ([PRESENCE_PREFIX] + path + [PRESENCE_SUFFIX]).join(SEPARATOR)
    end

    # Table alias for a joined singular association.
    def table(path)
      ([TABLE_PREFIX] + path).join("_")
    end
  end
end
