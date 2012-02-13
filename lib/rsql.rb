# A module encapsulating classes to manage MySQLResults and process
# Commands using an EvalContext for handling recipes.
#
module RSQL
    VERSION = '0.2.8'

    require 'rsql/mysql_results'
    require 'rsql/eval_context'
    require 'rsql/commands'
end
