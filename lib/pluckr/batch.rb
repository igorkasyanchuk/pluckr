# frozen_string_literal: true

module Pluckr
  # Runs several unrelated aggregates over ActiveRecord relations in one
  # statement:
  #
  #   stats = Pluckr.batch do |b|
  #     b.count  user.videos,                        as: :video_count
  #     b.sum    user.videos.where(size: 100..), :size, as: :big_video_bytes
  #     b.exists user.photos,                        as: :has_photos
  #     b.count  Account.active,                     as: :active_accounts
  #   end
  #
  #   stats.video_count  # => 3
  #
  # Each entry is whatever SQL the relation already compiles to, so default
  # scopes, association scopes, `:through`, polymorphic and STI conditions are
  # respected - ActiveRecord applied them before Pluckr saw the relation.
  #
  # This is the ad-hoc counterpart to `Pluckr::Query`: no class, no reuse, and
  # bound to concrete records rather than to a row of a result set.
  class Batch
    # Eager loading is pointless inside a scalar aggregate subquery and joining
    # the associated tables can change the row count; row locks are not allowed
    # alongside an aggregate.
    IGNORED_RELATION_VALUES = %i[includes eager_load preload lock].freeze

    COLUMNLESS_OPERATIONS = %i[count exists].freeze

    def self.build(&block)
      raise ConfigurationError, "`Pluckr.batch` requires a block" unless block

      batch = new
      block.call(batch)
      batch
    end

    def initialize
      @nodes = []
    end

    # ---------------------------------------------------------------- DSL --

    def count(source, column = nil, as:)
      add(:count, source, column, as)
    end

    def sum(source, column, as:)
      add(:sum, source, column, as)
    end

    def min(source, column, as:)
      add(:min, source, column, as)
    end

    def max(source, column, as:)
      add(:max, source, column, as)
    end

    def exists(source, as:)
      add(:exists, source, nil, as)
    end

    # ----------------------------------------------------------- execution --

    def to_sql
      compiler.aggregate_only_sql
    end

    def fetch
      scope = schema
      compiler = Compiler::Sql.new(schema: scope)
      row = compiler.connection.select_all(compiler.aggregate_only_sql, "Pluckr Batch").first

      Result::Builder.new(scope, label: "Pluckr::Batch").build(row)
    end

    def entries
      @nodes.map(&:output)
    end

    def inspect
      "#<Pluckr::Batch #{entries.join(", ")}>"
    end

    private

    def add(operation, source, column, output)
      relation = relation_for(operation, output, source)
      column = validate_column!(operation, output, column, relation.klass)
      validate_grouping!(operation, output, column, relation)
      validate_projection!(operation, output, column, relation)
      validate_connection!(output, relation)
      validate_output!(output)

      @nodes << Schema::Aggregate.new(
        output: output,
        operation: operation,
        relation: normalize(relation),
        column: column
      )
      self
    end

    # The derived table has to expose exactly what the outer aggregate reads,
    # without changing what the caller asked for.
    def normalize(relation)
      ignored = IGNORED_RELATION_VALUES.dup
      # ORDER BY only matters when it decides which rows a limit/offset keeps.
      ignored << :order unless relation.limit_value || relation.offset_value
      relation = relation.unscope(*ignored)

      # A projection is meaningful when it is what DISTINCT or GROUP BY applies
      # to, and noise otherwise.
      return relation if relation.select_values.any? && projection_matters?(relation)

      return relation.unscope(:select) if relation.group_values.empty?

      # `SELECT *` alongside GROUP BY is invalid on PostgreSQL and MySQL.
      relation.unscope(:select).select(*relation.group_values)
    end

    def projection_matters?(relation)
      relation.distinct_value || relation.group_values.any?
    end

    def relation_for(operation, output, source)
      return source.all if source.is_a?(Class) && source < ActiveRecord::Base
      return source if source.is_a?(ActiveRecord::Relation)

      raise ConfigurationError,
            "`#{operation} ..., as: :#{output}` expects an ActiveRecord relation or model, " \
            "got #{source.inspect}"
    end

    # A grouped relation returns one row per group, so the only thing that can
    # be asked of it is how many groups there are.
    def validate_grouping!(operation, output, column, relation)
      return if relation.group_values.empty?
      return if COLUMNLESS_OPERATIONS.include?(operation) && column.nil?

      raise ConfigurationError,
            "`#{operation} ..., as: :#{output}`: the relation is grouped, so only `count` and " \
            "`exists` (without a column) are meaningful - aggregate inside the relation instead"
    end

    # count and exists work without a column; the rest need one.
    def validate_column!(operation, output, column, model)
      if column.nil?
        return nil if COLUMNLESS_OPERATIONS.include?(operation)

        raise ConfigurationError, "`#{operation} ..., as: :#{output}` requires a column"
      end

      unless model.column_names.include?(column.to_s)
        raise UnknownField, "#{model.name} does not have column `#{column}`"
      end

      column
    end

    # With DISTINCT the caller's projection is kept, so an aggregate column that
    # is not part of it would not exist in the derived table.
    def validate_projection!(operation, output, column, relation)
      return if column.nil? || !relation.distinct_value

      projected = relation.select_values.select { |value| value.is_a?(Symbol) || value.is_a?(String) }
      return if projected.empty? || projected.map(&:to_s).include?(column.to_s)

      raise ConfigurationError,
            "`#{operation} ..., as: :#{output}`: the relation selects #{projected.join(", ")} " \
            "with DISTINCT, so column `#{column}` is not available to aggregate"
    end

    # One statement means one connection.
    def validate_connection!(output, relation)
      return if @nodes.empty?

      first = @nodes.first.relation.klass
      return if first.connection_pool == relation.klass.connection_pool

      raise ConfigurationError,
            "`as: :#{output}`: #{relation.klass.name} and #{first.name} use different database " \
            "connections, so they cannot be batched into one statement"
    end

    def validate_output!(output)
      return unless @nodes.any? { |node| node.output == output.to_sym }

      raise ConfigurationError, "duplicate output name `#{output}` in batch"
    end

    # Rebuilt per call: entries may be added between to_sql and fetch.
    def schema
      raise ConfigurationError, "batch is empty - add at least one aggregate" if @nodes.empty?

      Schema::Scope.new(nil, @nodes.dup) # Scope freezes what it is given
    end

    def compiler
      Compiler::Sql.new(schema: schema)
    end
  end

  # @see Pluckr::Batch
  def self.batch(&block)
    Batch.build(&block).fetch
  end
end
