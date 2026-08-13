# frozen_string_literal: true

module Pluckr
  # Subclass this to declare a read model:
  #
  #   class UserSummary < Pluckr::Query
  #     source User
  #
  #     schema do
  #       field :id
  #       field :email
  #       one :subscription do
  #         field :name
  #       end
  #       exists :photos
  #       count :videos
  #     end
  #   end
  class Query
    class << self
      # ------------------------------------------------------------- DSL --

      def source(model)
        unless model.is_a?(Class) && model < ActiveRecord::Base
          raise ConfigurationError, "`source` expects an ActiveRecord model, got #{model.inspect}"
        end

        @source_model = model
      end

      def schema(&block)
        @pluckr_schema = Schema::Definition.build(source_model, &block)
        reset_compilation!
        @pluckr_schema
      end

      # Declared on this class, or inherited from the query it subclasses.
      def source_model
        @source_model || inherited_from_query(:source_model)
      end

      def pluckr_schema
        declared_schema || raise(ConfigurationError, "#{name} has no `schema` block")
      end

      # The schema declared here or by a query this one subclasses, or nil.
      # Kept separate from `pluckr_schema` so the error names the class that was
      # actually used, not an intermediate base class.
      def declared_schema
        @pluckr_schema || inherited_from_query(:declared_schema)
      end

      # Source-rooted queries return rows; aggregate-only queries return one object.
      def source_rooted?
        !source_model.nil?
      end

      # ---------------------------------------------------------- querying --

      def all
        raise MissingSource, "#{name} has no `source` model to query" unless source_rooted?

        Relation.new(self, source_model.all)
      end

      def where(...)
        all.where(...)
      end

      def order(...)
        all.order(...)
      end

      def limit(value)
        all.limit(value)
      end

      def offset(value)
        all.offset(value)
      end

      def find(id)
        all.find(id)
      end

      # Read models for records already in memory. One statement for a collection.
      #
      #   UserCard.for(user)     # one object, like find(user.id)
      #   UserCard.for(users)    # array, same order, one SQL
      #   UserCard.for(scope)    # an unloaded relation stays a subquery
      def for(records)
        all.for(records)
      end

      def first
        all.first
      end

      def fetch
        source_rooted? ? all.fetch : fetch_aggregates
      end

      def to_sql
        source_rooted? ? all.to_sql : compiler.aggregate_only_sql
      end

      # ---------------------------------------------------------- internals --

      def compiler
        @compiler ||= Compiler::Sql.new(schema: pluckr_schema, source_model: source_model)
      end

      def result_builder
        @result_builder ||= Result::Builder.new(pluckr_schema, label: name || "Pluckr::Result")
      end

      private

      def inherited_from_query(reader)
        return nil unless superclass.respond_to?(reader) && superclass <= Query && superclass != Query

        superclass.public_send(reader)
      end

      def fetch_aggregates
        row = compiler.connection.select_all(to_sql, "#{name} Pluckr").first
        result_builder.build(row)
      end

      def reset_compilation!
        @compiler = nil
        @result_builder = nil
      end
    end
  end
end
