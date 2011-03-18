# Copyright (C) 2011 by brad+rsql@gigglewax.com
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

    require 'stringio'

    EvalResults = Struct.new(:value, :stdout)

    MySQLResults = Struct.new(:fields, :table)
    class MySQLResults
        def each_hash(&block)
            table.each do |row|
                hash = {}
                fields.each_with_index {|f,i| hash[f.name] = row[i]}
                yield(hash)
            end
        end
    end

    ########################################
    # A wrapper to parse and handle commands
    #
    class Commands

        Command = Struct.new(:content, :bangs, :is_ruby, :displayer)

        def self.mysql; @@mysql; end
        def self.mysql=(conn); @@mysql = conn; end

        def self.eval_context; @@eval_context; end
        def self.eval_context=(ctx); @@eval_context = ctx; end

        @@max_rows = 200
        def self.max_rows; @@max_rows; end
        def self.max_rows=(cnt); @@max_rows = cnt; end

        @@field_separator = ' '
        def self.field_separator; @@field_separator; end
        def self.field_separator=(sep); @@field_separator = sep; end

        def self.running?; @@running; end

        ########################################

        # split on separators, allowing for escaping
        #
        SEPARATORS = ';|!'
        def initialize(input)
            @cmds = []
            esc = ''
            bangs = {}
            match_before_bang = nil
            next_is_ruby = false

            input.scan(/[^#{SEPARATORS}]+.?/) do |match|
                if i = SEPARATORS.index(match[-1])
                    sep = SEPARATORS[i]
                    match.chop!

                    if match[-1] == ?\\
                        # unescape the separator and save the content away
                        esc << match[0..-2] << sep
                        next
                    end
                else
                    sep = nil
                end

                if esc.any?
                    esc << match
                    match = esc
                    esc = ''
                end

                if match_before_bang
                    match.split(/\s*,\s*/).each do |ent|
                        (key,val) = ent.split(/\s*=>\s*/)
                        bangs[key.strip] = val.to_sym
                    end
                    match = match_before_bang
                    match_before_bang = nil
                end

                if sep == ?!
                    match_before_bang = match
                    next
                end

                add_command(match, bangs, next_is_ruby, sep)

                bangs = {}
                next_is_ruby = sep == ?|
            end

            add_command(esc, bangs, next_is_ruby)
        end

        attr_reader :mysql_database_name

        def empty?
            return @cmds.empty?
        end

        def run!
            last_results = nil
            while @cmds.any?
                cmd = @cmds.shift
                results = run_command(cmd, last_results)
                return :done if results == :done

                if cmd.displayer == :pipe
                    last_results = results
                elsif MySQLResults === results
                    last_results = nil
                    method(cmd.displayer).call(results)
                elsif EvalResults === results
                    last_results = nil
                    if results.stdout && 0 < results.stdout.size
                        puts results.stdout.string
                    end
                    puts "=> #{results.value}" if results.value
                end
            end
        end

        ########################################
        private
        
            def add_command(content, bangs, is_ruby, separator=nil)
                content.strip!
                if content[0] == ?.
                    content.slice!(0)
                    is_ruby = true
                end

                if content.end_with?('\G')
                    # emulate mysql's \G output
                    content.slice!(-2,2)
                    displayer = :display_by_line
                elsif separator == ?|
                    displayer = :pipe
                else
                    displayer = :display_by_column
                end

                if content.any?
                    @cmds << Command.new(content, bangs, is_ruby, displayer)
                    return true
                end

                return false
            end

            def run_command(cmd, last_results)
                @@eval_context.bangs = cmd.bangs

                if cmd.is_ruby
                    stdout = cmd.displayer == :pipe ? StringIO.new : nil
                    value = @@eval_context.safe_eval(cmd.content, last_results, stdout)
                else
                    value = cmd.content
                end

                return :done if value == 'exit' || value == 'quit'

                if String === value
                    return mysql_eval(value, @@eval_context.bangs)
                end

                return EvalResults.new(value, stdout)
            end

            def mysql_eval(content, bangs)
                if content.match(/use\s+(\S+)/)
                    @mysql_database_name = $1
                end

                begin
                    results = @@mysql.query(content)
                rescue Mysql::Error => ex
                    $stderr.puts(ex.message)
                end

                bangs.merge!(@@eval_context.bangs)

                return process_results(results, bangs)
            end

            # extract mysql results into our own table so we can predetermine the
            # lengths of columns and give users a chance to reformat column data
            # before it's displayed (via the bang maps)
            #
            HEX_RANGE = (Mysql::Field::TYPE_TINY_BLOB..Mysql::Field::TYPE_STRING)
            def process_results(results, bangs, max_rows=@@max_rows)
                return nil unless results && 0 < results.num_rows

                if max_rows < results.num_rows
                    $stderr.puts "refusing to process this much data: #{results.num_rows} rows"
                    return nil
                end

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
                        val = vals[i]
                        if bang = bangs[field.name]
                            val = @@eval_context.bang_eval(bang, val)
                        end
                        if val.nil?
                            val = 'NULL'
                        elsif HEX_RANGE.include?(field.type) && val =~ /[^[:print:]\s]/
                            val = @@eval_context.to_hexstr(val)
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

                return MySQLResults.new(fields, results_table)
            end

            # show a set of results in a decent fashion
            #
            def display_by_column(results)
                return unless results.fields && results.table

                fmts = []
                names = []
                len = 0
                results.fields.each do |field|
                    fmts << "%-#{field.longest_length}s"
                    names << field.name
                    len += field.longest_length
                end

                fmt = fmts.join(@@field_separator)
                puts(fmt % names, '-' * (len + fmts.length))
                results.table.each{|row| puts(fmt % row)}
            end

            # show a set of results with a single character separation
            #
            def display_by_batch(results)
                return unless results.fields && results.table

                fmt = (['%s'] * results.fields.size).join(@@field_separator)
                puts fmt % results.fields.collect{|f| f.name}
                results.table.each{|row| puts(fmt % row)}
            end

            # show a set of results line separated
            #
            def display_by_line(results)
                return unless results.fields && results.table

                namelen = 0
                results.fields.each do |field|
                    namelen = field.name.length if namelen < field.name.length
                end
                namelen += 1

                results.table.each_with_index do |row, i|
                    puts("#{'*'*30} #{i+1}. row #{'*'*30}")
                    row.each_with_index do |val, vi|
                        printf("%#{namelen}s #{val}#{$/}", results.fields[vi].name + ':')
                    end
                end
            end

    end # class Commands

end # module RSQL
