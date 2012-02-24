# A module encapsulating classes to manage MySQLResults and process
# Commands using an EvalContext for handling recipes.
#
# See the {file:example.rsqlrc.rdoc} file for a simple tutorial and usage
# information.
#
module RSQL
    VERSION = '0.2.11'

    require 'rsql/mysql_results'
    require 'rsql/eval_context'
    require 'rsql/commands'
end
