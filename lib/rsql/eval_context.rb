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

    require 'time'

    ################################################################################
    # This class wraps all dynamic evaluation and serves as the reflection
    # class for adding methods dynamically.
    #
    class EvalContext

        Registration = Struct.new(:name, :args, :bangs, :block, :usage, :desc, :source)

        HEXSTR_LIMIT = 32

        def initialize(verbose=false)
            @verbose      = verbose
            @hexstr_limit = HEXSTR_LIMIT
            @results      = nil
            @last_query   = nil

            @loaded_fns         = []
            @init_registrations = []
            @bangs              = {}

            @registrations = {
                :version => Registration.new('version', [], {},
                                             method(:version),
                                             'version',
                                             'RSQL version information.'),
                :reload => Registration.new('reload', [], {},
                                            method(:reload),
                                            'reload',
                                            'Reload the rsqlrc file.'),
                :desc => Registration.new('desc', [], {},
                                          method(:desc),
                                          'desc',
                                          'Describe the content of a recipe.'),
                :last_query => Registration.new('last_query', [], {},
                                                Proc.new{puts(@last_query)},
                                                'last_query',
                                                'Print the last query made from generated results.'),
                :set_max_rows => Registration.new('set_max_rows', [], {},
                                                  Proc.new{|r| MySQLResults.max_rows = r},
                                                  'set_max_rows',
                                                  'Set the maximum number of rows to process.'),
                :max_rows => Registration.new('max_rows', [], {},
                                              Proc.new{MySQLResults.max_rows},
                                              'max_rows',
                                              'Get the maximum number of rows to process.'),
            }
        end

        attr_accessor :bangs, :verbose

        def call_init_registrations
            @init_registrations.each do |sym|
                reg = @registrations[sym]
                sql = reg.block.call(*reg.args)
                query(sql) if String === sql
            end
        end

        def load(fn, init=true)
            ret = Thread.new {
                begin
                    eval(File.read(fn), binding, fn)
                    nil
                rescue Exception => ex
                    ex
                end
            }.value

            if Exception === ret
                bt = ret.backtrace.collect{|line| line.start_with?(fn) ? line : nil}.compact
                $stderr.puts("#{ret.class}: #{ret.message}", bt, '')
            else
                @loaded_fns << fn unless @loaded_fns.include?(fn)
                call_init_registrations if init
            end
        end

        def reload
            @loaded_fns.each{|fn| self.load(fn, false)}
            puts "loaded: #{@loaded_fns.inspect}"
        end

        def bang_eval(field, val)
            if bang = @bangs[field]
                begin
                    val = Thread.new{ eval("$SAFE=2;#{bang}(val)") }.value
                rescue Exception => ex
                    $stderr.puts(ex.message, ex.backtrace.first)
                end
            end

            return val
        end

        # Safely evaluate Ruby content within our context.
        #
        def safe_eval(content, results, stdout)
            @results = results

            # allow a simple reload to be called directly as it requires a
            # little looser safety valve...
            if 'reload' == content
                reload
                return
            end

            # same relaxed call to load too
            if m = content.match(/^\s*load\s+'(.+)'\s*$/)
                self.load(m[1])
                return
            end

            # help out the poor user and fix up any describes
            # requested so they don't need to remember that it needs
            # to be a symbol passed in
            if m = content.match(/^\s*desc\s+([^:]\S+)\s*$/)
                content = "desc :#{m[1]}"
            end

            if stdout
                # capture stdout
                orig_stdout = $stdout
                $stdout = stdout
            end

            begin
                value = Thread.new{ eval('$SAFE=2;' + content) }.value
            rescue Exception => ex
                if @verbose
                    $stderr.puts("#{ex.class}: #{ex.message}", ex.backtrace)
                else
                    $stderr.puts(ex.message.gsub(/\(eval\):\d+:/,''))
                end
            ensure
                $stdout = orig_stdout if stdout
            end

            @last_query = value if String === value

            return value
        end

        # Provide a list of tab completions given the prompted value.
        #
        def complete(str)
            if str[0] == ?.
                str.slice!(0)
                prefix = '.'
            else
                prefix = ''
            end

            ret  = MySQLResults.complete(str)
            ret += @registrations.keys.sort_by{|sym|sym.to_s}.collect do |sym|
                name = sym.to_s
                if name.start_with?(str)
                    prefix + name
                else
                    nil
                end
            end

            ret.compact!
            ret
        end

        # Reset the hexstr limit back to the default value.
        #
        def reset_hexstr_limit
            @hexstr_limit = HEXSTR_LIMIT
        end

        # Convert a binary string value into a hexadecimal string.
        #
        def to_hexstr(bin, limit=@hexstr_limit, prefix='0x')
            cnt = 0
            str = prefix << bin.gsub(/./m) do |ch|
                if limit
                    if limit < 1
                        cnt += 1
                        next
                    end
                    limit -= 1
                end
                '%02x' % ch[0]
            end

            if limit && limit < 1 && 0 < cnt
                str << "... (#{cnt} bytes hidden)"
            end

            return str
        end

        ########################################
        private

            # Display a listing of all registered helpers.
            #
            def list            # :doc:
                usagelen = 0
                desclen  = 0

                sorted = @registrations.values.sort_by do |reg|
                    usagelen = reg.usage.length if usagelen < reg.usage.length
                    longest_line = reg.desc.split(/\r?\n/).collect{|l|l.length}.max
                    desclen = longest_line if longest_line && desclen < longest_line
                    reg.usage
                end

                fmt = "%-#{usagelen}s  %s#{$/}"

                printf(fmt, 'usage', 'description')
                puts '-'*(usagelen+2+desclen)

                sorted.each do |reg|
                    printf(fmt, reg.usage, reg.desc)
                end

                return nil
            end

            def params(block)
                params = ''

                if block.arity != 0 && block.arity != -1 &&
                        block.inspect.match(/@(.+):(\d+)>$/)
                    fn = $1
                    lineno = $2.to_i

                    if fn == '(eval)'
                        $stderr.puts 'refusing to search an eval block'
                        return params
                    end

                    File.open(fn) do |f|
                        i = 0
                        found = false
                        while line = f.gets
                            i += 1
                            next if i < lineno

                            unless found
                                # give up if no start found within 20
                                # lines
                                break if lineno + 20 < i
                                if m = line.match(/(\{|do)(.*)$/)
                                    # adjust line to be the remainder
                                    # after the start
                                    line = m[2]
                                    found = true
                                else
                                    next
                                end
                            end

                            if m = line.match(/^\s*\|([^\|]*)\|/)
                                params = "(#{m[1]})"
                                break
                            end

                            # if the params aren't here then we'd
                            # better only have whitespace otherwise
                            # this block doesn't have params...even
                            # though arity says it should
                            next if line.match(/^\s*$/)
                            $stderr.puts 'unable to locate params'
                            break
                        end
                    end
                end

                return params
            end

            def desc(sym)
                unless Symbol === sym
                    $stderr.puts("must provide a Symbol--try prefixing it with a colon (:)")
                    return
                end

                unless reg = @registrations[sym]
                    $stderr.puts "nothing registered as #{sym}"
                    return
                end

                if Method === reg.block
                    $stderr.puts "refusing to describe the #{sym} method"
                    return
                end

                if !reg.source && reg.block.inspect.match(/@(.+):(\d+)>$/)
                    fn = $1
                    lineno = $2.to_i

                    if fn == __FILE__
                        $stderr.puts "refusing to describe EvalContext##{sym}"
                        return
                    end

                    if fn == '(eval)'
                        $stderr.puts 'unable to describe body for an eval block'
                        return
                    end

                    File.open(fn) do |f|
                        source = ''
                        i = 0
                        ending = nil
                        found = false

                        while line = f.gets
                            i += 1
                            next unless ending || i == lineno
                            source << line
                            unless ending
                                unless m = line.match(/\{|do/)
                                    $stderr.puts "unable to locate block beginning at #{fn}:#{lineno}"
                                    return
                                end
                                ending = m[0] == '{' ? '\}' : 'end'
                                next
                            end
                            if m = line.match(/^#{ending}/)
                                found = true
                                break
                            end
                        end

                        if found
                            reg.source = source
                        else
                            reg.source = ''
                        end
                    end
                end

                if reg.source && reg.source.any?
                    puts reg.source
                else
                    $stderr.puts "unable to locate body for #{sym}"
                end
            end

            # Show all the pertinent version data we have about our
            # software and the mysql connection.
            #
            def version         # :doc:
                puts "rsql:v#{RSQL::VERSION} client:v#{MySQLResults.conn.client_info} " \
                     "server:v#{MySQLResults.conn.server_info}"
            end

            # Provide a helper utility in the event a registered
            # method would like to make its own queries.
            #
            def query(content, *args) # :doc:
                MySQLResults.query(content, self, *args)
            end

            # Exactly like register below except in addition to registering as
            # a usable call for later, we will also use these as soon as we
            # have a connection to MySQL.
            #
            def register_init(sym, *args, &block) # :doc:
                register(sym, *args, &block)
                @init_registrations << sym
            end

            # If given a block, allow the block to be called later, otherwise,
            # create a method whose sole purpose is to dynmaically generate
            # sql with variable interpolation.
            #
            def register(sym, *args, &block) # :doc:
                name = usage = sym.to_s

                if Hash === args.last
                    bangs = args.pop
                    desc = bangs.delete(:desc)
                else
                    bangs = {}
                end

                desc = '' unless desc

                if block.nil?
                    source = args.pop
                    sql = sqeeze!(source.dup)

                    argstr = args.join(',')
                    usage << "(#{argstr})" unless argstr.empty?

                    blockstr = %{$SAFE=2;lambda{|#{argstr}|%{#{sql}} % [#{argstr}]}}
                    block = Thread.new{ eval(blockstr) }.value
                    args = []
                else
                    source = nil
                    usage << params(block)
                end

                @registrations[sym] = Registration.new(name, args, bangs, block, usage, desc, source)
            end

            # Convert a list of values into a comma-delimited string,
            # optionally with each value in single quotes.
            #
            def to_list(vals, quoted=false) # :doc:
                vals.collect{|v| quoted ? "'#{v}'" : v.to_s}.join(',')
            end

            # Convert a collection of values into hexadecimal strings.
            #
            def hexify(*ids)    # :doc:
                ids.collect do |id|
                    case id
                    when String
                        if id.start_with?('0x')
                            id
                        else
                            '0x' << id
                        end
                    when Integer
                        '0x' << id.to_s(16)
                    else
                        raise "invalid id: #{id.class}"
                    end
                end.join(',')
            end

            # Convert a number of bytes into a human readable string.
            #
            def humanize_bytes(bytes) # :doc:
                abbrev = ['B','KB','MB','GB','TB','PB','EB','ZB','YB']
                bytes = bytes.to_i
                fmt = '%7.2f'

                abbrev.each_with_index do |a,i|
                    if bytes < (1024**(i+1))
                        if i == 0
                            return "#{fmt % bytes} B"
                        else
                            b = bytes / (1024.0**i)
                            return "#{fmt % b} #{a}"
                        end
                    end
                end

                return bytes.to_s
            end

            # Convert a human readable string of bytes into an integer.
            #
            def dehumanize_bytes(str) # :doc:
                abbrev = ['B','KB','MB','GB','TB','PB','EB','ZB','YB']

                if str =~ /(\d+(\.\d+)?)\s*(\w+)?/
                    b = $1.to_f
                    if $3
                        i = abbrev.index($3.upcase)
                        return (b * (1024**i)).round
                    else
                        return b.round
                    end
                end

                raise "unable to parse '#{str}'"
            end

            # Show a nice percent value of a decimal string.
            #
            def humanize_percentage(decimal, precision=1) # :doc:
                if decimal.nil? || decimal == 'NULL'
                    'NA'
                else
                    "%5.#{precision}f%%" % (decimal.to_f * 100)
                end
            end

            # Convert a time into a relative string from now.
            #
            def relative_time(dt) # :doc:
                return dt unless String === dt

                now = Time.now.utc
                theirs = Time.parse(dt + ' UTC')
                if theirs < now
                    diff = now - theirs
                    postfix = 'ago'
                else
                    diff = theirs - now
                    postfix = 'from now'
                end

                fmt = '%3.0f'

                [
                 [31556926.0, 'years'],
                 [2629743.83, 'months'],
                 [86400.0,    'days'],
                 [3600.0,     'hours'],
                 [60.0,       'minutes']
                ].each do |(limit, label)|
                    if (limit * 1.5) < diff
                        return "#{fmt % (diff / limit)} #{label} #{postfix}"
                    end
                end

                return "#{fmt % diff} seconds #{postfix}"
            end

            # Squeeze out any spaces.
            #
            def sqeeze!(sql)    # :doc:
                sql.gsub!(/\s+/,' ')
                sql.strip!
                sql << ';' unless sql[-1] == ?;
                sql
            end

            # Safely store an object into a file keeping at most one
            # backup if the file already exists.
            #
            def safe_save(obj, name) # :doc:
                name += '.yml' unless File.extname(name) == '.yml'
                tn = "#{name}.tmp"
                File.open(tn, 'w'){|f| YAML.dump(obj, f)}
                if File.exist?(name)
                    bn = "#{name}~"
                    File.unlink(bn) if File.exist?(bn)
                    File.rename(name, bn)
                end
                File.rename(tn, name)
                puts "Saved: #{name}"
            end

            def method_missing(sym, *args, &block)
                if reg = @registrations[sym]
                    @bangs.merge!(reg.bangs)
                    final_args = reg.args + args
                    reg.block.call(*final_args)
                elsif MySQLResults.respond_to?(sym)
                    MySQLResults.send(sym, *args)
                else
                    super.method_missing(sym, *args, &block)
                end
            end

    end # class EvalContext

end # module RSQL
