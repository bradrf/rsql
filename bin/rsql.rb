#!/usr/bin/env ruby

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

begin
    # this isn't required unless that's how mysql and net/ssh have
    # been installed
    require 'rubygems'
rescue LoadError
end

require 'thread'
require 'timeout'
require 'readline'
require 'yaml'
require 'mysql'
require 'net/ssh'

# allow ourselves to be run from within a source tree
libdir = File.join(File.dirname(__FILE__),'..','lib')
$: << libdir if File.directory?(libdir)

require 'rsql/eval_context'
require 'rsql/commands'
include RSQL

ver = '0.1'

bn = File.basename($0, '.rb')

Commands.eval_context = EvalContext.new

if i = ARGV.index('-rc')
    ARGV.delete_at(i)
    rc_fn = ARGV.delete_at(i)
else
    rc_fn = File.join(ENV['HOME'], ".#{bn}rc")
end

Commands.eval_context.load(rc_fn) if File.exists?(rc_fn)

################################################################################
# command line parsing

def get_password(prompt)
    iswin = nil != (RUBY_PLATFORM =~ /(win|w)32$/)
    STDOUT.print(prompt)
    STDOUT.flush
    `stty -echo` unless iswin
    password = STDIN.gets
    password.chomp!
ensure
    `stty echo` unless iswin
    STDOUT.puts
    return password
end

# safely separate login credentials while preserving "emtpy" values--
# anything of the form [<username>[:<password]@]<host>
#
def split_login(str)
    login = []
    if i = str.rindex(?@)
        login << str[i+1..-1]
        if 0 < i
            str = str[0..i-1]
            i = str.index(?:)
            if 0 == i
                login << '' << str[i+1..-1]
            elsif i
                login << str[0..i-1] << str[i+1..-1]
            else
                login << str
            end
        else
            login << ''
        end
    else
        login << str
    end
end

if i = ARGV.index('-help')
    Commands.eval_context.help
    exit
end

if i = ARGV.index('-version')
    puts "#{bn} v#{ver}"
    exit
end

if i = ARGV.index('-maxrows')
    ARGV.delete_at(i)
    Commands.max_rows = ARGV.delete_at(i).to_i
end

if i = ARGV.index('-sep')
    ARGV.delete_at(i)
    Commands.field_separator = ARGV.delete_at(i)
    Commands.field_separator = "\t" if Commands.field_separator == '\t'
    user_separator = true
end

if i = ARGV.index('-ssh')
    ARGV.delete_at(i)
    (ssh_host, ssh_user, ssh_password) = split_login(ARGV.delete_at(i))
end

if i = ARGV.index('-e')
    ARGV.delete_at(i)
    batch_input = ''
    ARGV.delete_if do |arg|
        arg_i = ARGV.index(arg)
        if i <= arg_i
            batch_input << ' ' << arg
        end
    end
    Commands.field_separator = "\t" unless user_separator
end

if ARGV.size < 1
    prefix = '        ' << ' ' * bn.size
    $stderr.puts <<USAGE

usage: #{bn} [-version] [-help]
#{prefix}[-rc <rcfile>] [-maxrows <max>] [-sep <field_separator>]
#{prefix}[-ssh [<ssh_user>[:<ssh_password>]@]<ssh_host>]
#{prefix}[<mysql_user>[:<mysql_password>]@]<mysql_host>
#{prefix}[<database>] [-e <remaining_args_as_input>]

  If -ssh is used, a SSH tunnel is established before trying to
  connect to the MySQL server.

  Commands may either be passed in non-interactively via the -e option
  or by piping into the process' standard input (stdin). If using -e,
  it _must_ be the last option following all other arguments.

USAGE
    exit 1
end

(mysql_host, mysql_user, mysql_password) = split_login(ARGV.shift)
mysql_password = get_password('mysql password? ') unless mysql_password
real_mysql_host = mysql_host

if ssh_host
    # randomly pick a tcp port above 1024
    mysql_port = rand(0xffff-1025) + 1025
else
    mysql_port = 3306
end

db_name = ARGV.shift

