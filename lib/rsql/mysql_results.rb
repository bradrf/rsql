# Copyright (C) 2011 by Brad Robel-Forrest <brad+rsql@gigglewax.com>
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

            # get the name of the current database in use
            #
            def database_name; @@database_name; end

            # get the list of databases available
            #
            def databases
                @@databases ||= @@conn.list_dbs.sort if @@conn
            end

            # get the list of tables available (if a database is
            # selected) at most once every ten seconds
            #
            @@last_table_list = Hash.new{|h,k| h[k] = [Time.at(0), []]}
            def tables(database = nil)
                now = Time.now
                (last, tables) = @@last_table_list[database]
                if last + 10 < now
                    begin
                        if @@conn
                            if database && database != database_name
                                tables = @@conn.list_tables("FROM #{database}").sort
                            else
                                tables = @@conn.list_tables.sort
                            end
                        end
                    rescue Mysql::Error => ex
                        tables = []
                    end
                    @@last_table_list[database] = [now, tables]
                end
                tables
            end

            # provide a list of tab completions given the prompted
            # value
            #
            def complete(str)
                return [] unless @@conn

                # offer table names from a specific database
                if str =~ /^([^.]+)\.(.*)$/
                    db = $1
                    tb = $2
                    ret = tables(db).collect do |n|
                        if n.downcase.start_with?(tb)
                            "#{db}.#{n}"
                        else
                            nil
                        end
                    end
                    ret.compact!
                    return ret
                end

                ret = databases.select{|n| n != database_name && n.downcase.start_with?(str)}
                if database_name
                    # if we've selected a db then we want to offer
                    # completions for other dbs as well as tables for
                    # the currently selected db
                    ret += tables.select{|n| n.downcase.start_with?(str)}
                end
                return ret
            end

            # get results from a query
            #
            def query(content, eval_context, max_rows=@@max_rows)
                if content.match(/use\s+(\S+)/)
                    @@database_name = $1
                end

                start   = Time.now.to_f
                results = @@conn.query(content)
                elapsed = Time.now.to_f - start.to_f

                affected_rows = @@conn.affected_rows
                unless results && 0 < results.num_rows
                    return new(elapsed, affected_rows)
                end

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

                return new(elapsed, affected_rows, fields, results_table)
            end

        end # class << self

        ########################################

        def initialize(elapsed, affected_rows,
                       fields=nil, table=nil, field_separator=@@field_separator)
            @elapsed         = elapsed;
            @affected_rows   = affected_rows;
            @fields          = fields
            @table           = table
            @field_separator = field_separator
        end

        # get the number of rows that were affected by the query
        #
        attr_reader :affected_rows

        # determine if there are any results
        #
        def any?
            !@table.nil?
        end

        # determine if there are no results
        #
        def empty?
            @table.nil?
        end

        # get the number of rows available in the results
        #
        def num_rows
            @table ? @table.size : 0
        end

        # get a row from the table hashed with the field names
        #
        def row_hash(index)
            hash = {}
            if @fields && @table
                row = @table[index]
                @fields.each_with_index {|f,i| hash[f.name] = row[i]}
            end
            return hash
        end

        # iterate through each row of the table hashed with the field
        # names
        #
        def each_hash(&block)
            if @table
                @table.each do |row|
                    hash = {}
                    @fields.each_with_index {|f,i| hash[f.name] = row[i]}
                    yield(hash)
                end
            end
        end

        # show a set of results in a decent fashion
        #
        def display_by_column(io=$stdout)
            if @fields && @table
                fmts = []
                names = []
                len = 0
                @fields.each do |field|
                    fmts << "%-#{field.longest_length}s"
                    names << field.name
                    len += field.longest_length
                end

                fmt = fmts.join(@field_separator)
                sep = '-' * (len + fmts.length)
                io.puts(fmt % names, sep)
                @table.each{|row| io.puts(fmt % row)}
                display_stats(io, sep)
            else
                display_stats(io)
            end
        end

        # show a set of results with a single character separation
        #
        def display_by_batch(io=$stdout)
            if @fields && @table
                fmt = (['%s'] * @fields.size).join(@field_separator)
                io.puts fmt % @fields.collect{|f| f.name}
                @table.each{|row| io.puts(fmt % row)}
            end
        end

        # show a set of results line separated
        #
        def display_by_line(io=$stdout)
            if @fields && @table
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
            display_stats(io)
        end

        def display_stats(io=$stdout, hdr='')
            if @table
                s = 1 == @table.size ? 'row' : 'rows'
                io.puts(hdr, "#{@table.size} #{s} in set (#{'%0.2f'%@elapsed} sec)")
            else
                s = 1 == @affected_rows ? 'row' : 'rows'
                io.puts(hdr, "Query OK, #{@affected_rows} #{s} affected (#{'%0.2f'%@elapsed} sec)")
            end
        end

    end # class MySQLResults

end # module RSQL
