7# Copyright (C) 2011 by Brad Robel-Forrest <brad+rsql@gigglewax.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

module RSQL

    require 'mysql'

    ########################################
    # A wrapper to make it easier to work with MySQL results (and prettier)
    #
    class MySQLResults

        HEX_RANGE = (Mysql::Field::TYPE_TINY_BLOB..Mysql::Field::TYPE_STRING)

        @@conn            = nil
        @@field_separator = ' '
        @@max_rows        = 1000
        @@database_name   = nil

        class MaxRowsException < RangeError
            def initialize(rows, max)
                @rows = rows
                @max  = max
            end
            attr_reader :rows, :max
        end

        class << self

            def conn; @@conn; end
            def conn=(conn); @@conn = conn; end

            def field_separator; @@field_separator; end
            def field_separator=(sep); @@field_separator = sep; end

            def max_rows; @@max_rows; end
            def max_rows=(cnt); @@max_rows = cnt; end

            def database_name; @@database_name; end

            # get results from a query
            #
            def query(content, eval_context, max_rows=@@max_rows)
                if content.match(/use\s+(\S+)/)
                    @@database_name = $1
                end

                results = @@conn.query(content)

                return nil unless results && 0 < results.num_rows
                if max_rows < results.num_rows
                    raise MaxRowsException.new(results.num_rows, max_rows)
                end

                # extract mysql results into our own table so we can predetermine the
                # lengths of columns and give users a chance to reformat column data
                # before it's displayed (via the bang maps)

                fields = results.fetch_fields
                fields.collect! do |field|
                    def field.longest_length=(len); @longest_length = len; end
                    def field.longest_length; @longest_length; end
                    field.longest_length = field.name.length
                    field
                end

                results_table = []
                while vals = results.fetch_row
                    row = []
                    fields.each_with_index do |field, i|
                        val = eval_context.bang_eval(field.name, vals[i])
                        if val.nil?
                            val = 'NULL'
                        elsif HEX_RANGE.include?(field.type) && val =~ /[^[:print:]\s]/
                            val = eval_context.to_hexstr(val)
                        end
                        if field.longest_length < val.length
                            if String === val
                                # consider only the longest line length since some
                                # output contains multiple lines like "show create table"
                                longest_line = val.split(/\r?\n/).collect{|l|l.length}.max
                                if field.longest_length < longest_line
                                    field.longest_length = longest_line
                                end
                            else
                                field.longest_length = val.length
                            end
                        end
                        row << val
                    end
                    results_table << row
                end

                return new(fields, results_table)
            end

        end # class << self

        ########################################

        def initialize(fields, table, field_separator=@@field_separator)
            @fields = fields
            @table  = table
            @field_separator = field_separator
        end

        # get a row from the table hashed with the field names
        #
        def row_hash(index)
            return nil unless @fields && @table

            row = @table[index]
            hash = {}
            @fields.each_with_index {|f,i| hash[f.name] = row[i]}

            return hash
        end

        # iterate through each row of the table hashed with the field
        # names
        #
        def each_hash(&block)
            @table.each do |row|
                hash = {}
                @fields.each_with_index {|f,i| hash[f.name] = row[i]}
                yield(hash)
            end
        end

        # show a set of results in a decent fashion
        #
        def display_by_column(io=$stdout)
            return unless @fields && @table

            fmts = []
            names = []
            len = 0
            @fields.each do |field|
                fmts << "%-#{field.longest_length}s"
                names << field.name
                len += field.longest_length
            end

            fmt = fmts.join(@field_separator)
            io.puts(fmt % names, '-' * (len + fmts.length))
            @table.each{|row| io.puts(fmt % row)}
        end

        # show a set of results with a single character separation
        #
        def display_by_batch(io=$stdout)
            return unless @fields && @table

            fmt = (['%s'] * @fields.size).join(@field_separator)
            io.puts fmt % @fields.collect{|f| f.name}
            @table.each{|row| io.puts(fmt % row)}
        end

        # show a set of results line separated
        #
        def display_by_line(io=$stdout)
            return unless @fields && @table

            namelen = 0
            @fields.each do |field|
                namelen = field.name.length if namelen < field.name.length
            end
            namelen += 1

            @table.each_with_index do |row, i|
                io.puts("#{'*'*30} #{i+1}. row #{'*'*30}")
                row.each_with_index do |val, vi|
                    io.printf("%#{namelen}s #{val}#{$/}", @fields[vi].name + ':')
                end
            end
        end

    end # class MySQLResults

end # module RSQL
