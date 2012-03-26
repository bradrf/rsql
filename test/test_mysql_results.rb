#!/usr/bin/env ruby

require 'test/unit'

begin
    require 'rubygems'
rescue LoadError
end
require 'mocha'

$: << File.expand_path(File.join(File.dirname(__FILE__),'..','lib')) << File.dirname(__FILE__)
require 'rsql/mysql_results.rb'

class TestMySQLResults < Test::Unit::TestCase

    include RSQL

    def setup
        MySQLResults.conn = nil
        MySQLResults.database_name = nil
        MySQLResults.reset_cache
    end

    def test_databases
        assert_equal([], MySQLResults.databases)
        conn = mock('Mysql')
        conn.expects(:reconnect=)
        conn.expects(:list_dbs).returns(['accounts'])
        conn.expects(:select_db)
        conn.expects(:list_tables).returns([])
        MySQLResults.conn = conn
        assert_equal(['accounts'], MySQLResults.databases)
    end

    def test_tables
        assert_equal([], MySQLResults.tables)
        MySQLResults.reset_cache

        conn = mock('Mysql')
        conn.expects(:reconnect=)
        conn.expects(:list_dbs).returns(['accounts'])
        conn.expects(:select_db)
        conn.expects(:list_tables).returns(['users','groups'])
        MySQLResults.conn = conn

        assert_equal([], MySQLResults.tables)
        MySQLResults.database_name = 'accounts'
        assert_equal(['groups','users'], MySQLResults.tables)
        assert_equal(['groups','users'], MySQLResults.tables('accounts'))
    end

    def test_complete
        assert_equal([], MySQLResults.complete(nil))

        conn = mock('Mysql')
        conn.expects(:reconnect=)
        conn.expects(:list_dbs).returns(['Accounts','Devices','Locations'])
        conn.expects(:select_db).times(3)
        tbls = sequence(:tbls)
        conn.expects(:list_tables).in_sequence(tbls).returns(['Prefs','Names'])
        conn.expects(:list_tables).in_sequence(tbls).returns(['IPs'])
        conn.expects(:list_tables).in_sequence(tbls).returns(['Street','City','State'])
        MySQLResults.conn = conn

        assert_equal(['Accounts','Devices','Locations'], MySQLResults.complete(''))
        assert_equal(['Accounts'], MySQLResults.complete('a'))

        MySQLResults.database_name = 'Accounts'
        assert_equal(['Devices','Locations','Names','Prefs'], MySQLResults.complete(''))
        assert_equal(['Names'], MySQLResults.complete('n'))

        assert_equal(['Accounts.Names','Accounts.Prefs'], MySQLResults.complete('accounts.'))
    end

    def test_query
        f1 = mock('f1')
        f1.expects(:name).returns('c1').times(12)
        f1.expects(:type).returns(1).times(2)
        f1.stubs(:is_num?).returns(false)
        f1.stubs(:longest_length)

        f2 = mock('f2')
        f2.expects(:name).returns('c2').times(11)
        f2.expects(:type).returns(1).times(2)
        f2.stubs(:is_num?).returns(false)
        f2.stubs(:longest_length)

        res = mock('results')
        res.expects(:num_rows).returns(2).times(2)
        res.expects(:fetch_fields).returns([f1,f2])

        rows = sequence(:rows)
        res.expects(:fetch_row).in_sequence(rows).returns(['v1.1','v1.2'])
        res.expects(:fetch_row).in_sequence(rows).returns(['v2.1','v2.2'])
        res.expects(:fetch_row).in_sequence(rows).returns(nil)

        conn = mock('Mysql')
        conn.expects(:reconnect=)
        conn.expects(:list_dbs).returns([])
        conn.expects(:query).with(instance_of(String)).returns(res)
        conn.expects(:affected_rows).returns(1)
        conn.expects(:reconnected?)
        MySQLResults.conn = conn

        bangs = mock('bangs')
        bangs.expects(:bang_eval).with(instance_of(String),instance_of(String)).
            returns('val').times(4)

        mres = MySQLResults.query('ignored', bangs)
        assert_equal('ignored', mres.sql)
        assert_equal(true, mres.any?)
        assert_equal(false, mres.empty?)
        assert_equal(2, mres.num_rows)
        assert_equal({"c1"=>"val", "c2"=>"val"}, mres[0])
        assert_equal({"c1"=>"val", "c2"=>"val"}, mres[1])
        assert_equal(nil, mres[2])

        cnt = 0
        mres.each_hash do |row|
            cnt += 1
            assert_equal({"c1"=>"val", "c2"=>"val"}, row)
        end
        assert_equal(2, cnt)

        dout = StringIO.new
        mres.display_by_column(dout)
        assert_match(/^c1c2--------valvalvalval--------2rowsinset/,
                     dout.string.gsub(/\s+/,''))

        dout = StringIO.new
        mres.display_by_batch(dout)
        assert_equal('valvalvalval', dout.string.gsub(/\s+/,''))

        dout = StringIO.new
        mres.display_by_line(dout)
        assert_match(/^\*+1.row\*+c1:valc2:val\*+2.row\*+c1:valc2:val2rowsinset/,
                     dout.string.gsub(/\s+/,''))
    end

    def test_init
        mres = MySQLResults.new([], [])
        assert_equal(0, mres.num_rows)

        mres = MySQLResults.new(['col1', 'col2'], [[1,2], [3,4]])
        assert_equal(2, mres.num_rows)
        dout = StringIO.new
        mres.display_by_column(dout)
        assert_equal('col1col2----------1234----------2rowsinset',
                     dout.string.gsub(/\s+/,''))
    end

    def test_grep
        f1 = mock('f1')
        f1.stubs(:name).returns('c1')
        f1.stubs(:type).returns(1)
        f1.stubs(:is_num?).returns(false)
        f1.stubs(:longest_length)

        f2 = mock('f2')
        f2.stubs(:name).returns('c2')
        f2.stubs(:type).returns(1)
        f2.stubs(:is_num?).returns(false)
        f2.stubs(:longest_length)

        res = mock('results')
        res.stubs(:num_rows).returns(2)
        res.stubs(:fetch_fields).returns([f1,f2])

        rows = sequence(:rows)
        res.expects(:fetch_row).in_sequence(rows).returns(['v1.1','v1.2'])
        res.expects(:fetch_row).in_sequence(rows).returns(['v2.1','v2.2'])
        res.expects(:fetch_row).in_sequence(rows).returns(nil)

        conn = mock('Mysql')
        conn.expects(:reconnect=)
        conn.stubs(:list_dbs).returns([])
        conn.stubs(:query).with(instance_of(String)).returns(res)
        conn.stubs(:affected_rows).returns(1)
        conn.expects(:reconnected?).times(4)
        MySQLResults.reset_history
        MySQLResults.conn = conn

        mres = MySQLResults.query('ignored1', eval_context=nil, raw=true)
        assert_equal(false, mres.grep(/val/))

        rows = sequence(:rows)
        res.expects(:fetch_row).in_sequence(rows).returns(['v1.1','v1.2'])
        res.expects(:fetch_row).in_sequence(rows).returns(['v2.1','v2.2'])
        res.expects(:fetch_row).in_sequence(rows).returns(nil)

        mres = MySQLResults.query('ignored2', eval_context=nil, raw=true)
        assert_equal(true, mres.grep('v1', :fixed))
        assert_equal("\e[31;1mv1\e[0m.1", mres[0]['c1'])
        assert_equal("\e[31;1mv1\e[0m.2", mres[0]['c2'])

        rows = sequence(:rows)
        res.expects(:fetch_row).in_sequence(rows).returns(['v1.1','v1.2'])
        res.expects(:fetch_row).in_sequence(rows).returns(['v2.1','v2.2'])
        res.expects(:fetch_row).in_sequence(rows).returns(nil)

        mres = MySQLResults.query('ignored3', eval_context=nil, raw=true)
        assert_equal(false, mres.grep('v', :fixed, :inverse))

        rows = sequence(:rows)
        res.expects(:fetch_row).in_sequence(rows).returns(['v1.1','v1.2'])
        res.expects(:fetch_row).in_sequence(rows).returns(['v2.1','v2.2'])
        res.expects(:fetch_row).in_sequence(rows).returns(nil)

        mres = MySQLResults.query('ignored4', eval_context=nil, raw=true)
        assert_equal(true, mres.grep('v1.1', :nocolor))
        assert_equal("v1.1", mres[0]['c1'])

        # fixme: technically should be in it's only test...
        cmds = []
        4.times{|i| cmds << "ignored#{i+1}"}
        assert_equal(cmds, MySQLResults.history)
        assert_equal([cmds.last], MySQLResults.history(1))
        assert_equal(cmds, MySQLResults.history(15))
    end

end # class TestMySQLResults
