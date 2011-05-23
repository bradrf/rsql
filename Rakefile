require 'rake'
require 'rake/rdoctask'
require 'rake/testtask'
require 'rake/gempackagetask'
require 'rake/clean'

task :default => [:rdoc, :test]

Rake::RDocTask.new do |rd|
    rd.rdoc_dir = 'doc'
    rd.title = 'RSQL Documentation'
    rd.main = "README.rdoc"
    rd.rdoc_files.include('README.rdoc', 'lib')
    rd.options << '--exclude' << 'mysql.rb'
end

Rake::TestTask.new do |t|
  t.libs << 'test'
  t.test_files = FileList['test/test_*.rb']
end

begin
    # don't require rcov if they haven't installed it
    require 'rcov/rcovtask'
    Rcov::RcovTask.new do |t|
        t.libs << "test"
        t.test_files = FileList['test/test*.rb']
    end
rescue LoadError
end

spec = Gem::Specification.new do |s|
    rsql_version = nil
    File.open("lib/rsql.rb").each do |line|
        if line =~ /VERSION\s*=\s*'([^']+)'/
            rsql_version = $1
            break
        end
    end
    s.summary = 'Ruby based MySQL command line with recipes.'
    s.name = 'rsql'
    s.author = 'Brad Robel-Forrest'
    s.email = 'brad+rsql@gigglewax.com'
    s.version = rsql_version
    s.required_ruby_version = '>=1.8.2'
    s.add_dependency('net-ssh', '>=2.1.0')
    s.require_path = 'lib'
    s.files = `git ls-files`.split($/) << 'lib/rsql/mysql.rb'
    s.files.delete('Rakefile')
    s.rdoc_options <<
        '--title' << 'RSQL Documentation' <<
        '--main' << 'README.rdoc' <<
        '--exclude' << 'mysql.rb'
    s.extra_rdoc_files = ['README.rdoc']
    s.executables = 'rsql'
    s.homepage = 'https://github.com/bradrf/rsql'
    s.description = <<EOF
RSQL makes working with a MySQL command line more convenient through
the use of recipes and embedding the common operation of using a SSH
connection to an intermediary host for access to the MySQL server.
EOF
end

Rake::GemPackageTask.new(spec) do |pkg|
   pkg.need_zip = true
   pkg.need_tar = true
end

# Embed TOMITA Masahiro\'s pure Ruby MySQL client.

MYSQL_VERSION = '0.2.6'
MYSQL_TGZ     = "ruby-mysql-#{MYSQL_VERSION}.tar.gz"

file MYSQL_TGZ do |t|
    sh "wget -nv http://www.tmtm.org/en/ruby/mysql/#{t.name}"
end

file 'mysql.rb' => MYSQL_TGZ do |t|
    sh "tar --strip-components=1 -zxf #{MYSQL_TGZ} ruby-mysql-#{MYSQL_VERSION}/mysql.rb"
    # rake relies on timestamps to be new, so we need to update it to "now"
    touch 'mysql.rb'
end

file 'lib/rsql/mysql.rb' => 'mysql.rb' do |t|
    # consider if we need to run mysql's setup.rb on install of our pkg

    # wrap the mysql library within our module to avoid conflicting
    # with any other mysql lib installed
    File.open('mysql.rb') do |inf|
        File.open(t.name, 'w') do |outf|
            outf.puts('module RSQL')
            inf.each {|line| outf.write(line)}
            outf.puts('end # module RSQL')
        end
    end
    puts 'embedded mysql.rb'
end

task :package => 'lib/rsql/mysql.rb'
task :gem => 'lib/rsql/mysql.rb'

CLOBBER.include(MYSQL_TGZ, 'mysql.rb')
