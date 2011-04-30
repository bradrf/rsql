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

    VERSION = '1.1'

    require 'stringio'

    EvalResults = Struct.new(:value, :stdout)

    ########################################
    # A wrapper to parse and handle commands
    #
    class Commands

        Command = Struct.new(:content, :bangs, :declarator, :displayer)

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
                    new_bangs = {}
                    match.split(/\s*,\s*/).each do |ent|
                        (key,val) = ent.split(/\s*=>\s*/)
                        unless key && val
                            # they are using a bang but have no maps
                            # so we assume this is a != or something
                            # similar and let it go through unmapped
                            esc = match_before_bang + '!' + match
                            match_before_bang = nil
                            break
                        end
                        new_bangs[key.strip] = val.to_sym
                    end
                    next unless match_before_bang
                    match = match_before_bang
                    match_before_bang = nil
                    bangs.merge!(new_bangs)
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

        def empty?
            return @cmds.empty?
        end

        def run!(eval_context)
            last_results = nil
            while @cmds.any?
                cmd = @cmds.shift
                results = run_command(cmd, last_results, eval_context)
                return :done if results == :done

                if cmd.displayer == :pipe
                    last_results = results
                elsif MySQLResults === results
                    last_results = nil
                    results.send(cmd.displayer)
                elsif EvalResults === results
                    last_results = nil
                    if results.stdout && 0 < results.stdout.size
                        puts results.stdout.string
                    end
                    puts "=> #{results.value.inspect}" if results.value
                end
            end
        end

        ########################################
        private
        
            def add_command(content, bangs, is_ruby, separator=nil)
                content.strip!

                case content[0]
                when ?.
                    content.slice!(0)
                    declarator = :ruby
                when ?@
                    content.slice!(0)
                    declarator = :iterator
                else
                    declarator = is_ruby ? :ruby : nil
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
                    @cmds << Command.new(content, bangs, declarator, displayer)
                    return true
                end

                return false
            end

            def run_command(cmd, last_results, eval_context)
                ctx = EvalContext::CommandContext.new

                # set up to allow an iterator to run up to 100,000 times
                100000.times do |i|
                    eval_context.bangs = cmd.bangs

                    if cmd.declarator
                        ctx.index = i
                        ctx.last_results = last_results
                        stdout = cmd.displayer == :pipe ? StringIO.new : nil
                        value = eval_context.safe_eval(cmd.content, ctx, stdout)
                    else
                        value = cmd.content
                    end

                    return :done if value == 'exit' || value == 'quit'

                    if String === value
                        begin
                            last_results = MySQLResults.query(value, eval_context)
                        rescue MySQLResults::MaxRowsException => ex
                            $stderr.puts "refusing to process #{ex.rows} rows (max: #{ex.max})"
                        rescue MysqlError => ex
                            $stderr.puts ex.message
                        rescue Exception => ex
                            $stderr.puts ex.inspect
                            raise
                        end
                    else
                        last_results = EvalResults.new(value, stdout)
                    end

                    break unless ctx.incomplete
                end

                return last_results
            end

    end # class Commands

end # module RSQL
