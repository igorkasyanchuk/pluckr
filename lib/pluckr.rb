# frozen_string_literal: true

require "active_record"

require "pluckr/version"
require "pluckr/errors"
require "pluckr/aliases"
require "pluckr/reflection/association"
require "pluckr/schema/node"
require "pluckr/schema/field"
require "pluckr/schema/one"
require "pluckr/schema/exists"
require "pluckr/schema/aggregate"
require "pluckr/schema/scope"
require "pluckr/schema/definition"
require "pluckr/compiler/sql"
require "pluckr/result/object"
require "pluckr/result/builder"
require "pluckr/relation"
require "pluckr/batch"
require "pluckr/query"

# A declarative read-query layer for ActiveRecord.
#
#   DSL -> schema AST -> reflection -> SQL compiler -> flat row -> result object
module Pluckr
end
