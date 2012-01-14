#--
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

    require 'stringio'

    EvalResults = Struct.new(:value, :stdout)

    ########################################
    # A wrapper to parse and handle commands
    #
    class Commands

        Command = Struct.new(:content, :bangs, :declarator, :displayer)

        ########################################

        # Split commands on these characters.
        SEPARATORS = ';|!'

        # Split on separators, allowing for escaping;
        #
        def initialize(input, default_displayer)
            @default_displayer = default_displayer
            @cmds = []
            esc = ''
            bangs = {}
            match_before_bang = nil
            in_pipe_arg = false
            next_is_ruby = false

            input.scan(/[^#{SEPARATORS}]+.?/) do |match|
                orig_match = match

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

                unless esc.empty?
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

                if sep == ?|
                    # we've split on a pipe so we need to handle the
                    # case where ruby code is declaring a block with
                    # arguments (e.g. {|x| p x} or do |x| p x end)
                    if in_pipe_arg
                        in_pipe_arg = false
                        esc << match << '|'
                        next
                    elsif orig_match =~ /\{\s*|do\s*/
                        in_pipe_arg = true
                        esc << match << '|'
                        next
                    end
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

        def concat(other)
            @cmds.concat(other)
        end

        def last
            @cmds.last
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
                    if MySQLResults === results.value
                        # This happens if their recipe returns MySQL
                        # results...just display it like above.
                        results.value.send(cmd.displayer)
                    else
                        if results.stdout && 0 < results.stdout.size
                            puts results.stdout.string
                        end
                        puts "=> #{results.value.inspect}" if results.value
                    end
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
                    displayer = @default_displayer
                end

                unless content.empty?
                    @cmds << Command.new(content, bangs, declarator, displayer)
                    return true
                end

                return false
            end

            def run_command(cmd, last_results, eval_context)
                eval_context.bangs = cmd.bangs

                if cmd.declarator
                    stdout = cmd.displayer == :pipe ? StringIO.new : nil
                    value = eval_context.safe_eval(cmd.content, last_results, stdout)
                    if String === value
                        cmds = Commands.new(value, cmd.displayer)
                        unless cmds.empty?
                            # need to carry along the bangs into the
                            # last command so we don't lose them
                            if cmds.last.bangs.empty? && cmd.bangs.any?
                                cmds.last.bangs = cmd.bangs
                            end
                            @cmds = cmds.concat(@cmds)
                        end
                        return
                    end
                else
                    value = cmd.content
                end

                return :done if value == 'exit' || value == 'quit'

                if String === value
                    begin
                        last_results = MySQLResults.query(value, eval_context)
                    rescue MySQLResults::MaxRowsException => ex
                        $stderr.puts "refusing to process #{ex.rows} rows (max: #{ex.max})--" <<
                            "consider raising this via set_max_rows"
                    rescue Mysql::Error => ex
                        $stderr.puts ex.message
                    rescue Exception => ex
                        $stderr.puts ex.inspect
                        raise
                    end
                else
                    last_results = EvalResults.new(value, stdout)
                end

                return last_results
            end

    end # class Commands

end # module RSQL
