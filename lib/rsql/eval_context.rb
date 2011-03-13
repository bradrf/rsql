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

    ################################################################################
    # This class wraps all dynamic evaluation and serves as the reflection
    # class for adding new methods dynamically.
    #
    class EvalContext

        Registration = Struct.new(:name, :args, :bangs, :block, :usage, :desc)

        HEXSTR_LIMIT = 32

        def initialize
            @hexstr_limit = HEXSTR_LIMIT
            @last_cmd = nil

            @loaded_fns = []
            @init_registrations = []
            @bangs = {}

            @registrations = {
                :help => Registration.new('help',[],{},method(:help),'help',
                                          'Display documentation.'),
                :reload => Registration.new('reload',[],{},method(:reload),'reload',
                                            'Reload the rsqlrc file.'),
                :last_cmd => Registration.new('last_cmd',[],{},method(:show_last_cmd),
                                              'last_cmd', 'Print the last command generated.'),
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
            Thread.new{ eval '$SAFE=2;' + IO.read(fn) }.join
            @loaded_fns << fn unless @loaded_fns.include?(fn)
        rescue Exception => ex
            $stderr.puts("Loading #{fn} failed: #{ex.message}:", ex.backtrace.first)
        end

        def reload
            @loaded_fns.each{|fn| self.load(fn)}
        end

        def show_last_cmd
            puts @last_cmd
        end

        def get_block(sym)
            if reg = @registrations[sym]
                return reg.block
            end
            return nil
        end

        def bang_eval(bang, val)
            begin
                Thread.new{ eval("$SAFE=3;#{bang}(val)") }.value
            rescue Exception => ex
                $stderr.puts(ex.message, ex.backtrace.first)
            end
        end

        # safely evaluate Ruby content within our context
        #
        def safe_eval(content, last_results=nil)
            @last_results = last_results

            # allow a simple reload to be called directly as it requires a
            # little looser safety valve...
            if 'reload' == content
                reload
                return
            end

            begin
                value = Thread.new{ eval('$SAFE=3;' + content) }.value
            rescue Exception => ex
                $stderr.puts(ex.message, ex.backtrace.first)
            end

            @last_command = value

            return value
        end

        # display some basic usage for calling dynamic methods
        #
        def help
            puts <<HELP

Aside from the standard MySQL command syntax, the following
functionality allows for a little more expressive processing.

Multiple commands can be issued in one set by separation with
semicolons.


Generating SQL
--------------

Ruby code may be called to generate the SQL that is to be executed.
This is done by starting any command string with a period. If the
final result of evaluating the command string is another string, it is
executed as SQL. Any semicolons meant to be processed by Ruby must be
escaped. Example:

 rsql> . puts 'hello world!' \\; 'select * from Account'


Utilizing Canned Methods
------------------------

Commands can be stored in the .rsqlrc file in your HOME directory to
expose methods that may be invoked to generate SQL with variable
interpolation. Use of the 'register' helper is recommended for this
approach. These can then be called in the same way as above. Example:

In the .sqlrc file...

 register :users_by_email, :email %q{
   SELECT * FROM Users WHERE email = '\#\{email\}'
 }

...then from the prompt:

 rsql> . users_by_email 'brad@gigglewax.com'

If a block is provided to the registration, it will be called as a
method. Example:

In the .sqlrc file...

 register :dumby, :hello do |*args|
   p args
 end

 rsql> . dumby :world

All registered methods can be listed using the built-in 'list'
command.

Changes to a sourced file can be reloaded using the built-in 'reload'
command.


Processing Column Data
----------------------

Ruby can be called to process any data on a per-column basis before a
displayer is used to render the output. In this way, one can write
Ruby to act like MySQL functions on all the data for a given column,
converting it into a more readable value. A bang indicator (exlamation
point: !) is used to demarcate a mapping of column names to Ruby
methods that should be invoked to processes content. Example:

 rsql> select IpAddress from Devices ; ! IpAddress => bin_to_str

This will call 'bin_to_str' for each 'IpAddress' returned from the
query. Mulitple mappings are separated by a comma. These mappings can
also be utilized in a canned method. Example:

 register :all_ips, 'select IpAddress from Devices', 'IpAddress' => :bin_to_str


Redirection
-----------

Output from one or more queries may be post-processed dynamically. If
any set of commands is follwed by a greater-than symbol, all results
will be stored in a global $results array (with field information
stored in $fields) and the final Ruby code will be evaluated with
access to them. Any result of the evaluation that is a string is then
executed as SQL. Example:

 rsql> select * from Account; select * from Users; > $results.each {|r| p r}

HELP
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

            ret = @registrations.keys.sort_by{|sym|sym.to_s}.collect do |sym|
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

            if limit && limit < 1
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
                    final_args << @last_results if @last_results
                    reg.block.call(*final_args)
                else
                    super.method_missing(sym, *args, &block)
                end
            end

    end

end # module RSQL
