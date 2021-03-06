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

module RSQL

    require 'ostruct'
    require 'time'

    # todo: add a simple way to interpolate directly within a sql query about to
    # be exec'd (so we can save stuff from other queries in variables that can
    # then be ref'd in a new query all on the cmd line)

    ################################################################################
    # This class wraps all dynamic evaluation and serves as the reflection class
    # for adding methods dynamically.
    #
    class EvalContext

        Registration = Struct.new(:name, :args, :bangs, :block, :usage,
                                  :desc, :source, :source_fn)

        HEXSTR_LIMIT = 32

        def initialize(options=OpenStruct.new)
            @opts         = options
            @prompt       = nil
            @verbose      = @opts.verbose
            @hexstr_limit = HEXSTR_LIMIT
            @results      = nil

            @loaded_fns         = []
            @loaded_fns_state   = {}
            @init_registrations = []
            @bangs              = {}
            @global_bangs       = {}

            @registrations = {
                :version => Registration.new('version', [], {},
                    method(:version),
                    'version',
                    'Version information about RSQL, the client, and the server.'),
                :help => Registration.new('help', [], {},
                    method(:help),
                    'help',
                    'Show short syntax help.'),
                :grep => Registration.new('grep', [], {},
                    method(:grep),
                    'grep(string_or_regexp, *options)',
                    'Show results when regular expression matches any part of the content.'),
                :reload => Registration.new('reload', [], {},
                    method(:reload),
                    'reload',
                    'Reload the rsqlrc file.'),
                :desc => Registration.new('desc', [], {},
                    method(:desc),
                    'desc(name)',
                    'Describe the content of a recipe.'),
                :history => Registration.new('history', [], {},
                    method(:history),
                    'history(cnt=1)',
                    'Print recent queries made (request a count or use :all for entire list).'),
                :set_max_rows => Registration.new('set_max_rows', [], {},
                    Proc.new{|r| MySQLResults.max_rows = r},
                    'set_max_rows(max)',
                    'Set the maximum number of rows to process.'),
                :max_rows => Registration.new('max_rows', [], {},
                    Proc.new{MySQLResults.max_rows},
                    'max_rows',
                    'Get the maximum number of rows to process.'),
            }
        end

        attr_reader :prompt
        attr_accessor :bangs, :verbose

        def call_init_registrations
            @init_registrations.each do |sym|
                reg = @registrations[sym]
                sql = reg.block.call(*reg.args)
                query(sql) if String === sql
            end
        end

        def load(fn, opt=nil)
            @loaded_fns << fn unless @loaded_fns_state.key?(fn)
            @loaded_fns_state[fn] = :loading

            # this should only be done after we have established a
            # mysql connection, so this option allows rsql to load the
            # init file immediately and then later make the init
            # registration calls--we set this as an instance variable
            # to allow for loaded files to call load again and yet
            # still maintain the skip logic
            if opt == :skip_init_registrations
                reset_skipping = @skipping_init_registrations = true
            end

            ret = Thread.new {
                begin
                    eval(File.read(fn), binding, fn)
                    nil
                rescue Exception => ex
                    ex
                end
            }.value

            if Exception === ret
                @loaded_fns_state[fn] = :failed
                if @verbose
                    $stderr.puts("#{ret.class}: #{ret.message}", ex.backtrace)
                else
                    bt = ret.backtrace.collect{|line| line.start_with?(fn) ? line : nil}.compact
                    $stderr.puts("#{ret.class}: #{ret.message}", bt, '')
                end
                ret = false
            else
                @loaded_fns_state[fn] = :loaded
                call_init_registrations unless @skipping_init_registrations
                ret = true
            end

            @skipping_init_registrations = false if reset_skipping

            return ret
        end

        def reload
            # some files may be loaded by other files, if so, we don't want to
            # reload them again here
            @loaded_fns.each{|fn| @loaded_fns_state[fn] = nil}
            @loaded_fns.each{|fn| self.load(fn, :skip_init_registrations) if @loaded_fns_state[fn] == nil}

            # load up the inits after all the normal registrations are ready
            call_init_registrations

            # report all the successfully loaded ones
            loaded = []
            @loaded_fns.each{|fn,state| loaded << fn if @loaded_fns_state[fn] == :loaded}
            puts "loaded: #{loaded.inspect}"
        end

        def bang_eval(field, val)
            # allow individual bangs to override global ones, even if they're nil
            if @bangs.key?(field)
                bang = @bangs[field]
            else
                # todo: this will run on *every* value--this should be optimized
                # so that it's only run once on each query's result column
                # fields and then we'd know if any bangs are usable and pased in
                # for each result value
                @global_bangs.each do |m,b|
                    if (String === m && m == field.to_s) ||
                        (Regexp === m && m.match(field.to_s))
                        bang = b
                        break
                    end
                end
            end

            if bang
                begin
                    val = Thread.new{ eval("#{bang}(val)") }.value
                rescue Exception => ex
                    if @verbose
                        $stderr.puts("#{ex.class}: #{ex.message}", ex.backtrace)
                    else
                        $stderr.puts(ex.message, ex.backtrace.first)
                    end
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
                # in order to print out errors in a loaded script so
                # that we have file/line info, we need to rescue their
                # exceptions inside the evaluation
                th = Thread.new do
                    eval('begin;' << content << %q{
                      rescue Exception => ex
                        if @verbose
                            $stderr.puts("#{ex.class}: #{ex.message}", ex.backtrace)
                        else
                            bt = []
                            ex.backtrace.each do |t|
                              break if t.include?('bin/rsql')
                              bt << t unless t.include?('lib/rsql/') || t.include?('(eval)')
                            end
                            $stderr.puts(ex.message.gsub(/\(eval\):\d+:/,''),bt)
                        end
                      end
                    })
                end
                value = th.value
            rescue Exception => ex
                $stderr.puts(ex.message.gsub(/\(eval\):\d+:/,''))
            ensure
                $stdout = orig_stdout if stdout
            end

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
            return bin if bin.nil?

            cnt = 0
            str = prefix << bin.gsub(/./m) do |ch|
                if limit
                    if limit < 1
                        cnt += 1
                        next
                    end
                    limit -= 1
                end
                '%02x' % ch.bytes.first
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

            # Used by params() and desc() to find where a block begins.
            #
            def locate_block_start(name, io, lineno, ending=nil, source=nil)
                i = 0
                param_line = ''
                params = nil

                while line = io.gets
                    i += 1
                    next if i < lineno
                    source << line if source

                    # give up if no start found within 20 lines
                    break if lineno + 20 < i
                    if m = line.match(/(\{|do\b)(.*)$/)
                        if ending
                            ending << (m[1] == '{' ? '\}' : 'end')
                        end
                        # adjust line to be the remainder after the start
                        param_line = m[2]
                        break
                    end
                end

                if m = param_line.match(/^\s*\|([^\|]*)\|/)
                    return "(#{m[1]})"
                else
                    return nil
                end
            end

            # Attempt to locate the parameters of a given block by
            # searching its source.
            #
            def params(name, block)
                params = nil

                if block.arity != 0 && block.inspect.match(/@(.+):(\d+)>$/)
                    fn = $1
                    lineno = $2.to_i

                    if fn == '(eval)'
                        $stderr.puts "refusing to search an eval block for :#{name}"
                        return ''
                    end

                    File.open(fn) do |f|
                        params = locate_block_start(name, f, lineno)
                    end
                end

                if params.nil?
                    $stderr.puts "unable to locate params for :#{name}" if @verbose
                    return ''
                end

                return params
            end

            # Similiar to the MySQL "desc" command, show the content
            # of nearly any registered recipe including where it was
            # sourced (e.g. what file:line it came from).
            #
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

                    reg.source_fn = "#{fn}:#{lineno}"

                    File.open(fn) do |f|
                        source = ''
                        ending = ''

                        locate_block_start(sym, f, lineno, ending, source)
                        break if ending.empty?

                        while line = f.gets
                            source << line
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

                if reg.source && !reg.source.empty?
                    puts '', "[#{reg.source_fn}]", '', reg.source
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

            # Show a short amount of information about acceptable syntax.
            #
            def help            # :doc:
                puts <<EOF

Converting values on the fly:

  rsql> select name, value from rsql_example ! value => humanize_bytes;

Inspect MySQL connection:

  rsql> . p [host_info, proto_info];

Escape strings:

  rsql> . p escape_string('drop table "here"');

Show only rows containing a string:

  rsql> select * from rsql_example | grep 'mystuff';

Show only rows containing a regular expression with case insensitive search:

  rsql> select * from rsql_example | grep /mystuff/i;

EOF
            end

            # Provide a helper utility in the event a registered method would
            # like to make its own queries. See MySQLResults.query for more
            # details regarding the other arguments available.
            #
            def query(content, *args) # :doc:
                MySQLResults.query(content, self, *args)
            end

            # Show the most recent queries made to the MySQL server in this
            # session. Default is to show the last one.
            #
            def history(cnt=1) # :doc:
                if h = MySQLResults.history(cnt)
                    h.each{|q| puts '', q}
                end
                nil
            end

            # Remove all rows that do NOT match the expression. Returns true if
            # any matches were found.
            #
            # Options:
            #   :fixed   => indicates that the string should be escaped of any
            #               special characters
            #   :nocolor => will not add color escape codes to indicate the
            #               match
            #   :inverse => reverses the regular expression match
            #
            def grep(pattern, *gopts) # :doc:
                nocolor = gopts.include?(:nocolor)

                if inverted = gopts.include?(:inverse)
                    # there's no point in coloring matches we are removing
                    nocolor = true
                end

                if gopts.include?(:fixed)
                    regexp = Regexp.new(/#{Regexp.escape(pattern.to_str)}/)
                elsif Regexp === pattern
                    regexp = pattern
                else
                    regexp = Regexp.new(/#{pattern.to_str}/)
                end

                rval = inverted

                @results.delete_if do |row|
                    matched = false
                    row.each do |val|
                        val = val.to_s unless String === val
                        if nocolor
                            if matched = !val.match(regexp).nil?
                                rval = inverted ? false : true
                                break
                            end
                        else
                            # in the color case, we want to colorize all hits in
                            # all columns, so we can't early terminate our
                            # search
                            if val.gsub!(regexp){|m| "\e[31;1m#{m}\e[0m"}
                                matched = true
                                rval = inverted ? false : true
                            end
                        end
                    end
                    inverted ? matched : !matched
                end

                return rval
            end

            # Register bangs to evaluate on all displayers as long as a column
            # match is located. Bang keys may be either exact string matches or
            # regular expressions.
            #
            def register_global_bangs(bangs)
                @global_bangs.merge!(bangs)
            end

            # Exactly like register below except in addition to registering as
            # a usable call for later, we will also use these as soon as we
            # have a connection to MySQL.
            #
            def register_init(sym, *args, &block) # :doc:
                register(sym, *args, &block)
                @init_registrations << sym unless @init_registrations.include?(sym)
            end

            # If given a block, allow the block to be called later, otherwise,
            # create a method whose sole purpose is to dynmaically generate
            # sql with variable interpolation.
            #
            def register(sym, *args, &block) # :doc:
                if m = caller.first.match(/^([^:]+:\d+)/)
                    source_fn = m[1]
                end

                name = usage = sym.to_s

                if Hash === args.last
                    bangs = args.pop
                    desc = bangs.delete(:desc)
                else
                    bangs = {}
                end

                desc = '' unless desc

                if block.nil?
                    source = args.pop.strip
                    sql = squeeze!(source.dup)

                    argstr = args.join(',')
                    usage << "(#{argstr})" unless argstr.empty?

                    blockstr = %{lambda{|#{argstr}|%{#{sql}} % [#{argstr}]}}
                    block = Thread.new{ eval(blockstr) }.value
                    args = []
                else
                    source = nil
                    usage << params(name, block)
                end

                @registrations[sym] = Registration.new(name, args, bangs, block, usage,
                                                       desc, source, source_fn)
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
                abbrev = ['B ','KB','MB','GB','TB','PB','EB','ZB','YB']
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
            def squeeze!(sql)    # :doc:
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
                elsif MySQLResults.conn.respond_to?(sym)
                    MySQLResults.conn.send(sym, *args)
                else
                    super.method_missing(sym, *args, &block)
                end
            end

    end # class EvalContext

end # module RSQL
