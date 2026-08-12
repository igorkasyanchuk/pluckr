# frozen_string_literal: true

module Pluckr
  module Reflection
    # Thin wrapper over ActiveRecord association reflection.
    #
    # Everything Pluckr knows about tables, keys and join direction comes from
    # here - developers never spell out foreign keys in the DSL.
    class Association
      SINGULAR_MACROS = %i[belongs_to has_one].freeze

      attr_reader :owner, :name, :reflection

      # @param owner [Class<ActiveRecord::Base>]
      # @param name [Symbol] association name
      def self.for(owner, name)
        raise MissingSource, "Cannot resolve association `#{name}` without a `source` model" if owner.nil?

        reflection = owner.reflect_on_association(name)
        unless reflection
          raise UnknownAssociation, "#{owner.name} does not have association `#{name}`"
        end

        new(owner, name, reflection)
      end

      def initialize(owner, name, reflection)
        @owner = owner
        @name = name.to_sym
        @reflection = reflection
        validate_supported!
        freeze
      end

      def macro
        reflection.macro
      end

      def klass
        reflection.klass
      end

      def table_name
        klass.table_name
      end

      def primary_key
        klass.primary_key
      end

      def singular?
        SINGULAR_MACROS.include?(macro)
      end

      def collection?
        macro == :has_many
      end

      # Column on the association's own table used in the join.
      def association_key
        reflection.join_primary_key.to_s
      end

      # Column on the owner's table used in the join.
      def owner_key
        reflection.join_foreign_key.to_s
      end

      # ON clause for `owner_table` LEFT JOIN `association_table`.
      def join_condition(association_table, owner_table)
        association_table[association_key].eq(owner_table[owner_key])
      end

      private

      def validate_supported!
        if reflection.polymorphic?
          raise UnsupportedAssociation,
                "`#{owner.name}##{name}` is polymorphic, which Pluckr does not support yet"
        end

        if reflection.through_reflection?
          raise UnsupportedAssociation,
                "`#{owner.name}##{name}` is a :through association, which Pluckr does not support yet"
        end

        if reflection.scope
          raise UnsupportedAssociation,
                "`#{owner.name}##{name}` has a scope, which Pluckr does not apply yet"
        end
      end
    end
  end
end