unless $stdin.tty?
    batch_input = $stdin.read.gsub(/\r?\n/,';')
end

# make sure we remove any duplicates when we add to the history to
# keep it clean
#
def add_to_history(item)
    found = nil
    Readline::HISTORY.each_with_index do |h,i|
        if h == item
            found = i
            break
        end
    end
    Readline::HISTORY.delete_at(found) if found
    Readline::HISTORY.push(item)
end

Commands.max_rows ||= batch_input ? 1000 : 200

ssh_enabled = false

if ssh_host

    # might need to open an idle channel here so server doesn't close on
    # us...or just loop reconnection here in the thread...

    port_opened = false

    puts "SSH #{ssh_user}#{ssh_user ? '@' : ''}#{ssh_host}..." unless batch_input
    ssh = nil
    ssh_thread = Thread.new do
        opts = {:timeout => 15}
        opts[:password] = ssh_password if ssh_password
        ssh = Net::SSH.start(ssh_host, ssh_user, opts)
        ssh_enabled = true
        ssh.forward.local(mysql_port, mysql_host, 3306)
        port_opened = true
        ssh.loop(1) { ssh_enabled }
    end

    15.times do
        break if ssh_enabled && port_opened
        sleep(1)
    end

    unless ssh_enabled
        $stderr.puts "failed to connect to #{ssh_host} ssh host in 15 seconds"
        exit 1
    end

    unless port_opened
        $stderr.puts "failed to forward #{mysql_port}:#{mysql_host}:3306 via #{ssh_host} ssh host in 15 seconds"
        exit 1
    end

    # now have our mysql connection use our port forward...
    mysql_host = '127.0.0.1'
end

puts "MySQL #{mysql_user}@#{real_mysql_host}..." unless batch_input
begin
    Commands.mysql = Mysql.new(mysql_host, mysql_user, mysql_password, db_name, mysql_port)
rescue Mysql::Error => ex
    if ex.message.include?('Client does not support authentication')
        $stderr.puts "failed to connect to #{mysql_host} mysql server: unknown credentials?"
    else
        $stderr.puts "failed to connect to #{mysql_host} mysql server: #{ex.message}"
    end
    exit 1
end

shutdown = false
cmd_started = false

Signal.trap('INT') do
    shutdown = true
    if cmd_started
        # stop the mysql command
        Commands.mysql.close
        mysql = nil
        $stderr.puts 'Closed mysql connection while working on a command'
    end
end

Commands.eval_context.call_init_registrations(Commands.mysql)

history_fn = File.join(ENV['HOME'], ".#{bn}_history")
if File.exists?(history_fn) && 0 < File.size(history_fn)
    YAML.load_file(history_fn).each {|i| Readline::HISTORY.push(i)}
end

db_name = '<no database selected>' unless db_name
prompt = bn + '> '

Readline.completion_proc = Commands.eval_context.method(:complete)

while (!shutdown) do
    if batch_input
        input = batch_input
    else
        puts '',"[#{mysql_user}@#{ssh_host ? ssh_host : mysql_host}:#{db_name}]"
        input = batch_input || Readline.readline(prompt)
        if input.nil? || shutdown
            puts
            break
        end
        input.strip!
        next if input.empty?
    end

    add_to_history(input)
    cmds = Commands.new(input)
    if cmds.empty?
        Readline::HISTORY.pop
        next
    end

    break if cmds.run! == :done
end

unless Commands.mysql.nil?
    begin
        Commands.mysql.close
    rescue => ex
        $stderr.puts(ex)
    end
end

sleep(0.3)
ssh_enabled = false

if Readline::HISTORY.any?
    if 100 < Readline::HISTORY.size
        (Readline::HISTORY.size - 100).times do |i|
            Readline::HISTORY.delete_at(i)
        end
    end
    File.open(history_fn, 'w') {|f| YAML.dump(Readline::HISTORY.to_a, f)}
end

if ssh_thread
    begin
        Timeout.timeout(10) { ssh_thread.join }
    rescue Timeout::Error
        $stderr.puts 'Timed out waiting to close SSH connection'
    end
end
