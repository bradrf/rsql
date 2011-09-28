#!/usr/bin/env ruby

require 'test/unit'

begin
    require 'rubygems'
rescue LoadError
end
require 'mocha'

$: << File.expand_path(File.join(File.dirname(__FILE__),'..','lib')) << File.dirname(__FILE__)
require 'rsql/mysql_results.rb'
require 'rsql/eval_context.rb'
require 'rsql/commands.rb'

class TestCommands < Test::Unit::TestCase

    include RSQL

    def setup
        @orig_stdout = $stdout
        $stdout = @strout = StringIO.new
        @ctx = EvalContext.new
        @conn = mock('Mysql')
        @conn.expects(:list_dbs).returns([])
        MySQLResults.conn = @conn
    end

    def teardown
        $stdout = @orig_stdout
    end

    def test_simple_ruby
        cmds = Commands.new('. puts :hello', :display_by_column)
        assert_equal(false, cmds.empty?)
        assert_not_nil(cmds.last)
        cmds.run!(@ctx)
        assert_equal('hello', @strout.string.chomp)
    end

    def test_simple_sql
        cmds = Commands.new('do some silly stuff', :display_by_column)
        @conn.expects(:query).with(instance_of(String)).returns(nil)
        @conn.expects(:affected_rows).returns(1)
        cmds.run!(@ctx)
        assert_match(/Query OK, 1 row affected/, @strout.string)
    end

    def test_separators
        cmds = Commands.new('. puts :hello\; puts :world;', :display_by_column)
        cmds.run!(@ctx)
        assert_equal('hello'+$/+'world', @strout.string.chomp)

        # make sure our logic to handle eval'd blocks with args works
        @strout.string = ''
        cmds = Commands.new('. Proc.new{|a| puts a.inspect} | @results.value.call(:fancy)', :display_by_column)
        cmds.run!(@ctx)
        assert_equal(':fancy', @strout.string.chomp)
    end

    def test_multiple
        @conn.expects(:query).with('one thing').returns(nil)
        @conn.expects(:affected_rows).returns(1)
        cmds = Commands.new('. "one thing" ; . puts :hello.inspect', :display_by_column)
        cmds.run!(@ctx)
        assert_match(/^QueryOK,1rowaffected\(\d+.\d+sec\):hello$/,
                     @strout.string.gsub(/\s+/,''))
    end

    def test_bangs
        cmds = Commands.new('silly stuff ! this => that', :display_by_column)
        @conn.expects(:query).with('silly stuff').returns(nil)
        @conn.expects(:affected_rows).returns(13)
        cmds.run!(@ctx)
        assert_match(/Query OK, 13 rows affected/, @strout.string)

        # now test logic to continue if it _doesn't_ look like a bang
        cmds = Commands.new('silly stuff ! more things', :display_by_column)
        @conn.expects(:query).with('silly stuff ! more things').returns(nil)
        @conn.expects(:affected_rows).returns(4)
        cmds.run!(@ctx)
        assert_match(/Query OK, 4 rows affected/, @strout.string)
    end

end # class TestCommands
