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

    ################################################################################
    # This class wraps all dynamic evaluation and serves as the reflection
    # class for adding new methods dynamically.
    #
    class EvalContext

        Registration = Struct.new(:name, :args, :bangs, :block, :usage, :desc)

        CommandContext = Struct.new(:index, :incomplete, :last_results, :state)

        HEXSTR_LIMIT = 32

        def initialize
            @hexstr_limit = HEXSTR_LIMIT
            @last_cmd = nil

            @loaded_fns = []
            @init_registrations = []
            @bangs = {}

            @registrations = {
                :version => Registration.new('version', [], {},
                                             method(:version),
                                             'version',
                                             'RSQL version information.'),
                :reload => Registration.new('reload', [], {},
                                            method(:reload),
                                            'reload',
                                            'Reload the rsqlrc file.'),
                :last_cmd => Registration.new('last_cmd', [], {},
                                              Proc.new{puts @last_cmd},
                                              'last_cmd',
                                              'Print the last command generated.'),
            }
        end

        attr_accessor :bangs

        def call_init_registrations(mysql)
            @init_registrations.each do |sym|
                reg = @registrations[sym]
                sql = reg.block.call(*reg.args)
                mysql.query(sql) if String === sql
            end
        end

        def load(fn)
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
            end
        end

        def reload
            @loaded_fns.each{|fn| self.load(fn)}
            puts "loaded: #{@loaded_fns.inspect}"
        end

        def bang_eval(field, val)
            if bang = @bangs[field]
                begin
                    val = Thread.new{ eval("$SAFE=3;#{bang}(val)") }.value
                rescue Exception => ex
                    $stderr.puts(ex.message, ex.backtrace.first)
                end
            end

            return val
        end

        # safely evaluate Ruby content within our context
        #
        def safe_eval(content, context, stdout)
            @command_context = context

            # allow a simple reload to be called directly as it requires a
            # little looser safety valve...
            if 'reload' == content
                reload
                return
            end

            # same relaxed call to load too
            if m = /^\s*load\s+'(.+)'\s*$/.match(content)
                self.load(m[1])
                return
            end

            if stdout
                # capture stdout
                orig_stdout = $stdout
                $stdout = stdout
            end

            begin
                value = Thread.new{ eval('$SAFE=3;' + content) }.value
            rescue Exception => ex
                $stderr.puts(ex.message.gsub(/\(eval\):\d+:/,''))
            ensure
                $stdout = orig_stdout if stdout
            end

            @last_cmd = value if String === value

            return value
        end

        # provide a list of tab completions given the prompted value
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

        # reset the hexstr limit back to the default value
        #
        def reset_hexstr_limit
            @hexstr_limit = HEXSTR_LIMIT
        end

        # convert a binary value into a hexadecimal string
        #
        def to_hexstr(bin, prefix='0x')
            limit = @hexstr_limit
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

            # display a listing of all registered helpers
            #
            def list
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

            # show all the pertinent version data we have about our
            # software and the mysql connection
            #
            def version
                puts "rsql:v#{RSQL::VERSION} client:v#{MySQLResults.conn.client_info} " \
                     "server:v#{MySQLResults.conn.server_info}"
            end

            # provide a helper utility in the event a registered
            # method would like to make it's own queries
            #
            def query(content)
                MySQLResults.query(content, self)
            end

            # exactly like register below except in addition to registering as
            # a usable call for later, we will also use these as soon as we
            # have a connection to MySQL.
            #
            def register_init(sym, *args, &block)
                register(sym, *args, &block)
                @init_registrations << sym
            end

            # if given a block, allow the block to be called later, otherwise,
            # create a method whose sole purpose is to dynmaically generate
            # sql with variable interpolation
            #
            def register(sym, *args, &block)
                name = usage = sym.to_s

                if Hash === args.last
                    bangs = args.pop
                    desc = bangs.delete(:desc)
                else
                    bangs = {}
                end

                desc = '' unless desc

                if block.nil?
                    sql = args.pop
                    sql.gsub!(/\s+/,' ')
                    sql.strip!
                    sql << ';' unless sql[-1] == ?;

                    argstr = args.join(',')
                    usage << "(#{argstr})" unless argstr.empty?

                    blockstr = %{$SAFE=2;lambda{|#{argstr}|%{#{sql}} % [#{argstr}]}}
                    block = Thread.new{ eval(blockstr) }.value
                    args = []
                else
                    usage << "(#{block.arity})" unless 0 == block.arity
                end

                @registrations[sym] = Registration.new(name, args, bangs, block, usage, desc)
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

    end

end # module RSQL