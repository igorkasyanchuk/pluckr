# frozen_string_literal: true

module Pluckr
  module Schema
    # `where:` on an aggregate or existence node.
    #
    # A Hash is validated once, when the schema is defined, and is therefore
    # frozen at load time - `where: { created_at: 1.week.ago.. }` would keep
    # asking about the week before boot, forever.
    #
    # A callable is invoked on every compilation instead, so runtime values stay
    # runtime values:
    #
    #   count :recent_orders, from: Order, where: -> { { created_at: 1.week.ago.. } }
    module Conditions
      def dynamic_where?
        where.respond_to?(:call)
      end

      # @return [Hash, nil] the conditions to apply to this compilation
      def resolved_where
        return where unless dynamic_where?

        conditions = where.call

        unless conditions.is_a?(Hash)
          raise ConfigurationError,
                "`#{output}`: a `where:` lambda must return a Hash of column => value, " \
                "got #{conditions.inspect}"
        end

        conditions.each_key { |key| validate_column!(key) }
        conditions
      end

      private

      def validate_column!(name)
        return if target_model.column_names.include?(name.to_s)

        raise UnknownField, "#{target_model.name} does not have column `#{name}`"
      end
    end
  end
end
