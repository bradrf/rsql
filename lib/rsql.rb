# A module encapsulating classes to manage MySQLResults and process
# Commands using an EvalContext for handling recipes.
#
# See the {file:example.rsqlrc.rdoc} file for a simple tutorial and usage
# information.
#
module RSQL
    VERSION = [0,3,0]

    def VERSION.to_s
        self.join('.')
    end

    # Set up our version to be comparable to version strings.
    #
    VERSION.extend(Comparable)
    def VERSION.eql?(version)
        self.<=>(version) == 0
    end
    def VERSION.<=>(version)
        version = version.split('.').map!{|v|v.to_i}
        r = self[0] <=> version[0]
        r = self[1] <=> version[1] if r == 0
        r = self[2] <=> version[2] if r == 0
        r
    end

    require 'rsql/mysql_results'
    require 'rsql/eval_context'
    require 'rsql/commands'
end
