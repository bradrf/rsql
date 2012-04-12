#--
# Copyright (C) 2011-2012 by Brad Robel-Forrest <brad+rsql@gigglewax.com>
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

# The standard MySQL hooks block Ruby threads, this interface provides an
# asynchronous query.
#
require 'mysqlplus'

# @private
class Mysql # :nodoc:
    alias :query :async_query
end

module RSQL

    ########################################
    # A wrapper to make it easier to work with MySQL results (and prettier).
    #
    class MySQLResults

        HEX_RANGE = [
                     Mysql::Field::TYPE_BLOB,
                     Mysql::Field::TYPE_STRING,
                    ]

        @@conn            = nil
        @@field_separator = ' '
        @@max_rows        = 1000
        @@database_name   = nil
        @@name_cache      = {}
        @@history         = []
        @@max_history     = 10

        class MaxRowsException < RangeError
            def initialize(rows, max)
                @rows = rows
                @max  = max
            end
            attr_reader :rows, :max
        end

        class << self

            # Get the underlying MySQL connection object in use.
            #
            def conn; @@conn; end

            # Set the underlying MySQL connection object to use which implicitly
            # resets the name cache.
            #
            def conn=(conn)
                if @@conn = conn
                    @@conn.reconnect = true
                end
                reset_cache
            end

            # Get the field separator to use when writing rows in columns.
            #
            def field_separator; @@field_separator; end

            # Set the field separator to use when writing rows in columns.
            #
            def field_separator=(sep); @@field_separator = sep; end

            # Get the maximum number of rows to process before throwing a
            # MaxRowsException.
            #
            def max_rows; @@max_rows; end

            # Set the maximum number of rows to process before throwing a
            # MaxRowsException.
            #
            def max_rows=(cnt); @@max_rows = cnt; end

            # Get the name of the current database in use.
            #
            def database_name; @@database_name; end

            # Set the name of the current database in use.
            #
            def database_name=(database); @@database_name = database; end

            # Get a list of the most recent query strings.
            #
            def history(cnt=:all)
                if Integer === cnt && cnt < @@history.size
                    @@history[-cnt,cnt]
                else
                    @@history
                end
            end

            # Reset the history to an empty list.
            #
            def reset_history
                @@history = []
            end

            # Get the maximum number of historical entries to retain.
            #
            def get_max_history; @@max_history; end

            # Set the maximum number of historical entries to retain.
            #
            def set_max_history=(count); @@max_history = count; end

            # Get the list of databases available.
            #
            def databases
                @@name_cache.keys.sort
            end

            # Get the list of tables available for the current database or a
            # specific one.
            #
            def tables(database=@@database_name)
                @@name_cache[database] || []
            end

            # Force the database and table names cache to be (re)loaded.
            #
            def reset_cache
                @@name_cache = {}
                begin
                    if @@conn
                        @@conn.list_dbs.each do |db_name|
                            @@conn.select_db(db_name)
                            @@name_cache[db_name] = @@conn.list_tables.sort
                        end
                    end
                rescue Mysql::Error => ex
                ensure
                    if @@conn && @@database_name
                        @@conn.select_db(@@database_name)
                    end
                end
            end

            # Provide a list of tab completions given the prompted
            # case-insensitive value.
            #
            def complete(str)
                return [] unless @@conn

                ret = []

                # offer table names from a specific database
                if str =~ /^([^.]+)\.(.*)$/
                    db = $1
                    tb = $2
                    @@name_cache.each do |db_name, tnames|
                        if db.casecmp(db_name) == 0
                            tnames.each do |n|
                                if m = n.match(/^(#{tb})/i)
                                    ret << "#{db_name}.#{n}"
                                end
                            end
                            break
                        end
                    end
                else
                    @@name_cache.each do |db_name, tnames|
                        if db_name == @@database_name
                            tnames.each do |n|
                                if m = n.match(/^(#{str})/i)
                                    ret << n
                                end
                            end
                        elsif m = db_name.match(/^(#{str})/i)
                            ret << db_name
                        end
                    end
                end

                return ret.sort
            end

            # Get results from a query.
            #
            def query(sql, eval_context, raw=false, max_rows=@@max_rows)
                if @@conn.reconnected?
                    # make sure we stick with the user's last database in case
                    # we had to reconnect (probably because the query thread was
                    # killed
                    @@conn.select_db(@@database_name) if @@database_name
                end

                @@history.shift if @@max_history <= @@history.size
                @@history << sql

                start   = Time.now.to_f
                results = @@conn.query(sql)
                elapsed = Time.now.to_f - start.to_f

                affected_rows = @@conn.affected_rows
                unless results && 0 < results.num_rows
                    return new(nil, nil, affected_rows, sql, elapsed)
                end

                if max_rows < results.num_rows
                    raise MaxRowsException.new(results.num_rows, max_rows)
                end

                # extract mysql results into our own table so we can
                # predetermine the lengths of columns and give users a chance to
                # reformat column data before it's displayed (via the bang maps)

                fields = results.fetch_fields
                extend_fields!(fields)

                results_table = []
                while vals = results.fetch_row
                    row = []
                    fields.each_with_index do |field, i|
                        val = vals[i]
                        orig_vlen = val.respond_to?(:length) ? val.length : 0
                        if val && field.is_num?
                            val = field.decimals == 0 ? val.to_i : val.to_f
                        end
                        unless raw
                            val = eval_context.bang_eval(field.name, val)
                            if val.nil?
                                val = 'NULL'
                            elsif HEX_RANGE.include?(field.type) && val =~ /[^[:print:]\s]/
                                val = eval_context.to_hexstr(val)
                            end
                        end
                        update_longest!(field, val, orig_vlen)
                        row << val
                    end
                    results_table << row
                end

                return new(fields, results_table, affected_rows, sql, elapsed)
            end

            ########################################
            private

                def extend_fields!(fields)
                    fields.collect! do |field|
                        def field.name; to_s; end unless field.respond_to?(:name)
                        def field.longest_length=(len); @longest_length = len; end
                        def field.longest_length; @longest_length; end
                        field.longest_length = field.name.length
                        field
                    end
                end

                def update_longest!(field, val, default_vlen=nil)
                    vlen = if val.respond_to?(:length)
                               val.length
                           elsif default_vlen
                               default_vlen
                           else
                               val.to_s.length
                           end

                    if field.longest_length < vlen
                        if String === val
                            # consider only the longest line length since some
                            # output contains multiple lines like "show create
                            # table"
                            longest_line = val.split(/\r?\n/).collect{|l|l.length}.max
                            if field.longest_length < longest_line
                                field.longest_length = longest_line
                            end
                        else
                            field.longest_length = vlen
                        end
                    end
                end

        end # class << self

        ########################################

        def initialize(fields, table, affected_rows=nil, sql=nil, elapsed=nil,
                       field_separator=@@field_separator)

            @fields          = fields
            @table           = table
            @affected_rows   = affected_rows || table.size
            @sql             = sql
            @elapsed         = elapsed
            @field_separator = field_separator

            # we set this here so that it occurs _after_ we are successful and
            # so we can show an appropriate messge in a displayer
            if @sql && @sql.match(/use\s+(\S+)/i)
                @database_changed = true
                @@database_name = $1
            end

            # if we're not given fields from a query we need to find the column
            # widths
            if @fields && @table && @fields.size > 0 &&
                    !@fields.first.respond_to?(:longest_length)
                self.class.send(:extend_fields!, @fields)
                @table.each do |row|
                    @fields.each_with_index do |field, i|
                        self.class.send(:update_longest!, field, row[i])
                    end
                end
            end
        end

        # Get the query associated with these results.
        #
        attr_reader :sql

        # Get the number of rows that were affected by the query.
        #
        attr_reader :affected_rows

        # Get the amount of elapsed time taken by the query.
        #
        attr_reader :elapsed

        # Determine if there are any results.
        #
        def any?
            !@table.nil?
        end

        # Determine if there are no results.
        #
        def empty?
            @table.nil?
        end

        # Get the number of rows available in the results.
        #
        def num_rows
            @table ? @table.size : 0
        end

        # Convenience helper to grab the value in the very first entry for those
        # times when the query only has one expected value returned.
        #
        def scalar
            self[0,0]
        end

        # Get an entire row as a hash or a single value from the table of
        # results. The value of row_j may be an integer index or a string column
        # name.
        #
        def [](row_i, row_j=nil)
            if @table
                if row = @table[row_i]
                    if row_j
                        return row[row_j] if Integer === row_j
                        if row_j = @fields.index{|f| f.name == row_j}
                            return row[row_j]
                        end
                    else
                        hash = {}
                        @fields.each_with_index{|f,i| hash[f.name] = row[i]}
                        return hash
                    end
                end
            end
            return nil
        end

        # Iterate through each row of the table hashed with the field names.
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

        # Conditionally delete rows from the results.
        #
        def delete_if(opts=nil, &block)
            if @table
                @table.delete_if do |row|
                    if opts == :row_hash
                        hash = {}
                        @fields.each_with_index{|f,i| hash[f.name] = row[i]}
                        yield(hash)
                    else
                        yield(row)
                    end
                end
            end
            self
        end

        # Show a set of results in a decent fashion.
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

        # Show a set of results with a single character separation.
        #
        def display_by_batch(io=$stdout)
            if @fields && @table
                fmt = (['%s'] * @fields.size).join(@field_separator)
                @table.each{|row| io.puts(fmt % row)}
            end
        end

        # Show a set of results line separated.
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

        # Show a summary line of the results.
        #
        def display_stats(io=$stdout, hdr='')
            estr = @elapsed ? " (#{'%0.2f'%@elapsed} sec)" : ''
            if @table
                if @database_changed
                    io.puts(hdr, "Database changed");
                    hdr = ''
                end
                s = 1 == @table.size ? 'row' : 'rows'
                io.puts(hdr, "#{@table.size} #{s} in set#{estr}")
            else
                if @database_changed
                    io.puts(hdr, "Database changed");
                else
                    s = 1 == @affected_rows ? 'row' : 'rows'
                    io.puts(hdr, "Query OK, #{@affected_rows} #{s} affected#{estr}")
                end
            end
        end

    end # class MySQLResults

end # module RSQL
