#!/usr/bin/env ruby

require 'test/unit'
require 'tempfile'

begin
    require 'rubygems'
rescue LoadError
end
require 'mocha'

$: << File.expand_path(File.join(File.dirname(__FILE__),'..','lib')) << File.dirname(__FILE__)
require 'rsql/mysql_results.rb'
require 'rsql/eval_context.rb'

class TestEvalContext < Test::Unit::TestCase

    include RSQL

    def setup
        @conn = mock('Mysql')
        @conn.expects(:list_dbs).returns([])
        @conn.expects(:query).with(instance_of(String)).returns(nil)
        @conn.expects(:affected_rows).returns(0)
        MySQLResults.conn = @conn
        @ctx = EvalContext.new
        @ctx.load(File.join(File.dirname(__FILE__),'..','example.rsqlrc'))
    end

    def test_load
#        @conn.expects(:list_dbs).returns([])
        orig = $stdout
        $stdout = out = StringIO.new
        @ctx.safe_eval('reload', nil, out)
        assert_match(/loaded: .+?example.rsqlrc/, out.string)
    ensure
        $stdout = orig
    end

    def test_eval
        out = StringIO.new

        # test a simple string registration
        val = @ctx.safe_eval('cleanup_example', nil, out)
        assert_equal('DROP TEMPORARY TABLE IF EXISTS rsql_example;', val)
        assert_equal(true, out.string.empty?)

        # test a block registration
        val = @ctx.safe_eval('fill_table', nil, out)
        assert_match(/(INSERT IGNORE INTO .+?){10}/, val)
        assert_equal(true, out.string.empty?)

        # test results handling and output redirection
        res = mock
        res.expects(:each_hash).yields({'value' => '2352'})
        val = @ctx.safe_eval('to_report', res, out)
        assert_equal(nil, val)
        assert_equal("There are 1 small values and 0 big values.", out.string.chomp)
    end

    def test_list
        out = StringIO.new
        val = @ctx.safe_eval('list', nil, out)
        assert_match(/usage\s+description/, out.string)
    end

    def test_params
        val = @ctx.safe_eval('params("ft", @registrations[:fill_table].block)', nil, nil)
        assert_equal('', val)
        val = @ctx.safe_eval('params("sv", @registrations[:save_values].block)', nil, nil)
        assert_equal('(fn)', val)
    end

    def test_desc
        out = StringIO.new
        err = StringIO.new
        orig_err = $stderr

        $stderr = err
        val = @ctx.safe_eval('desc max_rows', nil, out)
        $sterr = orig_err
        assert_equal('', out.string)
        assert_equal('refusing to describe EvalContext#max_rows',
                     err.string.chomp)

        err.string = ''
        $stderr = err
        val = @ctx.safe_eval('desc :sldkfjas', nil, out)
        $sterr = orig_err
        assert_equal('', out.string)
        assert_equal('nothing registered as sldkfjas', err.string.chomp)

        err.string = ''
        $stderr = err
        val = @ctx.safe_eval('desc :version', nil, out)
        $sterr = orig_err
        assert_equal('', out.string)
        assert_equal('refusing to describe the version method', err.string.chomp)

        err.string = ''
        out.string = ''
        val = @ctx.safe_eval('desc :cleanup_example', nil, out)
        assert_equal('', err.string)
        assert_equal('DROP TEMPORARY TABLE IF EXISTS #{@rsql_table}', out.string.strip)

        out.string = ''
        val = @ctx.safe_eval('desc :to_report', nil, out)
        lines = out.string.split($/)
        assert_match(/^register .+ do$/, lines[0])
        assert_match(/^\s+puts/, lines[-2])
        assert_match(/^end$/, lines[-1])
        assert_equal(12, lines.size)
    end

    def test_complete
        assert_equal(18, @ctx.complete('').size)
        assert_equal(['version'], @ctx.complete('v'))
        assert_equal(['.version'], @ctx.complete('.v'))
    end

    def test_bang_eval
        @ctx.bangs = {'time' => :relative_time}
        t = (Time.now - 2532435).to_s
        assert_equal(t, @ctx.bang_eval('do no harm', t))
        assert_equal(' 29 days ago', @ctx.bang_eval('time', t))
    end

    def test_humanize
        out = StringIO.new
        assert_equal('   9.16 GB',
                     @ctx.safe_eval('humanize_bytes(9832742324)', nil, out))
        assert_equal(9835475108,
                     @ctx.safe_eval('dehumanize_bytes("   9.16 GB")', nil, out))
        assert_equal(' 20.9%',
                     @ctx.safe_eval('humanize_percentage(0.209384)', nil, out))
        assert(out.string.empty?)
    end

    def test_hex
        bin = ''
        100.times{|i| bin << i}
        hex = @ctx.to_hexstr(bin)
        assert_equal('0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f' <<
                     '... (68 bytes hidden)', hex)

        out = StringIO.new
        assert_equal('0x1234', @ctx.safe_eval('hexify("1234")', nil, out))
        assert_equal('0x1234', @ctx.safe_eval('hexify("0x1234")', nil, out))
        assert_equal('0x1234', @ctx.safe_eval('hexify(0x1234)', nil, out))
        assert(out.string.empty?)
    end

    def test_safe_save
        out = StringIO.new
        @ctx.safe_eval('@mystuff = {:one => 1, :two => 2}', nil, out)
        tf = Tempfile.new('mystuff')
        @ctx.safe_eval("safe_save(@mystuff, '#{tf.path}')", nil, out)
        tf = tf.path + '.yml'
        assert_equal("Saved: #{tf}", out.string.chomp)
        assert_equal({:one => 1, :two => 2}, YAML.load_file(tf))

        # now make sure it keeps one backup copy
        out = StringIO.new
        @ctx.safe_eval('@mystuff = {:one => 1}', nil, out)
        @ctx.safe_eval("safe_save(@mystuff, '#{tf}')", nil, out)
        assert_equal("Saved: #{tf}", out.string.chomp)
        assert_equal({:one => 1}, YAML.load_file(tf))
        assert_equal({:one => 1, :two => 2}, YAML.load_file(tf+'~'))
    ensure
        File.unlink(tf) if File.exists?(tf)
        File.unlink(tf+'~') if File.exists?(tf+'~')
    end

end # class TestEvalContext
