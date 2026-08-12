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

      def source_model
        @source_model
      end

      def pluckr_schema
        @pluckr_schema || raise(ConfigurationError, "#{name} has no `schema` block")
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
