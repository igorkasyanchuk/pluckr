# frozen_string_literal: true

module Pluckr
  module Result
    # Immutable, ActiveRecord-free value object.
    #
    # One subclass is generated per schema level, with a plain reader per
    # selected output. Internal aliases and presence markers never reach here.
    class Object
      # @param outputs [Array<Symbol>] readers this level exposes
      # @param label [String] shown by #inspect
      def self.build_class(outputs, label)
        Class.new(self) do
          define_singleton_method(:pluckr_outputs) { outputs }
          define_singleton_method(:pluckr_label) { label }

          outputs.each do |output|
            define_method(output) { @attributes[output] }
          end
        end
      end

      def self.pluckr_outputs
        []
      end

      def self.pluckr_label
        "Pluckr::Result"
      end

      def initialize(attributes)
        @attributes = attributes.freeze
        freeze
      end

      def [](key)
        @attributes[key.to_sym]
      end

      def to_h
        @attributes.transform_values do |value|
          value.is_a?(Object) ? value.to_h : value
        end
      end
      alias to_hash to_h

      # Without this, ActiveSupport serialises the object's ivars and
      # `render json: result` emits {"attributes": {...}}.
      def as_json(options = nil)
        to_h.as_json(options)
      end

      def to_json(*args)
        as_json.to_json(*args)
      end

      def keys
        @attributes.keys
      end

      def ==(other)
        other.class == self.class && other.to_h == to_h
      end
      alias eql? ==

      def hash
        [self.class, to_h].hash
      end

      def inspect
        pairs = @attributes.map { |key, value| "#{key}=#{value.inspect}" }
        "#<#{self.class.pluckr_label} #{pairs.join(", ")}>"
      end
      alias to_s inspect

      def pretty_print(pp)
        pp.text(inspect)
      end
    end
  end
end
